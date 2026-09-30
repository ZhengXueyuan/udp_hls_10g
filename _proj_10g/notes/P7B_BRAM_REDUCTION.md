# P7B · BRAM 减法调查（A4 路：不换 URAM 的前提下把 BRAM 用量减下来）

- 日期：2026-09-30
- 范围：**只读调查 + 只写本文件**。本轮**不实施**任何改动（用户明确"当前先不动代码"）。
- 与其他路的分工：**URAM 迁移不归本路**；`P7B_BRAM_INVENTORY.md`（另一路 agent 的产出）本路**只读**，
  但截至落笔时**该文件尚不存在**，故本路的归属表是独立从报告与 RTL 重建的（见 §0 证据链）。
- ⛔ 纪律遵守：**未启动任何 Vivado/xsim/xvlog/synth**；只读 `.rpt`；**未碰 `vivado_prj/`** 以外的任何东西，
  `vivado_prj/` 内也只读了综合报告与日志（当时有全实现构建在跑，`impl_1/.route_design.begin.rst` 在位）。
- 终局目标对齐：**低延时行情 UDP 组播 + 交易 TCP** ⇒ "减深度" 与 "减延迟" 同向，本报告对每条减法都标注延迟方向的收益。

---

## §0 基线读数与归属（先把"谁占的"钉死）

### §0.1 基线

| 量 | 读数 | 出处 |
|---|---|---|
| Block RAM Tile | **348 / 480 = 72.50%** | `board/p7b_ku5p_util.rpt`（2026-09-30 17:50，Routed） |
| RAMB36/FIFO | 317 | 同上 |
| RAMB18 | 62 | 同上 |
| URAM | 0 / 64 | 同上 |
| LUT as Memory | 6654 (6.66%)，其中 **distributed RAM 6604** | 同上 |
| LUT as Logic | 65073 (29.99%) | 同上 |
| **构建配置** | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1` | `board/build_p7b_ku5p.tcl:145-149`（`verilog_define`） |

⚠️ **同刻的另一次读数（必须分开记）**：19:39 的**综合**报告（`vivado_prj/p7b_ku5p_prj.runs/synth_1/wrapper_p4_utilization_synth.rpt`）
给出 **281 RAMB36 + 62 RAMB18 = 312 tile** —— 差值 **36** 正是 **xdma_0 的 OOC 网表**（综合期它是 black box，不计数；
实现期链接进来才计）。见 §0.2。

### §0.2 归属表（每片 tile 是谁的）

**证据来源**（两条独立链，互相钉死）：
1. **分层利用率报告** `p6a_ku5p_verify/p6a_t6p4_util_hier.rpt`（`report_utilization -hierarchical -hierarchical_depth 2`，
   P6a 配置 = `APP_MODE=1`，**无** PCIE_OBS / P7b）—— 它把每个例化点的 RAMB36/RAMB18 逐点列出。
2. **OOC 子核报告** `vivado_prj/p7b_ku5p_prj.runs/xdma_0_synth_1/xdma_0_utilization_synth.rpt`（38 RAMB36）、
   `.../pcs64_synth_1/pcs64_utilization_synth.rpt`（**0**）。
3. **新鲜综合报告**（19:39，当前配置）—— 用来证明 P7b 新增件（10G MAC / UDP_TX_OVL / 8 路发生器 / snap_seq / axi_regs）
   **一片 tile 都没加**（281/62 与 P6a 的 RTL 小计逐数相同）。

| # | 块 | 例化点（行号） | RAMB36 | RAMB18 | **tile** | 占 348 的 |
|---|---|---|---|---|---|---|
| 1 | **retx_ram**（TCP 重传环，2 bank × 64K×64） | `rtl/tcp_tx_frame.v` → `u_retx`；声明 `rtl/retx_ram.v:119-120` | **256** | 0 | **256** | **73.6%** |
| 2 | **xdma_0**（厂商 PCIe IP，观测通道） | `board/build_p7b_ku5p.tcl:110-124` | 38（OOC） | 0 | **38** | **10.9%** |
| 3 | **HLS 慢路径** `udp_echo`（`u_hls`） | `hls/slowstack_prj/solution1/syn/verilog/udp_echo.v` | 6 | **62** | **37** | **10.6%** |
| 4 | `tcp_echo.u_fifo` frame_fifo D=8192 | `rtl/tcp_echo.v:93` | 16 | 0 | **16** | 4.6% |
| 5 | `slow_rx_adp.u_ff` / `slow_tx_adp.u_wf` / `udp_split.u_uf`（frame_fifo D=512 ×3） | `rtl/slow_rx_adp.v:94` / `rtl/slow_tx_adp.v:80` / `rtl/udp_split.v:464` | 3 | 0 | **3** | 0.9% |
| 6 | 其余**全部** RTL（fifo_sync / fifo_async / app_* / tcb / tcp_cam / snap_seq / axi_regs / **P7b MAC** / **udp_tx_frame 乒乓**） | —— | **0** | **0** | **0** | **0%** |
| | 合计 | | 319 | 62 | **350** | |

- 与报告的 **348** 差 **2**：xdma 在 OOC 下 38 片、链接后 36 片（链接期可优化），或 RTL 微差。
  **结论不受影响**（第 1 名 256 片是铁证：`p6a_t6p4_util_hier.rpt` 第 107 行
  `u_tcp_tx.u_retx | retx_ram | ... | 256 | 0 |`）。
- ⭐ **一句话**：**这块板子的 BRAM 只有一个问题 —— `retx_ram` 一个人占了 73.6%；
  我们把其余所有 RTL 全加起来只占 0.9%。**
- ⭐ 第二条：**Vivado 把我们所有手写 FIFO（73/76 位宽、8~256 深）全部推断成了分布式 RAM**
  （逐点证据：P6a 分层报告 `u_udp_tx.u_fifo` = 0 RAMB36 + 336 LUTRAM；`u_app_udp.u_txf` = 0 + 336；
  `u_slow_rx.u_ofifo` = 0 + 384；`u_mac_rx.u_fifo` = 0 + 44）。⇒ **手写侧已经没有"BRAM 待减项"**，
  能减的只有 `retx_ram` / HLS / 厂商 IP 三处。

---

## §1 ① 深度过剩表（声明深度 vs 结构上界）

> 口径：**上界必须从 RTL 的握手/流控推出来，不许猜**。每条给出推导与行号。

| 块 | 声明深度 | **结构上界** | 比值 | 上界推导出处 | 可减? |
|---|---|---|---|---|---|
| **retx_ram（每连接）** | 8192 字 = **64 KB** | **6,332 字 = 50,649 B** | **1.29** | `rtl/tcp_tx_frame.v:180-184` + `:190` | ✅ 但见下 |
| **retx_ram（16 连接合计）** | 16 × 64 KB = **1 MB** | **N_biz × 50,649 B** | **16 / N_biz** | `rtl/tcp_cam.v:9`（N=16）、`rtl/tcb.v:8-13`（N=16） | ⭐⭐⭐ **最大一刀** |
| `tcp_echo.u_fifo` | 8192 字 = **64 KB** | **6,873 字 = 54,986 B** | **1.19**（≈按构造取整，见注） | `board/wrapper_p4.v:1126-1145` | ⚠️ 需先降 WIN_POOL |
| `slow_rx_adp.u_ff` / `slow_tx_adp.u_wf` / `udp_split.u_uf`（×3） | 512 字 | **190 字 = 1518 B** | **2.7** | `rtl/frame_fifo.v:4`（"深度必须 >= 单帧最大字数 (1518B = 190 字)"） | ❌ 见 §5-1 |
| `udp_tx_frame` bank ×2（`UDP_TX_OVL`） | 每 bank 256 字 | **189 字** | 1.35 | `rtl/udp_tx_frame.v:20-23` | ❌ 已 LUTRAM |
| `app_udp_pattern.u_txf` | 256 字 | 183 字（1464 B） | 1.40 | `rtl/app_udp_pattern.v:497` + 业务帧几何 | ❌ 已 LUTRAM |
| `fifo_async` u_rxcdc / u_txcdc | 256 字 | 190 字 + 跨域同步迟滞 | 1.35 | `board/wrapper_p4.v:885,2681` | ❌ 已 LUTRAM |
| `tcp_tx_frame.u_fifo` | 256 字 | 188 字 | 1.36 | `rtl/tcp_tx_frame.v:186-190` | ❌ 已 LUTRAM |
| **HLS 的 62 个 RAMB18** | 见表 §1.2 | 见 §1.2 | **利用率 6.2%** | 生成 RTL + 分层报告 | ⭐⭐ **第二刀** |

### §1.1 三条上界的推导（逐条，带算式）

**(a) retx_ram 每连接 —— 50,649 B**

- 声明：`mem_e/mem_o [0:65535]` 64 位，地址 `{conn[3:0], w[12:1]}` ⇒ 每连接每 bank 4096 字 = 32 KB，两 bank = **64 KB**
  （`rtl/retx_ram.v:9, 45-52, 119-120`）。
- 上界：ring 里只需放"**已发出但未被 ACK 的字节**"。
  - 该量的**门**是 `tcb.win_open`（`rtl/tcb.v:142-147`）：`(snd_nxt - snd_una) < min(snd_wnd, WIN_CAP)`，
    `WIN_CAP = 0xBFFE = 49,150`（`rtl/tcb.v:13`，由 wrapper 传 `WIN_CAP_5`，`board/wrapper_p4.v:222,1922`）。
    ⇒ 在飞 ≤ `0xBFFE − 1 = 49,149` B（"<" 的严格性 + 1 拍注册陈旧：`rtl/tcp_tx_frame.v:176-178`）。
  - 再加**已经在写 ring、但尚未计入 snd_nxt 的那一段**：`PLEN_MAX = 1500`（`rtl/tcp_tx_frame.v:190`）。
  - ⇒ **最坏在飞 = 49,149 + 1,500 = 50,649 B = 6,332 字。**
- 比值 = 65,536 / 50,649 = **1.294**。
- ⚠️ **文档缺陷（本轮抓到）**：`rtl/retx_ram.v:6` 与 `rtl/tcp_tx_frame.v:180`、`rtl/tcb.v:141` 三处都写
  "`plen_max 4095 = 53244`"，但 `PLEN_MAX` 现在是 **1500**（`tcp_tx_frame.v:190`）。
  即注释里的 53,244 是**旧值残留**（偏保守 2,595 B）。**结论不变**（50,649 < 65,536，硬界仍成立），
  但引它当"上界"会算错 5%。⇒ 建议顺手订正（**只报不改**）。

**(b) tcp_echo 的 64 KB frame_fifo —— 它是"按全预算造出来的"，不是拍脑袋**

`board/wrapper_p4.v:1126-1145` 把物理界写成一条等式（这是本设计里**唯一一条显式写下来的内存容量不变式**）：

```
Σwinq + N*ACC_MARGIN + Δ(2816) + U(1518) + SEG_MAX(1500) <= 65536
Σwinq <= WIN_POOL = 49152
⇒ N*ACC_MARGIN <= 10550
```
- 左边各项之和的上界 = 49,152 + 10,550 + 2,816 + 1,518 + 1,500 = **65,536 B = 8,192 字** ——
  **恰好等于声明的深度**。⇒ 这个 64 KB 的"过剩"是 **0**：它就是那条等式本身。
- 结论：**要减它，必须先减 `WIN_POOL`**（同一根杠杆，见 §3-2）。

**(c) 三个 512 深 frame_fifo —— 2.7 倍但不可减**

- 上界 190 字（`rtl/frame_fifo.v:4`），声明 512 ⇒ 2.7×。
- **但**：`localparam NB = D/512`（`rtl/frame_fifo.v:93`）—— **主存是"每 512 字一片 RAMB36"的硬结构**，
  D < 512 ⇒ `NB = 0` ⇒ **一块存储都没有**。而且换 RAMB18（512×36）也救不了：
  72 位宽要 2 片 RAMB18 = **同样 1 个 tile**（RAMB18 成对共 tile，见报告脚注）。
- ⇒ **这是"结构上界 190 / 物理最小可表达 512"的粒度损失，不是浪费。**（§5-1）

### §1.2 HLS 侧的"深度过剩"其实是**空间浪费**（62 片装 68 Kb）

HLS 把每个 `static` 数组各自例化成一个独立的 RAM 包装模块，**每个包装模块 = 1 片 RAMB18（或 RAMB36）**，
与数组真实大小无关。逐点读出（`hls/slowstack_prj/solution1/syn/verilog/udp_echo*.v`，
`DataWidth/AddressRange` 参数）：

| 数组（HLS 生成名） | 尺寸 | 位 | 例化**次数** | 占 tile | tile 利用率 |
|---|---|---|---|---|---|
| `ip_rx_process_hdr` | 10 B | **80** | **14** | 14 | **0.44%** |
| `arp_rx_process_arp_bytes` | 14 B | **112** | **10** | 10 | **0.62%** |
| `tcp_conn_*`（cwnd/seq/last_ack/ssthresh/rto/dup_ack/peer_mss/peer_port/state/retrans_pending/flight_size/peer_ip） | 3 项 | 24~96 | **13** | 13 | **0.13~0.5%** |
| `icmp_rx_process_csum_buf` | 128 B | 1,024 | 2 | 2 | 5.7% |
| `tcp_send_seg` | 280 B | 2,240 | 4 | 4 | 12% |
| `tcp_send_bufs` / `tcp_retrans_buf` | 1728 B | 13,824 | 2 | 2 | 75% |
| `*_ip_words`（ip/udp/icmp/igmp/dhcp） | 10×16 | 160 | 5 | 5 | 0.9% |
| `*_iw`（tcp_send / tcp_send_1） | 10×16 | 160 | 2 | 2 | 0.9% |
| `l2_table_ip` / `l2_table_valid` / `l1_age` / `igmp_report` / `cfg_write_w` / `frame_fifo(w32_d512)` | 详见 RTL | 256 ~ 16,384 | 6 | 6 | 1.4~91% |
| **小计（62 片 RAMB18）** | | **≈ 69,600 位** | **上述已逐点列 58 件**（另 ~4 件在 `dhcp_tx_process` 等子模块内未逐点展开，总数由分层报告的 62 片封顶） | **62** = 31 tile | **平均 6.2%** |
| `buffer_r` / `frame_buf` / `l2_table_mac` / `tcp_conn_flight_size`×2 / `tcp_rx_payload` | 768×32 / 400×32 / 256×48 / 3×32×2 / 576×8 | 24,576 / 12,800 / 12,288 / 96×2 / 4,608 | 6 | 6 = 6 tile | 0.27~67% |
| **HLS 合计** | | **≈ 124 Kb** | **68**（逐点可数） | **37 tile**（62 RAMB18 + 6 RAMB36） | **≈ 9.3%**（124 Kb / 1,332 Kb tile 容量） |

⭐ **62 片 RAMB18 装的数据加起来 ≈ 69.6 Kb —— 打包成 RAMB36 只要 2 片。**
这就是"声明与上界脱节"的真实形态：**不是深度声明太大，而是"一个数组一片 tile"的存储类别绑定**。

---

## §2 ② LUTRAM 候选表（正确的换算 + 净账 + 时序风险）

### §2.1 先把换算说对

- **原始位容量**：1 片 RAMB36 = 36 Kb = 36,864 位 = **576 个 RAM64X1**（64 位/LUTRAM）。这一句是对的。
- **但它不是"换 1 片 tile 就要 576 个 LUT"** —— 实测本设计的换算率（Vivado 自己选的、逐点可查）：

| 存储（已 LUTRAM） | 位 | 吃 LUTRAM | **位数 / LUTRAM** |
|---|---|---|---|
| `udp_tx_frame.u_fifo` 256×73 | 18,688 | **336** | **55.6** |
| `app_udp_pattern.u_txf` 256×73 | 18,688 | **336** | **55.6** |
| `slow_rx_adp.u_ofifo` 2048×9 | 18,432 | **384** | **48.0** |
| `frame_fifo` 边存 512×9（×3） | 4,608 | **96** | **48.0** |
| `frame_fifo` 边存 8192×9（tcp_echo） | 73,728 | **1,792** | **41.1**（另加 1,698 逻辑 LUT 做读 mux） |

⇒ **工程换算（本器件/本频率实测）：1 位 LUTRAM ≈ 45~55 位 BRAM 位；等价地
「1 片 RAMB36（36,864 位）≈ 700~820 个 LUTRAM LUT」，深存（>1K）还要再加等量的读 mux 逻辑 LUT。**
⚠️ 所以"用 576 个 LUT 换 1 片 tile"只有在对**深度 ≤64、宽 ≥1** 的小数组上才近似成立 —— 深度一上去就翻倍。

### §2.2 候选表

| 候选 | 省 tile | **吃 LUT**（按上式估） | 净账 | **时序风险** | 判决 |
|---|---|---|---|---|---|
| ⭐ **HLS 的 62 片 RAMB18 → LUTRAM** | **31** | **≈ 1,500~2,500**（40 个 ≤200 位的小件几乎免费：一个 14×8 数组 = 112 位 ≈ 2 个 LUTRAM；贵的是 `frame_fifo` 16,384 位、`tcp_send_bufs`×2 各 13,824 位、`buffer_r` 24,576 位那几件） | **31 tile / 2.5% LUT** —— 极优 | **中**：HLS 跑在 `dp_clk` 156.25 MHz，读口多为寄存器化；但 LUTRAM 读比 BRAM 读多 1~3 级 LUT | ✅ **强烈推荐**（HLS 侧只报不改） |
| 同上，只挑 **≤1 Kb 的那 ≈50 片**（`hdr`(14)/`arp_bytes`(10)/`tcp_conn_*`(13)/`*_ip_words`(5)/`*_iw`(2)/`l1_age`/`igmp_report`/`l2_table_valid`/`csum_buf`(2)） | **≈ 25** | **≈ 400~700** | 25 tile / 0.6% LUT —— 更优 | **低**（这些小数组的读路径本来就在慢 FSM 里） | ✅ **首选起步**（BIND_STORAGE 逐数组加 directive） |
| HLS 的 6 片 RAMB36 里的 4 个小件（`flight_size` 96 位 ×2、`l2_table_mac`、`tcp_rx_payload`） | **+2~4** | **≈ 100~300** | 同族 | 低 | ✅ 一并做 |
| `slow_rx_adp/slow_tx_adp/udp_split` 的 512 深 frame_fifo（主存）→ LUTRAM | 3 | ≈ 2,200 | **3 tile / 2.2% LUT** —— 差 | **高**：在 156 MHz 数据面主通路，且 `frame_fifo` 有 P6a"边存改 RAMB18 丢 tlast"的**板级前科** | ❌ **不做** |
| `tcp_echo.u_fifo` 主存 → LUTRAM | 16 | ≈ 10,000 | 差 | **极高** | ❌ **不做** |
| `retx_ram` → LUTRAM | 256 | ≈ 90,000 | 结构上放不下（LUTRAM 总位 99840×64 = 6.4 Mb，需求 8.4 Mb） | —— | ❌ **不可行** |

---

## §3 ③ 结构性减法清单

> 每条格式：**改什么 / 省多少 tile / 代价是什么 / 怎么验**

### §3-1 ⭐⭐⭐ `retx_ram`：连接数 16 → N_biz（**最大一刀**）

- **改什么**：`tcp_cam/ tcb / app_ctrl / tcp_rx / tcp_tx_frame / retx_ram` 的 `N`（现全为 16：
  `rtl/tcp_cam.v:9`、`rtl/tcb.v:9`、`rtl/app_ctrl.v:442-447` 的 `[0:15]` 槽表）。
- **省多少**：`(16 − N_biz) × 16 tile`。
  - N_biz = 8 ⇒ **省 128 tile**（348 → 220）
  - **N_biz = 4 ⇒ 省 192 tile（348 → 156，-55%）**
  - N_biz = 2 ⇒ 省 224 tile
- **代价**：（a）**产品并发上限**（现在 16 条，业务侧实测是**串行单连接**：
  `P7B_BIZ_S1.md:70` "300 次连接是串行的，`conn_ms` 均值 0.089 ms ≪ `dur_ms` 9.284 ms" ⇒
  16 是**设计值、不是需求值**，需产品确认 N_biz）；
  （b）conn id 位宽从 4 变 log2(N) ⇒ 跨 7 个模块 + HLS 侧 `MAX_TCP_CONN` 的协同改；
  （c）`app_ctrl` 的事件 FIFO/寄存器映射按槽号编址（`rtl/app_ctrl.v:353` EW 位宽）—— 需同步。
- **怎么验**：`sim/p4gates/run_matrix_p4dfix.bat`（P4 16 门）+ `sim/p5d_multi/run_tb_p5_multi.bat {main,neg_*}`（多连接门，
  含负对照）+ `sim/p5e_udp/run_tb_app_udp.bat` + 板级业务门（`P7B_BIZ_PLAN.md` 的 J0/J1/J3）。
- **延迟方向**：**中性**（不改变单连接的在飞上限）。但与 §3-2 叠加后变正。

### §3-2 ⭐⭐ `WIN_CAP` 48 KB → 24 KB（**同时省 tile 又降延迟**）

- **改什么**：**一个 localparam**：`board/wrapper_p4.v:222` 的 `WIN_CAP_5 = 16'hBFFE`
  → `16'h5FFE`。它一处喂三处（`:1214` app_ctrl、`:1922` tcb、`:2070` tcp_tx_frame），
  是**单点改动**（这就是当初把它做成 localparam 的红利）。
- **省多少**：
  - `retx_ram`：每连接 ring 64 KB → 32 KB（上界 24,573 + 1,500 = 26,073 ≤ 32,768 ✓）
    ⇒ **16 tile/连接 → 8 tile/连接**；16 连接共 **省 128 tile**。
  - `tcp_echo.u_fifo`：D 从 8192 降到 4096（32 KB）**当且仅当 WIN_POOL 同时 ≤ ~16 KB**
    （见 §1.1(b) 的等式）⇒ **再省 8 tile**。
  - 合计 **省 136 tile**（348 → 212）；与 §3-1 叠加（N=4 + 24 KB）⇒ retx 256 → **32**、
    tcp_echo 16 → 8 ⇒ **合计省 232 tile（348 → 116，-67%）**。
- **代价**：**每连接的在飞上限 48 KB → 24 KB**（BDP 上限）。量化：
  - RTT ≈ 50 µs（同机房交换机）⇒ 速率上限 ≈ 24 KB/50 µs ≈ **3.9 Gbps/连接**（交易 TCP 绰绰有余）
  - RTT ≈ 1 ms（跨机房）⇒ ≈ **196 Mbps/连接**
  - RTT ≈ 10 ms（跨境）⇒ ≈ **20 Mbps/连接** ← 这是真代价，**必须产品确认目标 RTT**
  - ⚠️ 附带：`P7B_BIZ_S1.md:228` 的 `ACC_MARGIN ≥ 3328` 下界钳位（`board/wrapper_p4.v:1140-1145`）不变。
- **延迟方向**：⭐⭐ **正收益**。RX 侧 64 KB 帧缓冲意味着**最坏 48 KB 的排队**；
  降到 24 KB 把最坏排队延迟**砍半**（10 Gbps 下 48 KB = 38 µs，24 KB = 19 µs；1 Gbps 下 393 µs → 196 µs）。
  这与"低延时行情"的终局目标**同向**。
- **怎么验**：业务门 J0/J1/J3（速率 + 逐字节）+ `sim/p5sim/run_tb_p5_fc.bat`（池/右沿算术边界）+ P5d 动态裕度门
  （`token` 表在 `board/wrapper_p4.v:1130-1145`，是 `tools/gen_stim_p5_adv.py` 的**文本解析目标**，改值必须同步门）。

### §3-3 ⭐ `retx_ram` 的**连接池化**（保留 16 逻辑槽，4 个物理 ring 段 + freelist）

- **改什么**：`retx_ram` 的地址从 `{conn[3:0], w[...]}` 改成 `{base[1:0], w[...]}`，
  `base` 由每连接的"ring 占用中"标志在首段写时分配（cfg ADD 时拿、连接拆除时还）。
- **省多少**：与 §3-1 同（活跃连接 ≤4 时省 192 tile），**但不牺牲逻辑连接数上限**。
- **代价**：**时序**。`retx_ram` 的写地址网是这个工程历史上**最差的一条**——
  `rtl/retx_ram.v:55-63` 记录过 `state_reg → 256 片 RAMB36 的 ADDRBWRADDR` 的 WNS −0.848 / 912 失败端点，
  修法是"入口寄存 1 拍 + `max_fanout` 交工具复制"。加一层 base mux = **在已经最痛的网上再加一级**。
  ⇒ 必须重跑实现确认 WNS（当前 +0.136，余量不宽）。
- **怎么验**：`sim/p4gates` 的 `unit_retx`（⚠️ 该门无条件 `exit 0`，要读日志尾）+
  P5d 多连接门 + **新的池化单元门**（分配/归还/无空闲段时的行为）+ 板级。
- **延迟方向**：中性。

### §3-4 ❌ `retx_ram` 单 bank 化（省 128 tile）—— **结构性不可行，记录在案**

- 现状：`mem_e`/`mem_o` 两个 bank 存在的唯一理由是**一拍内的写可能横跨两个 ring 字**
  （`rtl/retx_ram.v:31-52`：`o4 = w_seq[2:0]`，8 字节写落在任意字节偏移 ⇒ 至多两字）。
- 「改成单 bank + 跨字时拆两拍」的代价是**定量的**：TCP 载荷的字节偏移 `w_seq[2:0]` 在 8 个值里均匀分布
  ⇒ **7/8 的拍会踩到跨字** ⇒ 10G 需要的 8 字节/拍退化成 ~8/7 拍/字 ⇒ **吞吐直接掉 ~12.5%**。
  在没有上游弹性暂存（staging）配合的前提下不可接受。
- 另一半账：`retx_ram` 的 **tile 宽度利用率 = 64/72 = 89%**（RAMB36 没有 64 位模式，72 是最接近的 ≥64）。
  浪费 = 256 × 8 / 72 ≈ **28 片当量**。要回收它得把 ring 字改成 9 字节宽（512×72 用满），
  但那会毁掉"环回 = 掩码"（mod 9 不是位运算）—— `rtl/retx_ram.v:6` 明确说 2^16 是**为了零新增地址逻辑**。
  ⇒ **这 28 片当量是"2^16 字节环 + 字节写使能"的固有代价，不可回收。**

### §3-5 ✅ 结论保留：`UDP_TX_OVL` 乒乓**是必要的**，且**不占 tile**

- 定量：默认帧器 **378 拍/帧**（收 184 + 发 194，两段结构性互斥）→ 4.87 Gbps；
  乒乓 **191 拍/帧** → **实测 9.53 Gbps**（`P7B_RATE_RESULT.md`、`P7B_RATE_FRAMER.md`）。
  即**单 bank 化的代价 = 吞吐砍半（−4.67 Gbps）**，而收益 = **0 片 tile**（两个 bank 都在 LUTRAM 里，各 336 个）。
- ⇒ 这条**不是** tile 减法候选；写在这里是为了防止后来者"看它占地方就砍掉"。

### §3-6 串联重复缓冲：链上每一级的深度与理由（结论：无可合并项）

| 链 | 级 | 深度 | 理由 | 可合并? |
|---|---|---|---|---|
| RX（1G 前端） | `mac_rx_64.u_fifo` | 8 字 | 帧内 CRC 校验期弹性（LUTRAM） | —— |
| RX | `rx_classify.u_wf` | 16 字 | 决策窗（w5 拍）与字流解耦（LUTRAM） | —— |
| RX | `udp_split.u_pre/u_pb` | 16 / 32 字 | 头解析预取 + 透传暂存（LUTRAM） | —— |
| RX | `udp_split.u_uf` | 512 字（**1 tile**） | UDP 载荷整帧判定（rollback）⇒ 必须 ≥190 | ❌ |
| RX→app | **`tcp_echo.u_fifo`** | **8192 字（16 tile）** | **app 的 RX 弹性窗 + 窗口信用源**（`board/wrapper_p4.v:1033` 的 `app_rx_occ` 就是它的占用） | ❌ 见 §1.1(b) |
| TX(app) | `tcp_tx_frame.u_fifo` | 256 字（LUTRAM） | 帧级暂存：UDP/TCP 校验和必须"头发出前载荷已定" | ❌ 与 ring 不可合并（ring 只存已发数据） |
| TX(app) | `retx_ram`（**256 tile**） | 16×64 KB | 重传环 | ❌ |
| TX(app, UDP) | `app_udp_pattern.u_txf` + `udp_tx_frame` bank×2 | 256 ×3（LUTRAM） | 8 路发生器的组帧 + 校验和暂存 —— **同一份载荷确实被缓冲两次** | ⚠️ 可合并但**只省 LUTRAM 不省 tile**，见 §5-4 |
| CDC | `u_rxcdc` / `u_txcdc` | 256 / 256（LUTRAM） | 125↔156.25 MHz 跨域弹性（≥ 一帧 190 字） | ❌ |

### §3-7 厂商件

| 件 | tile | 可否减 |
|---|---|---|
| `xdma_0` | **38（10.9%）** | 这是**设计外的最大一块**。产品成型时若观测/主机通道能换成"只留 AXI-Lite + 自写 BAR"（我们已有 `axi_regs`，**0 tile**）或更小的 DMA，38 片全回来。**但这是产品决策 + 厂商 IP，不归本路。** |
| `pcs64`（xxv_ethernet PCS/PMA 64-bit，2 通道） | **0** | 无 |
| `udp_echo`（HLS 慢路径） | 37 | 见 §1.2/§2.2（**唯一的"我们的"HLS 大头**） |

---

## §4 ④ 净收益排序（前 5 名）

| # | 减法 | **能省多少 tile** | **代价** | **风险** | 延迟方向 |
|---|---|---|---|---|---|
| **1** | **HLS 的 62 片 RAMB18（先做 ≤1 Kb 的 ~45 片）→ LUTRAM**（`BIND_STORAGE` / `RAM_STYLE` 逐数组 directive，**HLS 侧只报不改**） | **22 ~ 31** | **≈ 400 ~ 2,500 LUT**（LUTRAM 余量 93%，用掉 0.6~2.5%） | 低-中。小件几乎无风险；`buffer_r`/`frame_fifo`/`tcp_send_bufs` 那几件要单独看 WNS | 中性 |
| **2** | **`retx_ram` N: 16 → 4** | **192**（348→156，−55%） | 产品并发上限（业务实测**串行单连接**，16 是设计值非需求值，待确认 N_biz）+ 跨 7 模块 conn id 参数化 | 中（协同改面广，但**不碰时序**——位宽变小只会更快） | 中性 |
| **3** | **`WIN_CAP` 48 KB → 24 KB**（`wrapper_p4.v:222` 一处） | **128**（retx 减半）+ 8（tcp_echo，需 WIN_POOL 同步） = **136** | 每连接在飞上限 48→24 KB：RTT 50 µs ⇒ 3.9 Gbps/连接、1 ms ⇒ 196 Mbps/连接、10 ms ⇒ 20 Mbps/连接 | 中。改的是**判据表里的数**（`token` 表 + P5d 裕度门需同步），且有硬界等式要重推 | ⭐ **正**（RX 排队延迟砍半） |
| **4** | **2+3 叠加（N=4 + 24 KB）** | **232**（348→**116**，−67%） | 上两条的代价之和 | 中 | **正** |
| **5** | `retx_ram` 连接池化（保 16 槽） | 同 #2（≤192） | **动的是全工程最差的地址网**（`retx_ram.v:55-63` 的 −0.848 历史） | **高（时序）** | 中性 |
| — | 3 个 512 深 frame_fifo → LUTRAM | 3 | 2,200 LUT | 高 + 有 P6a 边存前科 | —— ❌ 不推荐 |
| — | `xdma_0` | **38** | 产品/厂商决策 | —— | 不归本路 |

**最短路径建议**：先做 **#1**（不碰数据面时序、不碰产品语义、纯 HLS directive，一次重综合即可读数），
同时请产品确认 **N_biz 与目标 RTT** 以决定 #2/#3 的力度。

---

## §5 ⑤ 减不动的部分与理由（一句话/条）

1. **3 个 512 深的 frame_fifo（3 tile）**：上界只要 190 字，但 `NB = D/512` 是硬结构（`frame_fifo.v:93`），
   D<512 ⇒ 0 存储；换 RAMB18 也是同 1 个 tile ⇒ **粒度损失，不可减**。
2. **`retx_ram` 的 28 片当量宽度浪费**："2^16 字节环 + 字节写使能" + "RAMB36 无 64 位模式"的固有代价，不可回收（§3-4）。
3. **`retx_ram` 的单 bank 化**：写口需同拍落两字，拆拍 = 7/8 的拍掉一半吞吐 ⇒ 不可行（§3-4）。
4. **`UDP_TX_OVL` 乒乓的第二个 bank**：吃 LUTRAM 不吃 tile，且它是 9.53 Gbps 的来源 ⇒ **不能砍**（§3-5）。
5. **`tcp_echo` 的 64 KB**：它就是 wrapper 那条物理界等式的右边（0 过剩），要减只能动 `WIN_POOL`（§1.1(b)）。
6. **我们手写的其余全部 RTL：0 tile**（Vivado 把 73/76 位宽的手写 FIFO 全推断成分布式 RAM）⇒ **这块没有可减项**。
7. **`pcs64`：0 tile** ⇒ 10G 前端的 PCS/PMA 一点 BRAM 都没吃（免费）。

---

## §6 ⑥ 不确定与待实验项（**本轮不实施**）

| # | 不确定 | 怎么实验（下一轮） | 预期读数 |
|---|---|---|---|
| U1 | HLS 62 片 RAMB18 改 LUTRAM 后的**真实 LUT 代价与 WNS** | 只改 `hls/src` 的 directive（或 `hls/run_hls_active.tcl` 的 BIND_STORAGE），重跑 HLS，再跑一次 KU5P 实现 | LUT +0.6~2.5%，WNS 变化（判据：≥0） |
| U2 | 哪些 HLS 数组**带初值/异步复位**因而结构性不能 LUTRAM 化 | 逐个读生成 RTL 的 `q0_rom`/`written` 逻辑（`_RAM_*_1R1W.v` 里已有 ROM 路径） | 逐数组给"可/不可"表 |
| U3 | N_biz 与目标 RTT（**产品输入**） | 问产品：并发连接数上限？目标 RTT 档？ | 决定 §3-1/§3-2 力度 |
| U4 | `WIN_CAP` 改动对既有门的影响面 | grep 全仓 `0xBFFE` / `10550` / `ACC_MARGIN` / `WIN_POOL` 的**硬编码副本** | 我已知至少 6 处（wrapper `:222,1033,1130-1145`、tcb `:13`、tcp_tx_frame `:184`、app_ctrl `:195-216`）+ 门脚本的**文本解析点** |
| U5 | 连接池化的时序代价 | 先做**只读**估算：在 `retx_ram` 写地址路径上加一级 base mux 的级数，再决定是否值得 | 若 WNS < +0.05 则不划算 |
| U6 | `frame_fifo` 主存的 8 位宽度浪费（23 片 × 8/72 ≈ 2.6 片当量）能否靠**奇偶位**回收 | 实验：把 `{tlast, tkeep[7:0]}` 编成 5 位（tkeep 只用 4 位：合法值只有 9 种）后，能否声明成 72 位宽让 Vivado 用满 DINP/DOUTP | ⚠️ **有前科**：P6a 把边存挪到 RAMB18 **板级丢 tlast**（`frame_fifo.v:10-13`）⇒ 任何动边存的动作**必须板级验证**，不能只靠单元 TB |
| U7 | 板级 348 tile 与我的归属表 350 差 2 | 等当前实现跑完，读 `impl_1/*_utilization_placed.rpt` + 重跑一次 `-hierarchical` | 定位那 2 片 |

---

## §7 证据索引（本报告引用的全部原件）

| 用途 | 文件 | 关键行 |
|---|---|---|
| 基线利用率 | `board/p7b_ku5p_util.rpt` | BLOCKRAM 节（348/317/62） |
| 当前配置**新鲜综合**读数 | `vivado_prj/p7b_ku5p_prj.runs/synth_1/wrapper_p4_utilization_synth.rpt` | 281/62 |
| **逐例化点归属**（本报告的核心证据） | `p6a_ku5p_verify/p6a_t6p4_util_hier.rpt` | 第 107 行 `u_retx … 256`；第 43-78 行 `u_hls … 6/62` |
| xdma 的 BRAM | `vivado_prj/p7b_ku5p_prj.runs/xdma_0_synth_1/xdma_0_utilization_synth.rpt` | 38 RAMB36 |
| pcs64 的 BRAM | `vivado_prj/p7b_ku5p_prj.runs/pcs64_synth_1/pcs64_utilization_synth.rpt` | 0 |
| 构建宏 | `board/build_p7b_ku5p.tcl` | `:145-149` |
| 重传环声明与理由 | `rtl/retx_ram.v` | `:3-9`（64KB 理由）、`:55-63`（最差地址网）、`:119-120`（声明） |
| ring 门控帽与在飞上界 | `rtl/tcp_tx_frame.v` | `:180-184`（**陈旧 53244**）、`:190`（PLEN_MAX=1500） |
| 同一上界在 tcb 侧 | `rtl/tcb.v` | `:13`（WIN_CAP）、`:139-147` |
| **RX 物理界等式**（tcp_echo 深度的唯一依据） | `board/wrapper_p4.v` | `:1126-1145` |
| frame_fifo 结构（NB=D/512 硬粒度、边存 LUTRAM、P6a 前科） | `rtl/frame_fifo.v` | `:4`、`:10-13`、`:93`、`:217-236` |
| frame_fifo 例化点 | `rtl/tcp_echo.v:93`、`rtl/udp_echo.v:76`、`rtl/slow_rx_adp.v:94`、`rtl/slow_tx_adp.v:80`、`rtl/udp_split.v:464` | —— |
| 乒乓帧器（UDP_TX_OVL） | `rtl/udp_tx_frame.v` | `:20-23`、`:67-86`、`:161-172` |
| UDP 深度的业务口径 | `rtl/udp_split.v` | `:156-160`（UDP_AW=9 = 512 字 = 4KB） |
| 窗口/裕度参数面 | `rtl/app_ctrl.v` | `:195-216`、`:403-406`、`:675` |
| HLS 数组尺寸（生成 RTL） | `hls/slowstack_prj/solution1/syn/verilog/udp_echo.v` | `:1690-2160`（逐数组 `DataWidth/AddressRange`） |
| HLS 数组声明（C 侧） | `hls/src/layer_tcp.cpp:127-128,330`、`hls/src/eth_types.h:25` | —— |
| 业务并发实测（串行单连接） | `_proj_10g/notes/P7B_BIZ_S1.md` | `:70`、`:228` |
| 10G 速率读数（乒乓的必要性） | `_proj_10g/notes/P7B_RATE_RESULT.md`、`P7B_RATE_FRAMER.md`、`udp_hls_10g/CLAUDE.md` RATE 里程碑节 | —— |

### 本轮的方法学备注（留给后来者）
- **"谁占的"必须先钉死再谈减法**：`report_utilization -hierarchical -hierarchical_depth 2` 是唯一能给出
  "逐例化点 RAMB36/RAMB18" 的报告，本报告的排序完全建立在那张表上（而不是"某个模块看着像"）。
  ⚠️ 它同时也暴露一个**证据陷阱**：深度 2 的行里，子模块的 RAM tile **已经被计入父模块行**，
  直接相加会重复计数 —— 我这次是按"依赖树"逐行核对的（`u_hls` 62 RAMB18 与 62 个例化点逐点对账）。
- **上界必须从 RTL 推出并落到行号**：本报告里三条可用的上界（50,649 B / 65,536 B / 190 字）都是从
  `RING_CAP`、`PLEN_MAX`、`WIN_POOL`、`ACC_MARGIN` 的**真实取值**算出来的；顺手抓到一处
  **陈旧注释（53244 vs 50,649）**，正是"读注释不算数"这条纪律的又一次应验。
