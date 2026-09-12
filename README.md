# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行)

Kintex-7 XC7K325T 纯硬件 TCP/IP 数据面: 64bit 字流 @125MHz, 当前 1G RGMII 前端
(10G 仅提时钟到 156.25MHz, 流水线不改)。顶层 = `board/wrapper_p4.v`。
施工日志/踩坑/决策详见 `PORT_NOTES.md`; 工程规范与铁律见 `CLAUDE.md`。

## 状态 (2026-09-12)

**P0-P4b-7 全部完成, 板级 100MB 速率测试全通, 全部工作已提交并推送 GitHub。**

| 里程碑 | 内容 | 状态 |
|---|---|---|
| P0 | MAC RX/TX 64bit 字流 + 接口规范 | ✅ 板级 PASS |
| P1 | UDP echo 全链 bring-up | ✅ 板级 PASS |
| P2 | TCP fast path echo (CAM/TCB 基础) | ✅ 板级 PASS |
| P3 | TCP fast path echo + HLS 慢路径 (ARP/ICMP/DHCP 自发行文) | ✅ 板级 PASS |
| P4a | ARP 免静态 + ping + TCP/UDP echo | ✅ 板级 PASS |
| P4b | HLS 正式握手 (SYN/FIN/RST 分流 + cfg 通道) | ✅ 板级 PASS |
| P4b-7 | **快速重传自愈** (dup-ACK 触发 + RTO 兜底, retx_ram ring) | ✅ 板级 PASS |
| P5 | app interface (对上层 TCP/UDP 调用接口) | ⬜ 下一步 |
| P6 | 10G 提速 (156.25MHz + PG157 shim) | ⬜ 规划中 |

## 已完成功能

**fast path (纯 RTL 数据面, 每级 II=1)**:
- 64bit 左对齐字流 MAC (`mac_rx_64`/`mac_tx_64`), FCS 校验/剥离 (CRC 残留 0xDEBB20E3)
- TCP 数据段解析 + CAM 四元组匹配 + 16 连接 TCB (rcv/snd 状态机 + 窗口门控)
- 逐帧判定的 echo 管道 (tcp_rx → tcp_echo → tcp_tx_frame, frame_fifo 坏帧回卷)
- **快速重传自愈**: 3×dup-ACK 触发回卷重放 + RTO 兜底扫描器 (retx_ram 每连接 16KB ring,
  窗口门控 in_flight < min(peer_wnd, RING_CAP), 32 位回绕安全比较)

**slow path (HLS 协议栈 IP, ap_ctrl_none @125MHz)**:
- ARP / ICMP echo / UDP echo / TCP SYN-FIN-RST 握手 + DHCP DISCOVER / UDP HELLO 自发行文
- HLS cfg 通道 (wscale/窗口) → CAM/TCB; 看门狗 (饥饿超时 64 拍复位脉冲) 防 HLS 死锁

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

## 综合结果 (diag20, Vivado 2025.2, routed)

| 项 | 值 |
|---|---|
| 时序 | **WNS +0.506 ns**, TNS=0 / WHS +0.007 / THS=0 (全部约束达成) |
| Slice LUT | 37,303 / 203,800 (18.30%) — 含诊断脚手架, 数据面本体 ~8.3K |
| Slice Register | 30,778 / 407,600 (7.55%) |
| Block RAM | 107.5 / 445 (24.16%) — 含 retx_ram 16×16KB ring + 各级 frame FIFO + HLS 内部缓存 |
| 布局策略 | Performance_ExtraTimingOpt (残余时序问题已用寄存器化/原语直例化收口) |

## 板级结果

- **100MB TCP echo 速率测试全通**: 126.9/127.0 Mbps 发送/回显稳态, 104,857,600 B
  完整收齐, 零冻结零 RST; 期间 563 次重传/dup-ACK 自愈事件被正确消化
- **冻结三类根因全部破案修复** (详见 PORT_NOTES 会话存档点):
  1. wire counter 新时钟域杀死 HLS 慢路径 (回退 + WL 改 gmii_clk 域)
  2. tcp_rx 截断支静默吞尾 → echo 帧合并 (按真实字节闭合修复)
  3. PC 网卡驱动重启 → 无 tlast 半帧 → echo 半帧不判尾 (fend_trunc 合成尾拍修复)
- **驱动重启风暴免疫验收**: 强杀 npcap 抓包进程复现法 5/5 轮 100MB 全部完整
  (124-157 Mbps; 修复前复现率 ~75%)

## 验证

**TB 四门矩阵** (P6 类改动的固定回归门, ~13 min, 见 `sim/p4sim/`):
```bash
cd sim/p4sim
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat 200'                    # 门1 无注入基线
TRUNC=100 TRUNCM=8   cmd //c '...run_tb_p4_burst.bat 200'                              # 门2 截断帧
HALFDROP=100 HALFDROPK=990 cmd //c '...run_tb_p4_burst.bat 200'                        # 门3 半帧中止
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain.bat'                        # 门4 全链
# 附加: TXDROP=50 (快速重传自愈) / gate-4096 / dupstorm / pause-300k / conn1 判据
```
判据: BURST OK + 载荷逐字节全等 + ECOMAX≤182 (无合并巨帧) + TRUNCS/HALFD 哨兵 +
abort/eend=0。当前全矩阵 10/10 绿。

**板级测试** (`tools/`):
- `pc_tcp_rate_test.py [MB]` — TCP echo 吞吐 (双线程, 稳态 10-90% 速率)
- `capture_rate_test.ps1 [MB]` — tshark 抓包 + 怪帧/重传统计
- `board_diag18_test.py [秒]` — COM8 UART 快照 + 并行抓包

**构建/烧录** (`board/`):
```bash
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p4.bat'      # Vivado 合成+实现+bitstream
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p4.bat'    # JTAG 烧录 (1MHz)
```

## 遗留

- P5 app interface / P6 10G 未开工; DDR 留给 10G 大窗口 (BRAM ring 12KB 窗口已够 1G)
- PC 侧网卡 (Killer E5000B) 驱动重启的怪帧/半帧由 RTL 三层防御兜底, 对端根因未深究
- w6 截断支 (帧在头字就结束) 无干净 TB 用例 (激励侧构造限制); wrapper_tcp.v (P3 目标) 端口过时
- 诊断脚手架 (UART/trace/LED) 保留为长期板级诊断接口
