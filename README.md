# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行)

Kintex-7 XC7K325T 纯硬件 TCP/IP 数据面: 64bit 字流 @125MHz, 当前 1G RGMII 前端
(10G 仅提时钟到 156.25MHz, 流水线不改)。当前顶层 = `board/wrapper_p4.v`
(P4a 阶段: TCP fast path echo + HLS 慢路径 ARP/ICMP/UDP)。
施工日志/决策细节见 `PORT_NOTES.md`, 工程规范见 `CLAUDE.md`。

## 状态

- P0-P3: MAC RX/TX、UDP echo、TCP fast path echo 全部板级 PASS
- P4a 板上 PASS (ARP 免静态 + ping + TCP echo + UDP echo, 板上吞吐 ~110Mbps 稳态)
- 下一步: P4b 正式握手 (SYN/FIN/RST 分流慢路径)

## 综合结果 (P4a)

Vivado 2025.2, `vivado_prj/p4_prj.runs/impl_1` (routed, 2026-08-30):

| 设计 | 时钟 | WNS | LUT | FF | BRAM |
|------|------|-----|-----|----|----|
| wrapper_p4 (整板, placed) | 125MHz (gmii_clk) | **+0.740 ns** | 26537 / 203800 (13.02%) | 17621 / 407600 (4.32%) | 26.5 / 445 (5.96%) |
| udp_echo HLS 慢路径 IP (csynth 估计) | 8.00 ns 目标 | 达成 6.373 ns | 41771 (估计, ~20%) | 17879 | 30 (BRAM18K) |

- WHS = +0.037 ns, 全部时序约束达成 (TNS=0 / THS=0)。
- 数据面 (MAC + fast path RTL) 本体 ~8.3K LUT, 其余为 HLS 慢路径 IP
  (csynth 估计 41.8K LUT, Vivado 优化后整板合计 26.5K)。
- BRAM 含各级 frame FIFO (mac_rx_64 / slow 适配器 / HLS 内部帧缓存)。

## 验证

- xsim 回归: P0×2 + P2×3 + P3×4 + P4a×5 (含 tb_p4_chain 真 HLS 进仿真) 全绿
- 板级: `tools/pc_p4_test.py` (ping / TCP echo / UDP echo);
  吞吐: `tools/pc_throughput_test.py`; 抓包: pktmon (Killer E5000B)
