# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行)

Kintex-7 XC7K325T 纯硬件 TCP/IP 数据面: 64bit 字流 @125MHz, 当前 1G RGMII 前端
(10G 仅提时钟到 156.25MHz, 流水线不改)。顶层 = `board/wrapper_p4.v`。
施工日志/踩坑/决策详见 `PORT_NOTES.md`; 工程规范与铁律见 `CLAUDE.md`。

## 状态 (2026-09-12)

**P0-P4c 全部完成, 板级 100MB/64MB 速率测试全通, 全部工作已提交并推送 GitHub。**

| 里程碑 | 内容 | 状态 |
|---|---|---|
| P0 | MAC RX/TX 64bit 字流 + 接口规范 | ✅ 板级 PASS |
| P1 | UDP echo 全链 bring-up | ✅ 板级 PASS |
| P2 | TCP fast path echo (CAM/TCB 基础) | ✅ 板级 PASS |
| P3 | TCP fast path echo + HLS 慢路径 (ARP/ICMP/DHCP 自发行文) | ✅ 板级 PASS |
| P4a | ARP 免静态 + ping + TCP/UDP echo | ✅ 板级 PASS |
| P4b | HLS 正式握手 (SYN/FIN/RST 分流 + cfg 通道) | ✅ 板级 PASS |
| P4b-7 | **快速重传自愈** (dup-ACK 触发 + RTO 兜底, retx_ram ring) | ✅ 板级 PASS |
| P4c | 窗口 12KB→48KB + retx_ram 64KB/连接 + ACK-early 破案 (w6a 纯 ACK 修复) | ✅ 板级 PASS |
| P4d | 修补包: TCP 主动连接 (客户端) + VLAN fast path + w6 截断支 TB | ✅ sim 全绿 |
| P5a | **app interface 数据面** (app AXIS 收发 + 寄存器控制面 + FIN/RST/close + 演示 app) | ✅ **板级双向 PASS** |
| P5b | 应用 RX 流控闭环 (窗口随缓冲占用收缩 + 慢消费者背压) | ⬜ 下一步 |
| P5c | 关闭语义完善 (FIN 丢失重传板级用例 / 同时关闭 / 关闭超时) | ⬜ |
| P5d | 多连接加固 (retx_id 归属 / pend_id 逐字段 / 信用池 / CAM 清除) | ⬜ |
| P5e | UDP app 接口 (复用 udp_rx/udp_tx_frame) | ⬜ |
| P6 | 10G 提速 (156.25MHz + PG157 shim) | ⬜ 规划中 |

## 已完成功能

**fast path (纯 RTL 数据面, 每级 II=1)**:
- 64bit 左对齐字流 MAC (`mac_rx_64`/`mac_tx_64`), FCS 校验/剥离 (CRC 残留 0xDEBB20E3)
- TCP 数据段解析 + CAM 四元组匹配 + 16 连接 TCB (rcv/snd 状态机 + 窗口门控)
- 逐帧判定的 echo 管道 (tcp_rx → tcp_echo → tcp_tx_frame, frame_fifo 8192 字坏帧回卷)
- **快速重传自愈**: 3×dup-ACK 触发回卷重放 + RTO 兜底扫描器 (retx_ram 每连接 64KB ring,
  读延迟 2 拍流水, 窗口门控 in_flight < min(peer_wnd, RING_CAP=0xBFFE), 32 位回绕安全比较)
- **P4c**: 通告窗口 48KB (0xC000, 免 WS); 纯 ACK 帧 seq 窗口内 (含右沿, RFC 零长段) 即
  接受并处理其 ACK/窗口字段 (w6a 修复 — 板级 ACK-early 暴跌根因, 顺带扩大 dup-ACK
  快速重传检测覆盖)

**slow path (HLS 协议栈 IP, ap_ctrl_none @125MHz)**:
- ARP / ICMP echo / IGMP / UDP echo (8080) / TCP SYN-FIN-RST 握手 (服务端被动打开) +
  DHCP DISCOVER / UDP HELLO 周期自发行文
- HLS cfg 通道 (wscale/窗口) → CAM/TCB; 看门狗 (饥饿超时 64 拍复位脉冲) 防 HLS 死锁

## 协议功能全景 (P4c 收官)

| 协议 | 能力 | 路径 |
|---|---|---|
| ARP | 应答 (192.168.100.2)、免静态 ARP 学对端身份 | HLS 慢路径 |
| ICMP | echo 应答 (ping 通) | HLS |
| IGMP | 接收处理 (组播入口) | HLS |
| UDP | **接收+回显** (8080) + **主动发送** (周期 UDP HELLO 广播) | HLS |
| DHCP | DISCOVER 自发行文 (主动 UDP 客户端行为) | HLS |
| TCP | 服务端被动握手 (SYN→SYN+ACK→ESTABLISHED / FIN→FIN+ACK→LAST_ACK / RST) + **数据 echo** | 握手 HLS; 数据 fast path |

- **TCP 角色**: 服务端 (被动打开) + **客户端 (主动 connect, P4d)** — ACTIVE_CONNECT 宏
  上电自动连固定 IP:port (ARP 前置 + T_SYN_SENT 状态 + SYN 限次重传, 与被动监听共存);
  端口 8080; 16 连接 CAM/TCB
- **VLAN**: fast path 单层 802.1Q/1ad 剥离 (P4d: vlan_strip shim — mac_rx 后剥 TPID+TCI
  重对齐, 下游零改动; QinQ 剥一层后自然退化慢路径); 慢路径 HLS 支持多层 802.1Q/1ad;
  TX 恒无 tag (接 trunk 时回包不带 tag — 已知语义)
- **流控**: TX 窗口门控 in_flight < min(peer_wnd, RING_CAP); RX 通告 48KB; seq 窗口语义
  (边界接受 / 窗口内 OOO 丢数据回 dup-ACK / 超窗静默丢 / 零长 ACK 含右沿); 无拥塞控制 (设计决策)
- **重传**: 3×dup-ACK 整窗口回卷重放 + RTO 兜底 (16 连接轮扫, 双丢自愈); 无 SACK/NewReno
  (echo 场景够用)
- **鲁棒性三层防御**: 截断帧闭合 / 半帧中止防御 / 对端风暴免疫 (详见下)
- **应用接口 (P5a)**: `APP_MODE` 构建下, 应用通过 **AXIS 流**发/收 TCP 载荷
  (`app_tx_*` 一帧 = 一个 TCP 段 ≤1460B, `tid`=conn_id; `app_rx_*` 零拷贝直出接收缓冲,
  带 `len` 边带), 通过**寄存器面**拿连接事件 (CONN_UP/DOWN + peer ip/port/mac)、下发
  close(发 FIN)/abort(发 RST)、读每连接状态与计数。默认构建 (宏未定义) 仍为 echo 语义。
  板级实测: app 连上后主动发 1MB 图案 → PC 收逐字节零失配 + close/FIN; PC 发 32KB →
  板侧校验器零失配。详见 `PORT_NOTES.md` 的 P5a 段与 `rtl/app_ctrl.v`/`rtl/app_pattern.v` 头注释。
  窗口闭环 (P5b) 未做: 通告窗仍是静态 48KB, app 不消费时的背压靠既有 frame_fifo。

**鲁棒性 (板级实战逼出的三层防御)**:
1. 截断帧闭合 — 线上帧短于 IP 承诺载荷时按真实字节收下转发, 缺口由 PC 重传自愈
2. 半帧中止防御 — 上游无 tlast 帧流中断时合成 ferr 尾拍闭合 echo 半帧 (坏帧回卷),
   杜绝与后续帧合并成巨帧
3. 对端风暴免疫 — PC 网卡驱动重启 (抓包强杀) 引发的 dup-ACK/重传风暴全消化

**板级诊断接口 (长期保留)**:
- UART 9600-8N1 (板载 CH340E, COM8) 全精度快照: TCB/窗口/FSM/三站词计数/tlast 三计数/
  截断计数 (TRU)/慢路径存活字段 (SC/SD/SF/SP/SV/HR)/线缆帧长 (WL) + 64 拍 TR/RXT 轨迹环
  + FIFO tlast 位图 (TL), boot 自检后每 5s 一行 (见 `board/uart_dbg.v` 头注释)
- LED: boot 自检 3 闪 + 门控/锁存/满标志实时探针

## 综合结果 (Vivado 2025.2, routed)

| 项 | 值 |
|---|---|
| 时序 | **WNS +0.237 ns**, TNS=0 / WHS +0.034 / THS=0 (P4c, 全部约束达成) |
| Slice LUT | 39,517 / 203,800 (19.39%) — 含诊断脚手架 |
| Slice Register | 33,091 / 407,600 (8.12%) |
| Block RAM | RAMB36 ×280 + RAMB18 ×55 ≈ 307.5 / 445 (69%) — retx_ram 16 连接 × 64KB (256 片 RAMB36) + 各级 frame FIFO + HLS 内部缓存 |
| 布局策略 | Performance_ExtraTimingOpt (retx_ram 写地址寄存器化 + max_fanout 修 256 片布线拥塞) |

## 板级结果

- **100MB TCP echo 速率测试全通** (P4b-7): 126.9/127.0 Mbps 发送/回显稳态,
  104,857,600 B 完整收齐, 零冻结零 RST; 期间 563 次重传/dup-ACK 自愈事件被正确消化
- **P4c 板级**: 48KB 窗口用满 (PC 在飞 45-48KB 实锤); 64MB 回归 105.9 Mbps 稳态完整
  收齐; ACK-early 实验 (suppress=0) 板测 28.4Mbps — 根因破案 (纯 ACK 窗口右沿被丢
  → snd_una 停滞 → RTO 风暴) 并修复 (w6a), 最终裁决: TX 帧率翻倍使 PC 网卡线级截断
  与线级丢帧触发率翻倍, RTO 自愈成本吃掉全部收益 → 板级回退 suppress=1, 修复保留
- **冻结三类根因全部破案修复** (详见 PORT_NOTES 会话存档点):
  1. wire counter 新时钟域杀死 HLS 慢路径 (回退 + WL 改 gmii_clk 域)
  2. tcp_rx 截断支静默吞尾 → echo 帧合并 (按真实字节闭合修复)
  3. PC 网卡驱动重启 → 无 tlast 半帧 → echo 半帧不判尾 (fend_trunc 合成尾拍修复)
- **驱动重启风暴免疫验收**: 强杀 npcap 抓包进程复现法 5/5 轮 100MB 全部完整
  (124-157 Mbps; 修复前复现率 ~75%)
- **吞吐实测 (P4d 修正)**: C++ 合成对端 (tools/cpp_peer, 绕过内核栈) 实测
  **1GB @ 891.5 Mbps / 256MB @ 890.4 Mbps** (逐字节零失配, 零 RTO, 双向近 1G 线速) —
  旧记的 "echo 架构 125Mbps 铁律" 已证伪 (那是 Python 内核栈 + 逐包 pcap 的工具链产物);
  实测瓶颈 = 板侧 48KB 通告窗 × RTT (428µs, 板子纯 ACK 仅 0.9% 全靠 echo 捎带)

## 验证

**TB 门矩阵** (P6 类改动的固定回归门, ~25 min, 见 `sim/p4sim/`):
```bash
cd sim/p4sim
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat 200'                    # 门1 无注入基线
TRUNC=100 TRUNCM=8   cmd //c '...run_tb_p4_burst.bat 200'                              # 门2 截断帧
HALFDROP=100 HALFDROPK=990 cmd //c '...run_tb_p4_burst.bat 200'                        # 门3 半帧中止
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain.bat'                        # 门4 全链
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain_stall.bat'                  # 门5 死锁复现 (P4d-fix)
# 附加: TXDROP=50 (快速重传自愈) / gate-4096 / dupstorm / pause-300k /
#       PCACKOOB=1 (纯 ACK 窗口右沿语义, w6a 修复复现门) / conn1 判据
#       单元 TB: retx_ram (7 组含 latency=2cyc) / frame_fifo (D=8192) / uart_dbg
# 全矩阵一键: bash sim/p4sim/run_matrix_p4dfix.sh (16 门, 逐门日志 matrix_*.log)
```
判据: BURST OK + 载荷逐字节全等 + ECOMAX≤182 (无合并巨帧) + TRUNCS/HALFD 哨兵 +
ACK 位置合法性 (截断段/OOO/补缺口段) + abort/eend=0。P4c 当前全矩阵 13 门绿。

**门5 (PCSTALL, P4d-fix)**: 复现板级 48KB 满窗 + RTO 重放期收到"已收全部数据"
的高水位 ACK。TB: 累计 ACK 到阈值字节后**永久停发 ACK** → 板侧在飞累积 → RTO
回卷 → 重放开始后注入**一个** ack = 高水位的纯 ACK → 之后不再注入。判据
(`gen_stim_p4_chain.py stallcheck`): 注入确在会话期内且注入时 snd_nxt < ack
(原始 bug 条件) + 之后 **snd_una 追上高水位** 且新数据继续发出 (seq >= 高位
的 echo 帧)。**修复前 (ack_ok 用回卷后 snd_nxt) 必 FAIL** (ACK 被拒 → snd_una
永久冻结), 修复后 OK — 两跑拍级同构, 证据 `sim/p4sim/stall_gate_*.log`。
参数: `run_tb_p4_chain_stall.bat [N [BYTES [DELAY]]]` (默认 200 49150 300;
BYTES/DELAY 经 pcstall.memh 同源传入 TB 与 checker)。

**板级测试** (`tools/`):
- `pc_tcp_rate_test.py [MB]` — TCP echo 吞吐 (双线程, 稳态 10-90% 速率)
- `capture_rate_test.ps1 [MB]` — tshark 抓包 + 怪帧/重传统计
- `board_diag18_test.py [秒]` — COM8 UART 快照 + 并行抓包

**构建/烧录** (`board/`) — 两套独立工程, 位流互不覆盖:
```bash
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p4.bat'      # 默认构建 (echo 数据面) → p4_prj
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p4.bat'    # JTAG 烧录 (1MHz)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p5.bat'      # APP_MODE (app 接口) → p5_prj
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p5.bat'
```
**P5 app 门** (`sim/p5sim/`, 独立目录): `run_tb_p5_app.bat` (1MB 图案逐字节) /
`run_tb_p5_wrapper.bat` (**wrapper APP_MODE 全链 — 接线错误只有它能抓**) /
`run_tb_p5_status.bat` / `run_tb_p5_adv.bat <case>` (对抗集 10 例)。

## 遗留

- P5b-P5e 未开工 (窗口闭环 / 关闭语义完善 / 多连接加固 / UDP app 接口);
  P6 10G 未开工; DDR 留给 10G 大窗口 (BRAM ring 64KB/连接已用 69% BRAM)
- **app 模式窗口仍是静态 48KB**: app 不消费时靠既有 frame_fifo 硬扛 (P5b 做占用→窗口闭环)
- 板侧既有病理 (P4 起就有, 非 P5 引入): 偶发突发丢帧 + TX 静默 ~200ms
  (因果链推断 = 乱序 dup-ACK 请求 → `ackq` 8 深溢出 → 对端只能等 200ms RTO);
  P5b 对症 = ackq 加深 + `stat_ack/drop` 接进 UART 快照 + 窗口闭环
- SACK、拥塞控制未实现 (echo 场景决策); TCP 主动连接/VLAN fast path 已补 (P4d),
  板级实测待做 (主动连接默认宏关, VLAN 无真实带 tag 对端)
- 10G 风险预记: VLAN 剥离的 tag 字气泡 + 尾拍停靠 (1G 由 mac 8 深 FIFO + IFG 吸收)
  在 10G 线速会吃掉 IFG 的 2/3 — P6 需复核 (与 rx_classify 已知 min-frame 丢帧叠加)
- **测试工具余量 (P6 前哨)**: C++ 合成对端的 flush 路径上限 ~191k 帧/s (≈1.1 Gbps 载荷),
  实测峰值 147.9k fps = 上限 78% (双向双帧/段需 155k fps)。**1G 够用但只剩 ~20% 余量,
  10G 必须换工具** (`pcap_sendqueue_transmit(sync=1)` + 逐帧 `pcap_next_ex` 的结构撑不住)
- PC 侧网卡 (Killer E5000B) 驱动重启的怪帧/半帧由 RTL 三层防御兜底, 对端根因未深究;
  PC 网卡线级截断/线级丢帧是 1G 线速不可达的最终瓶颈 (FPGA 侧可做项已尽)
- wrapper_tcp.v (P3 目标) 端口过时 (仅历史参考; 新接口已接线但 tb 无覆盖)
- 诊断脚手架 (UART/trace/LED) 保留为长期板级诊断接口
