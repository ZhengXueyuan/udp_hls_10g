# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行)

Kintex-7 XC7K325T 纯硬件 TCP/IP 数据面: 64bit 字流 @125MHz, 当前 1G RGMII 前端
(10G 仅提时钟到 156.25MHz, 流水线不改)。顶层 = `board/wrapper_p4.v`。
施工日志/踩坑/决策详见 `PORT_NOTES.md`; 工程规范与铁律见 `CLAUDE.md`。

## 状态 (2026-09-20)

**P0-P5c 全部完成并提交; P5a/P5b/P5c 均通过板级验证。**

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
| P5b | 应用 RX 流控闭环 (窗口随缓冲占用收缩 + 慢消费者背压) | ✅ **门全绿 + 板级 PASS** |
| P5c | 关闭语义完善 (FIN 重推死锁 / RST 回卷洪水 / abort fence / 关闭超时) | ✅ **门全绿 + 板级 PASS** |
| P5d | 多连接加固 (信用池分池 / HLS 槽泄漏 + 48K 硬编码通告窗 + ackq 条目带 seq) | ⬜ 下一步 |
| P5e | UDP app 接口 (复用 udp_rx/udp_tx_frame) | ⬜ |
| P6 | 10G 提速 (156.25MHz + PG157 shim) | ⬜ 规划中 |

- **P5b 一句话结论**: 通告窗口 = `winq - occ` 随 frame_fifo 占用收缩、零窗后由 `wu` ACK
  主动重开;接受界加 `ACC_MARGIN(4096)` 裕度 + 拒收回 ACK ⇒ 慢消费者背压**零丢字节**。
  板级两张 UART 快照闭合 `W + occ ≈ winq`;构建 WNS −3.089 → **+0.271**。
- **P5c 一句话结论**: 修掉 FIN 重推死锁 (G1) 与 `ring_delta` 下溢洪水 (G9),abort 加 TX
  fence + `state=0` 写 + 配额归还,关闭超时**带对端活性判据** (静默 400ms 才 RST)。
  板级: FIN 后持续有数据 **5.2s 不被 RST**;对端静默后 **400ms RST**。

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
  窗口闭环与关闭语义见下 (P5b/P5c)。
- **应用 RX 流控闭环 (P5b)**: 每连接信用配额 `winq` (池 `WIN_POOL=0xC000`,按构造
  `Σwinq + pool == WIN_POOL`) + 单调右沿 `redge`;通告窗口 = `winq - occ`
  (`occ` = 全局 frame_fifo 占用,字粒度向上取整 ⇒ 保守) ⇒ app 消费慢则窗口收、零窗后
  由 **`wu` ACK** 主动重开 (电平请求 + gnt 握手,最低优先不抢 FIN 重推) ⇒ 对端停等可解。
  接受界 = 通告界 + **`ACC_MARGIN`(4096)** (对端按旧窗口合法发出的在飞段不被拒),
  拒收段回 ACK (RFC 793) ⇒ 不再白等 200ms RTO。app 侧慢消费者经 `tb_app_sink` 建门。
- **关闭语义 (P5c)**: FIN 重推不再只有一次机会 (排空拍"确实入队才清 pend" + RTO 装表兜底,
  修 G1 死锁)、`blocked` 期不回卷导致的 `ring_delta` 下溢洪水修复 (G9,修前会重放
  逐字节可验证的旧数据)、abort 后 TX fence (`rst_sent` 进 `start_data` 与 `s_axis_tready`
  同门) + `state=0` 写 (复用 fc 写通道) + 配额归还、**关闭超时 = 连续 400ms 对端无进展**
  (活性判据:该槽 `rcv_nxt` 未推进;合法半关闭的数据流不会被误拆)。

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
| 时序 | **WNS +0.137 ns**, TNS=0.000 / **WHS +0.041** / THS=0.000, **0 失败端点** (P5c, 全部约束达成) |
| Slice LUT | 49,426 / 203,800 (24.25%) — 含诊断脚手架与 P5 app/流控逻辑 |
| Slice Register | 39,887 / 407,600 (9.79%) |
| Block RAM | **310 / 445 (69.66%)** (RAMB36 ×279 + RAMB18 ×62) — retx_ram 16 连接 × 64KB (256 片 RAMB36) + 各级 frame FIFO + HLS 内部缓存 |
| 布局策略 | Performance_ExtraTimingOpt (retx_ram 写地址寄存器化 + max_fanout 修 256 片布线拥塞) |

⚠️ **hold 余量极薄** (WHS 仅 +0.041,最差 hold = 0 级逻辑纯布线) ⇒ 后续每次构建都要盯 WHS;
setup 侧近临界族 = `ack_pend_r → TCB CE` (slack 0.465–0.523,见 PORT_NOTES 的 P5c 段)。

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
- **P5b 板级 (窗口闭环成立)**: 两张 UART 快照闭合 `通告窗 W + 占用 OC ≈ winq (49152)` —
  · `RW=1E40` (7744) / `OC=0A1E8` (41448) ⇒ 和 = 49192 (差 +40)
  · `RW=2078` (8312) / `OC=09F60` (40800) ⇒ 和 = 49112 (差 −40)
  差值 = 字粒度取整 + 两个字段的采样时刻差 (与 flow 门的"抖动"同源,**非撤窗**)。
  `WU`/`PX` 只在**连接建立瞬间的配额竞争**时同步 +1 (冷启动单次 4MB 运行 `WU=0` ⇒
  正常数据流零额外帧,符合设计意图)。
- **P5c 板级 (关闭超时活性判据)**: FIN 之后对端**持续有数据 5.2s 不被 RST** (旧判据
  400ms 就 RST,会把对端 4MB 全丢);对端**静默 400ms 后 RST** ✓ —— 合法半关闭不再被误拆,
  无响应连接仍能拆干净 (RST 上线 + `state=0` + 配额归还)。
  · **阴性对照 (对端主动关闭)**: PC `shutdown(SHUT_WR)` ⇒ 走 HLS 慢路径 DEL ⇒ `RS` 不增
    (线上无 RST 帧),超时**不误触发** ✓
  · **配额归还后新连接可用**: 超时拆除后新连接拿到满窗 `WQ=C000` 并收全数据 ✓
    (累计 `RX=10,960,896` 逐字节精确、`MM=0`,工具 `BOARD_P5B OK`)
  · ⚠️ `FI` 口径: 它只是 **fast path** 的 FIN 计数;慢路径 HLS 另发一帧 FIN+ACK
    (`hls/src/layer_tcp.cpp` 的 `T_SYN_RCVD` 收 FIN 分支,seq 用旧值 ⇒ 对端 out-of-window
    丢弃,是该分支的正确行为) ⇒ **"一次 close 恰 1 帧 FIN"在线上不成立**,判据勿按线帧数写。

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
- `pc_p5b_win_test.py [--bytes 4194304]` — **P5b/P5c app RX 方向板级验收**: PC 全速灌图案
  (板侧校验器消费 ~0.89 字节/拍 ⇒ 必然积压 ⇒ 触发窗口收缩/wu 重开);图案生成**先于 connect**
- `board_p5b_check.py [--port COM9] [--expect-rx N]` — 读板侧 P5B1 状态行并自动判据
  (RX/MM/AD/DL/OC);`WU`/`PX`/`FI`/`RS` 只作诊断,口径见脚本头注释

**构建/烧录** (`board/`) — 两套独立工程, 位流互不覆盖:
```bash
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p4.bat'      # 默认构建 (echo 数据面) → p4_prj
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p4.bat'    # JTAG 烧录 (1MHz)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p5.bat'      # APP_MODE (app 接口) → p5_prj
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p5.bat'
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_timing_p5.bat'     # 快速时序迭代 (synth+place, 不 route/bitgen)
```
**P5 app 门** (`sim/p5sim/`, 独立目录): `run_tb_p5_app.bat` (1MB 图案逐字节) /
`run_tb_p5_app.bat close` (**P5c 关闭语义门**: 恰一 FIN / FIN 丢失 RTO 重发 / abort→RST+fence /
同时关闭 / 超时 → 5 条判据 + 3 条负向对照) / `run_tb_p5_wrapper.bat`
(**wrapper APP_MODE 全链 — 接线错误只有它能抓**) / `run_tb_p5_status.bat` /
`run_tb_p5_adv.bat <case>` (对抗集 11 例,含 `accmgn` 接受裕度定价) /
`run_tb_p5_fc.bat` (**P5b 定向单元门**: 池/右沿算术边界/4GB 回绕/事件撞车) /
`run_tb_p5_flow.bat` (**P5b 窗口闭环门**: 慢消费者 + 对端灌数据,逐拍占用/右沿/零重传)。
**P5c 定向证伪门**: `run_tb_tcp_close.bat` (`sim/p5close/`, G1 FIN 重推死锁 / G9 回卷洪水;
修复前 FAIL、修复后 PASS)。

## 遗留

- **P5d (下一步, 多连接加固)**:
  · **HLS 槽位泄漏**: abort/关闭后 HLS 槽停在 `T_ESTABLISHED`,同四元组新 SYN 被静默忽略
    (`hls/src/layer_tcp.cpp` 只有 `T_FREE+SYN+!ACK` 才建连) ⇒ 槽位永久占用
    (MAX_TCP_CONN=3 ⇒ 三次半关闭后建不了连)。
  · **HLS 硬编码 48K 通告窗 (C21)**: 慢路径每个段 (含 SYN-ACK) 都写死 `0xC000` ⇒
    零配额连接 (多连接池耗尽) 被告诉 48K 而猛发 ⇒ 全被 `tcp_rx` 拒 (物理安全由接受窗兜住,
    但**流控闭环对这类连接第一步就失效**) ⇒ 必须与**多连接信用分池**一起解决。
  · **多连接分池**: 零拷贝是单一全局 64KB FIFO ⇒ 今天 `WIN_Q_MAX = WIN_POOL` 让第 2 条连接
    `winq=0`;分池策略 (每连接配额上限 / `occ` 按连接归属) 未做。
  · **ackq 条目不带 seq** (P5c T1 残余): FIN 条目弹出那 1 拍内对端 ACK 到达时仍可能发
    `seq = fin_seq+1` 的 FIN ⇒ 需条目带 seq (接口改动)。
  · **`scan_now` 饥饿**: `fin_push`/`rst_push`/RTO 装表只在 FSM `S_IDLE` 拍评估 ⇒ app 饱和
    发送时 close/abort 被推到数据流结束才发 (生产 1MB ≈ 8ms);判据全绿但"应用中途 abort
    的响应延迟"无上界。
- **P5e**: UDP app 接口 (复用 udp_rx/udp_tx_frame)。**P6**: 10G 未开工; DDR 留给 10G 大窗口
  (BRAM 已用 69.66%)
- **P6 前哨 — 通告右沿 Δ 漂移在 10G 会溢出 (C1b)**: 实际通告右沿 = `redge + Δ`
  (`Δ = ackq 深 × 每帧拍数 × 到达速率`):1G (1B/拍) `32×88×1 = 2816` ⇒ `49152+2816 < 65536` ✓;
  **10G (8B/拍) `32×88×8 = 22528` ⇒ `49152+22528 = 71680 > 65536` ❌ 溢出**。
  P6 必做 (三选一): ① 减小 ackq 深 ② 缩 `WIN_Q_MAX` ③ **把 `redge[c]` 直接接进 ACK 帧组装**
  (窗口字段 = `clamp(redge[rb_id] - rb_rcv_nxt)`,精确右沿,根治;代价 16×32 位寄存器跨模块)。
- **P5b/P5c 已知代价**: 接受窗 (`ACC_MARGIN=4096`) 只在单连接 + 1G 流量下压测;
  多连接 + 大流量只有推导,无压测。构建 **hold 余量 +0.041ns 极薄** ⇒ 换布局种子或加逻辑时
  首当其冲是 hold。
- 板侧既有病理 (P4 起就有, 非 P5 引入): 偶发突发丢帧 + TX 静默 ~200ms
  (因果链推断 = 乱序 dup-ACK 请求 → `ackq` 8 深溢出 → 对端只能等 200ms RTO);
  P5b 对症 = ackq 加深 (8→32) + `stat_ack/drop` 接进 UART 快照 + 窗口闭环
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
