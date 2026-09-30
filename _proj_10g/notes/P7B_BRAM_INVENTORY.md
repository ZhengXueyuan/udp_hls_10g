# P7B · 全设计存储占用清点与归属（A1 路：**谁用的**）

- 日期：**2026-09-30**（数据取当日晚间 P7b 线速构建）
- 器件：`xcku5p-ffvb676-1-e`
- 本路问题：**这些 BRAM 到底是谁用的、在哪、能不能减、能不能换 URAM** —— 本文件只回答 **"谁用的"**，
  并对 URAM 可替代性给**初步标记**（不改代码）。
- 本路纪律：**只读 + 只写本文件**。未启动任何 Vivado / xvlog / xsim / synth；未碰 `vivado_prj/`
  下除 `*.rpt`（只读）之外的任何东西。落笔时**有一个全实现构建正在跑**（`impl_1/.route_design.begin.rst` 在位）。
- 用户明确"当前先不动代码" ⇒ 本文件**不含任何改动**，只有读数、归属与判据。
- 与并行路的关系：`_proj_10g/notes/P7B_BRAM_REDUCTION.md`（A4 路：不换 URAM 的减法）是独立重建的归属表；
  本文件的**新东西**是：① 逐实例的**全量**清单（含 LUTRAM 与 HLS 内部）；② 把 **348 的差额收口到 0**（见 §2，
  A4 路当时留了"差 2"的尾巴，本文件用 `_proj_pcie` 的 PCIe-min 构建把它**实测钉死**）。

---

## §0 一句话结论

1. **`retx_ram`（TCP 重传环）一个人占 256 / 348 = 73.6% 的 Block RAM Tile。**
2. **第 2、3 名都不是我们手写的逻辑**：厂商 `xdma_0` 36 tile（10.3%）、HLS 慢路径 `udp_echo` 37 tile（10.6%）。
3. **全部手写数据面 RTL（除 `retx_ram` 与 4 个 `frame_fifo`）对 BRAM 的贡献是 0 片** ——
   所有手写 FIFO 都被推断成了 **LUTRAM（分布式）**，一片 BRAM 没占。
4. ⇒ **BRAM 问题只有一个：`retx_ram`。** 把它的 256 片拿掉，占用从 **72.5% → 19.2%（92/480）**。
5. ⇒ 而 `retx_ram` **恰好是全设计唯一被综合器点名"本该用 URAM"的存储器**（Synth 8-6792/8-6793，见 §5）。

---

## §1 清点表

### §1.0 基线读数（**三个阶段的报告必须分开记，混用会得出错误结论**）

| 阶段 | 文件 | Block RAM Tile | RAMB36E2 | RAMB18E2 | URAM | LUT as Mem |
|---|---|---|---|---|---|---|
| **综合**（XDMA 此时是黑盒） | `vivado_prj/p7b_ku5p_prj.runs/synth_1/wrapper_p4_utilization_synth.rpt`（2026-09-30 19:39） | **312** | **281** | **62** | 0 | 5427（dist 5388） |
| **实现·放置**（XDMA 已链接） | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_utilization_placed.rpt`（19:48） | **348** | **317** | **62** | 0 | **6654（dist 6604）** |
| **实现·布线** | `board/p7b_ku5p_util.rpt`（17:50，本轮) | 348 | 317 | 62 | 0 | 6654 |

> ⚠️ **tile 换算**：`Block RAM Tile = RAMB36 数 + ⌈RAMB18 数/2⌉`。本设计里 RAMB18 恒为偶数
> （62 = 31 对），故 `348 = 317 + 31`，与报告逐数吻合。**本设计没有任何 `FIFO36E2/FIFO18E2` 原语**
> （Primitives 表里 BLOCKRAM 类只有 `RAMB36E2`×317 + `RAMB18E2`×62）⇒ 全部 BRAM 都是**推断或显式例化的 RAMB**。
> 构建宏：`APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1`（`board/build_p7b_ku5p.tcl:145`）。

### §1.1 BRAM 逐实例清单（**这是全部 348 tile 的来源，一条不漏**）

`tile` 列的归属证据 = 下面的 **分层报告**（见 §2.1 说明为何用 P6a 的报告）。

| # | 例化名（层次路径） | 声明/例化点 | 模块 | 推断/例化出的原语 | 深度 × 宽度 | 总位数 | RAMB36 | RAMB18 | **tile** |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `u_tcp_tx.u_retx.{g_byte[*].mem_e,mem_o}` | **`rtl/retx_ram.v:119-120`** | `retx_ram` | 推断 `RAMB36E2` ×256 | **2 bank × 65536 × 64** | 8,388,608 | **256** | 0 | **256** |
| 2 | `u_hls`（HLS 慢路径全体，20 个 RAM 实例） | `hls/slowstack_prj/solution1/syn/verilog/udp_echo*.v` | `udp_echo` | `RAMB36E2`×6 + `RAMB18E2`×62 | 见 §1.4 | ≈ 75 kbit | 6 | **62** | **37** |
| 3 | `u_pcie_xdma` | `board/build_p7b_ku5p.tcl:110-124`（IP） | `xdma_0` | 厂商网表内 `RAMB36E2` | 厂商内部（descriptor/credit） | —— | 36 | 0 | **36** |
| 4 | `u_tcp_echo.u_fifo.gen_mem[*].u_main` | **`rtl/frame_fifo.v:147`**（例化点 `rtl/tcp_echo.v:93`） | `frame_fifo` | **显式 `RAMB36E2`**（x72 SDP） | 8192 × 73 | 598,016 | **16** | 0 | **16** |
| 5 | `u_slow_rx.u_ff.gen_mem[*].u_main` | `rtl/slow_rx_adp.v:94` | `frame_fifo` | 显式 `RAMB36E2` | 512 × 73 | 37,376 | 1 | 0 | **1** |
| 6 | `u_slow_tx.u_wf.gen_mem[*].u_main` | `rtl/slow_tx_adp.v:80` | `frame_fifo` | 显式 `RAMB36E2` | 512 × 73 | 37,376 | 1 | 0 | **1** |
| 7 | `u_udp_split.u_uf.gen_mem[*].u_main` | `rtl/udp_split.v:464` | `frame_fifo` | 显式 `RAMB36E2` | 512 × 73 | 37,376 | 1 | 0 | **1** |
| | **合计** | | | | | | **317** | **62** | **348** |

**逐条求和 = 317 RAMB36E2 + 62 RAMB18E2 = 348 Block RAM Tile —— 与报告实测 348 逐数相等，差额 = 0。**

> `retx_ram` 的 256 是**独立三证**：① RTL 自身注释 `rtl/retx_ram.v:56` 写"256 片 RAMB36"、`:60` 写"原 128/bank"；
> ② 分层利用率报告逐点列出 `u_retx | retx_ram | RAMB36 = 256`；③ 按器件容量反算：
> `65536 深 × 64 位 × 2 bank` ÷ 每片 `512×72`（x72 SDP）= 2×128 = 256 片。

### §1.2 显式原语例化点（RTL 里直接写 `RAMB36E2` 的地方，**只有一处**）

| 文件:行 | 原语 | 说明 |
|---|---|---|
| `rtl/frame_fifo.v:147` | `RAMB36E2` | `DEV_USP` 分支（UltraScale+）。**x72 SDP：写口 B / 读口 A，`DOA_REG=0`（1 拍读延迟）**；`WRITE_WIDTH_B=72 / READ_WIDTH_A=72`；`ENBWREN` 恒 1（写使能低时"该写会丢"，见该文件头注释） |
| `rtl/frame_fifo.v:185` | `RAMB36E1` | **非** `DEV_USP` 分支（K7）。⚠️ **P7b 构建走的是 E2 分支**，E1 那半不综合 |

`gen_mem` 的片数 = `NB = D/512`（`rtl/frame_fifo.v:93`）⇒ 8192 深 = 16 片、512 深 = 1 片。这四个深度是**唯一**能推出上述 19 片的公式，已逐数对上。

### §1.3 LUTRAM / 分布式（**占 0 片 BRAM，吃 6604 个 LUT**）

⚠️ **本节全部条目对 Block RAM Tile 的贡献 = 0**。列出来是因为它们是 `LUT as Memory 6654 / 6.66%` 的构成，
而且**回答了"为什么手写侧一片 BRAM 都没占"**：手写 FIFO 都是 **FWFT/组合读**，综合器只能落分布式。

| 例化名 | 文件:行 | 模块 | 宽 × 深 | 位数 |
|---|---|---|---|---|
| `u_rxcdc` | `board/wrapper_p4.v:885` | `fifo_async`（**FWFT=1**） | 76 × 256 | 19,456 |
| `u_txcdc` | `board/wrapper_p4.v:2681` | `fifo_async`（FWFT=1） | 73 × 256 | 18,688 |
| `u_tcp_tx.u_fifo` | `rtl/tcp_tx_frame.v:645` | `fifo_sync` | 73 × 256 | 18,688 |
| `u_udp_tx.u_fifo_a` | `rtl/udp_tx_frame.v:161` | `fifo_sync`（`UDP_TX_OVL` 乒乓 A） | 73 × 256 | 18,688 |
| `u_udp_tx.u_fifo_b` | `rtl/udp_tx_frame.v:167` | `fifo_sync`（乒乓 B） | 73 × 256 | 18,688 |
| `u_app_udp.u_txf` | `rtl/app_udp_pattern.v:497` | `fifo_sync` | 73 × 256 | 18,688 |
| `u_slow_rx.u_ofifo` | `rtl/slow_rx_adp.v:115` | `fifo_sync` | 9 × 2048 | 18,432 |
| `u_slow_tx.u_ififo` | `rtl/slow_tx_adp.v:40` | `fifo_sync` | 9 × 2048 | 18,432 |
| `u_udp_split.u_desc` | `rtl/udp_split.v:506` | `udp_split_fifo` | 64 × 64 | 4,096 |
| `u_udp_split.u_pb` | `rtl/udp_split.v:718` | `udp_split_fifo` | 76 × 32 | 2,432 |
| `u_app_ctrl.u_evfifo` | `rtl/app_ctrl.v:353` | `fifo_sync` | 102 × 16 | 1,632 |
| `u_tcp_tx.u_ackq` | `rtl/tcp_tx_frame.v:710` | `fifo_sync` | 39 × 32 | 1,248 |
| `u_mac_rx.u_fifo` | `_proj_10g/p7b_mac/rtl/mac_rx_10g.v:492` | `fifo_sync` | 76 × 16 | 1,216 |
| `u_classify.u_wf` | `rtl/rx_classify.v:88` | `fifo_sync` | 76 × 16 | 1,216 |
| `u_udp_split.u_pre` | `rtl/udp_split.v:371` | `udp_split_fifo` | 76 × 16 | 1,216 |
| `u_mac_tx.u_fifo` | `_proj_10g/p7b_mac/rtl/mac_tx_10g.v:91` | `fifo_sync` | 73 × 16 | 1,168 |
| `u_slow_cfg.u_fifo` | `rtl/slow_cfg_adp.v:64` | `fifo_sync` | 32 × 16 | 512 |
| `u_tcp_echo.u_cq` | `rtl/tcp_echo.v:108` | `fifo_sync` | 4 × 64 | 256 |
| | | | **小计** | **146,064** |

**另外两族分布式存储（`(* ram_style = "distributed" *)` 显式强制）：**

| 例化名 | 文件:行 | 内容 | 位数 |
|---|---|---|---|
| `u_tcp_echo.u_fifo.gen_side.mem_s` | `rtl/frame_fifo.v:226` | side 段（tkeep+tlast, 9 位）× 8192 | 73,728 |
| 同上 ×3（slow_rx / slow_tx / udp_split 的 512 深 frame_fifo） | 同上 | 9 位 × 512 ×3 | 13,824 |
| `u_udp_split.*.mem`（3 个 `udp_split_fifo` 的存储体） | `rtl/udp_split.v:114` | 见上表 | （已计入） |
| `u_udp_split.{wh_word[0:7], wh_slot[0:7]}` | `rtl/udp_split.v:793-794` | 写头影子寄存器 8×64 + 8×AW | 584 |
| `u_udp_split.v6_mem[0:3]` | `rtl/udp_split.v:1276` | 89 位 × 4 | 356 |

**逐条求和** ≈ **234,556 bit ≈ 3,665 个 LUT6 当量**（64 bit/LUT6）。
**实测**：placed 报告 `LUT as Distributed RAM = 6604`，其中 **XDMA OOC 单独就占 1768**（⇒ RTL 侧 ≈ 4836）。
**差额 ≈ 1170 LUT 未逐条对账**，候选来源：HLS 内部被推断为 LUTRAM 的小表（`8-6904` 列表里有 8 个）、
扇出复制（`retx_ram` 的地址网被复制成 384/1152 份，见 `rtl/retx_ram.v:93`）、以及 `F7/F8 Mux` 的计法差异。
⇒ **本节是估算，不是逐条实测**（BRAM 那节才是逐条实测）。

**控制/状态类小数组（几乎全是 FF，不构成存储块，仅登记）**：
`rtl/tcb.v:72-78`（7 个 ×16）、`rtl/tcp_cam.v:36-40`（5 个 ×16）、`rtl/app_ctrl.v:383-447`（12 个 ×16）、
`rtl/tcp_tx_frame.v:227,240,249,250`（4 个 ×16）、`rtl/tcp_rx.v:212`（1 个 ×16）、
`rtl/udp_tx_frame.v:145-150`（5 个 ×2）、`rtl/app_udp_pattern.v:746`（`ev_f[0:7]`）、
`rtl/app_status_uart.v:610`（`ch_r[0:112]`）。

### §1.4 HLS 内部存储器逐条（`u_hls` = `udp_echo`）

尺寸取自各 `*_RAM_*.v` 的例化参数（`.DataWidth / .AddressRange`）；**tile 归属**取自分层报告。

**占 `RAMB36E2` 的 6 条（注意第 5、6 条：96 bit 占了一整片 RAMB36）：**

| 例化名 | 模块 | 深 × 宽 | 位数 | RAMB36 | BRAM 利用率 |
|---|---|---|---|---|---|
| `buffer_r_U` | `udp_echo_buffer_r_RAM_2P_BRAM_1R1W` | 768 × 32 | 24,576 | 1 | 67% |
| `frame_buf_U` | `udp_echo_frame_buf_RAM_AUTO_1R1W` | 400 × 32 | 12,800 | 1 | 35% |
| `l2_table_mac_U` | `udp_echo_l2_table_mac_RAM_2P_BRAM_1R1W` | 256 × 48 | 12,288 | 1 | 33% |
| `grp_tcp_rx_process_fu_1827` 内 1 块 | （`tcp_rx_process_payload` 576×8 等） | — | — | 1 | —— |
| `tcp_conn_flight_size_U` | `udp_echo_tcp_conn_flight_size_RAM_2P_BRAM_1R1W` | **3 × 32** | **96** | 1 | **0.26%** |
| `tcp_conn_peer_ip_U` | 同上（`_11` 变体） | **3 × 32** | **96** | 1 | **0.26%** |

**占 `RAMB18E2` 的 62 片（= 31 tile）** —— 按分层报告逐父节点：

| 父节点 | RAMB18 | 父节点 | RAMB18 |
|---|---|---|---|
| `grp_tcp_rx_process_fu_1827` | 7 | `grp_udp_tx_process_fu_2004` | 4 |
| `grp_tcp_active_tick_fu_2164` | 6 | `l1_age_U` | 1 |
| `grp_arp_rx_process_fu_1773` | 4 | `l2_table_ip_U` | 1 |
| `grp_icmp_rx_process_fu_1942` | 4 | `l2_table_valid_U` | 1 |
| `grp_tcp_send_fu_2113` | 4 | `tcp_conn_cwnd_U` | 1 |
| `grp_tcp_send_1_fu_2055` | 4 | `tcp_conn_last_ack_recv_U` | 1 |
| `grp_igmp_rx_process_fu_1923` | 3 | `tcp_conn_seq_U` | 1 |
| `grp_dhcp_tx_process_fu_1977` | 2 | `tcp_conn_ssthresh_U` | 1 |
| `grp_ip_rx_process_fu_1766` | 2 | `tcp_retrans_buf_U` | 1 |
| `frame_fifo_fifo_U`（`udp_echo_fifo_w32_d512_A`） | 1 | `tcp_send_bufs_U` | 1 |

> 上表**逐行相加 = 50**，而 `u_hls` 父行 = **62**。差 **12 片在 depth-3 节点里**（本报告用的是
> `-hierarchical_depth 2`，孙节点被聚合进其父行；`ram_style` 报告只列到 depth 2）——
> 典型是 `tcp_conn_*` 那批 3 项小表在多个 `grp_tcp_*` 里**各被例化一次**。⚠️ **不要把 50 当 62 用。**

**HLS 侧的浪费点（可直接点名的）**：至少 **2 片 RAMB36 + ~24 片 RAMB18** 装的是**几百 bit 状态**
（`tcp_conn_*` 全是 3 项 × 8/16/27/31/32 位）。综合器对它们**已经报过建议**：
`INFO: [Synth 8-7082] ... is implemented as Block RAM but is better mapped onto distributed LUT RAM for the following reason(s): The depth (2 address bits) is shallow.`

### §1.5 IP / 厂商件

| IP | 例化点 | 器件内 BRAM（**实测**） | 证据 |
|---|---|---|---|
| **`xdma_0`**（PCIe 观测通道） | `board/wrapper_p4.v:3749` | **36 tile**（in-context，实现后） | `_proj_pcie/pcie_min_util.rpt`（同器件 + **同 XDMA CONFIG** 的 PCIe-min 构建，Routed）= `Block RAM Tile 36`；OOC 单独报告 = 38（见 §2.3） |
| **`pcs64`**（`xxv_ethernet`，CORE = Ethernet PCS/PMA 64-bit） | `board/wrapper_p4.v:389` | **0** | `vivado_prj/p7b_ku5p_prj.runs/pcs64_synth_1/pcs64_utilization_synth.rpt` = `Block RAM Tile 0`；`pcs64_sim_netlist.v` 里 `RAMB*` 出现 **0** 次 |
| 厂商 `pcs64_pkt_gen_mon*.v` 例程件 | **不导入本构建**（`p7b_pcs_stub.v` 只在仿真用；`build_p7b_ku5p.tcl:18` 明写不导入） | **0** | 构建脚本 |
| `clk_gen_p6b`（MMCM） | `board/wrapper_p4.v:692` | **0** | 只有 MMCM，无存储 |
| 新型号 MAC `mac_rx_10g` / `mac_tx_10g` | `board/wrapper_p4.v:807 / 2705` | **0** | 独立 OOC 设计 `_proj_10g/p7b_mac_synth/reports/B_WithMac_util_hier_routed.rpt`（`xxv_mac_top`）BRAM 列全 0；源码里只有标量 `reg`，无数组 |
| `util_gmii_to_rgmii{,_us}.v` / `uart_dbg.v` / `axi_regs.v` / `snap_cdc.v` / `snap_seq.v` / `vlan_strip.v` / `checksum16.v` / `crc32*` / `axis_pipe.v` / `tx_arb.v` | — | **0** | 源码里无存储数组（`snap` 窗口是 **FF** 打的，不是 RAM） |
| `dbg_line_tx`（`u_dbg_line`） | `board/wrapper_p4.v:2944` | **0** | 分层报告 |

> ⚠️ **`xpm_*` 一个都没用** —— 全设计无 `xpm_memory` / `xpm_fifo` 例化（已全仓 grep）。
> 所有 FIFO 都是本仓手写的 `fifo_sync` / `fifo_async` / `frame_fifo` / `udp_split_fifo`。

### §1.6 **存在但未参与本构建**的存储器（不算 tile，但别踩）

| 文件:行 | 内容 | 为什么不算 |
|---|---|---|
| `rtl/udp_echo.v:76` | `frame_fifo #(.W(73),.D(2048),.AW(11)) u_fifo`（若被综合 = **4 片 RAMB36**） | 这是**旧手写 stub**。✅ **已双向验证**：① 综合日志点名综合的是 `.../sources_1/imports/verilog/udp_echo.v:9`（HLS 版，`board/p7b_ku5p_stdout.txt:623`）；② `p7b_ku5p_prj.xpr` 里**没有** `rtl/udp_echo.v`。⚠️ 但 `board/run_preflight.bat` 曾因"库里有它"而 elaborate 失败（见仓 CLAUDE.md 坑 24 ④） |
| `rtl/frame_fifo.v:185` | `RAMB36E1` 分支（非 US+） | `DEV_USP` 已定义 ⇒ 不综合 |
| `rtl/udp_tx_frame.v:517` | `fifo_sync #(.W(73),.D(256)) u_fifo`（`else` 分支） | `UDP_TX_OVL` 已定义 ⇒ 走 `u_fifo_a/u_fifo_b` 乒乓 |
| `rtl/mac_rx_64.v:364`、`rtl/mac_tx_64.v:70` | 1G 前端的 `fifo_sync`（8×76 / 16×73） | `P7B_10G` 已定义 ⇒ 走 `mac_rx_10g/mac_tx_10g` |
| `_proj_10g/p7b_mac/rtl/*` 之外的同名副本 | —— | 无 |

---

## §2 与报告对账（**关键**）

### §2.1 报告里**有没有**层级分解？—— **没有**

- ⛔ **`impl_1/wrapper_p4_utilization_placed.rpt` 里没有任何 RAMB 层级分解**：它是 `report_utilization`
  **不带 `-hierarchical`** 的产物，BLOCKRAM 节只有**一张全局表**（`Block RAM Tile / RAMB36/FIFO / RAMB18 / URAM`），
  没有 per-instance 行。
- ⛔ 本轮构建**没有** `report_ram_utilization` 的产物，**也没有** `report_utilization -hierarchical` 的产物
  （已全仓 `find`/`grep "Utilization by Hierarchy"` 确认；现存的 `*_util_hier.rpt` 全部来自**别的构建**，见下）。
- ✅ **替代证据链**（三条，互相独立，见 §2.2/§2.3）。

### §2.2 三级读数链（把 348 拆成"RTL"与"IP"两半）

| 级 | 构建/报告 | 读到的 Block RAM Tile | 含义 |
|---|---|---|---|
| ① | **P6**（K7）`p6_verify/p6_t6p4_util_hier.rpt`（`-hierarchical -depth 2`，Design = `wrapper_p4`） | **281 R36 + 62 R18 = 312** | 分层逐点：`u_tcp_tx.u_retx = 256`、`u_tcp_echo.u_fifo = 16`、`u_hls = 6+62`、`u_slow_rx/u_slow_tx/u_udp_split = 1/1/1` |
| ② | **P6a**（**KU5P**，`APP_MODE+DEV_USP`，**无 PCIE_OBS/DP_156MHZ**）`p6a_ku5p_verify/p6a_t6p4_util_hier.rpt` | **281 R36 + 62 R18 = 312** | 与①**逐实例逐数相同** ⇒ RTL 侧归属在两种器件上都成立 |
| ③ | **P7b 本构建·综合**（XDMA 是黑盒，0 BRAM）`synth_1/wrapper_p4_utilization_synth.rpt` | **281 R36 + 62 R18 = 312** | ⇒ **P7b 新增件（PCS / 新 MAC / `UDP_TX_OVL` 乒乓 / 8 路发生器 / `snap_seq` / `axi_regs`）一片 BRAM 都没加** |
| ④ | **P7b 本构建·实现**（XDMA 已链接）`impl_1/...placed.rpt` | **317 R36 + 62 R18 = 348** | **348 − 312 = +36 R36 = XDMA** |

### §2.3 差额解释（**收口到 0**）

| 项 | tile | 证据 |
|---|---|---|
| RTL + HLS 小计（①=②=③ 三方一致） | **312** | 见 §2.2 |
| XDMA OOC 单独综合报告 | **38** | `vivado_prj/p7b_ku5p_prj.runs/xdma_0_synth_1/xdma_0_utilization_synth.rpt` |
| **XDMA in-context（实现后）实测** | **36** | ⭐ `_proj_pcie/pcie_min_util.rpt` —— **同器件 `xcku5p-ffvb676-1-e` + 逐字相同的 XDMA CONFIG**（`num_queues=1 / 128_bit / mode_selection Basic / X0Y0 / 8.0_GT/s / X4`，见 `_proj_pcie/build_pcie_min.tcl:25-36`）的 PCIe-min 构建，`Design State: Routed` ⇒ `Block RAM Tile = 36`（且 0 RAMB18、0 URAM） |
| **合计** | **312 + 36 = 348** | ✅ **与报告实测 348 逐数相等，差额 0** |

> ⭐ **"OOC 38 vs in-context 36"这个 2 片差不是猜测，是实测**：同一个 XDMA 配置，
> **OOC 单独报告说 38**，**链接进一个只有它的顶层并跑到 routed 之后说 36**。
> ⇒ `P7B_BRAM_REDUCTION.md`（A4 路）§0.2 里那句"或 RTL 微差"的尾巴**可以删掉了**，
> 差额**全部**落在 XDMA 的 OOC↔in-context 上，RTL 侧 281/62 是硬数。

> ⚠️ **"我没找到"≠"不存在"**：本节没有任何"未解释的残余"。若日后要复核 `retx_ram = 256`，
> **唯一**的独立复核路径是再跑一次 `report_utilization -hierarchical`（本路无权启动 Vivado，
> 因为当时有全实现构建在跑）。

---

## §3 前 10 名排序表（按 tile 降序）

**通路口径**：`TX 快路径 / RX 快路径 / 慢路径(HLS) / 观测面 / 前端(PCS/MAC) / PCIe / 时钟复位`

| # | 模块（例化名） | **tile** | 占 348 | 通路 | FIFO 还是纯存储 | URAM 初步标记 |
|---|---|---|---|---|---|---|
| 1 | **`retx_ram`**（`u_tcp_tx.u_retx`） | **256** | **73.6%** | **TX 快路径**（TCP 重传环） | **纯存储**（16 连接 × 64KB 环形缓冲） | ⭐ **候选（最强）** —— 见 §5 |
| 2 | **`udp_echo`**（`u_hls`，20 个 RAM 实例） | **37** | 10.6% | **慢路径(HLS)** | 混合（L2 表 / frame_buf / 连接表，**无流控 FIFO 语义**） | **待定**（要改 HLS 源码 + 重综合；且多为极小表） |
| 3 | **`xdma_0`**（`u_pcie_xdma`） | **36** | 10.3% | **PCIe / 观测面** | 厂商内部（descriptor/credit，含 FIFO 语义） | **不可**（加密/网表 IP，配置项里没有关掉它们的开关） |
| 4 | **`frame_fifo` 8192×73**（`u_tcp_echo.u_fifo`） | **16** | 4.6% | **RX 快路径**（TCP 零拷贝接收缓冲） | **FIFO**（`snap`/`rollback` 整帧语义） | **候选（次优先）** —— 见 §5 |
| 5 | `grp_tcp_rx_process_fu_1827`（HLS） | 4.5 | 1.3% | 慢路径(HLS) | 纯存储（连接状态表） | 待定 |
| 6 | `grp_tcp_active_tick_fu_2164`（HLS） | 3.0 | 0.9% | 慢路径(HLS) | 纯存储 | 待定 |
| 7 | `grp_arp_rx_process_fu_1773`（HLS） | 2.0 | 0.6% | 慢路径(HLS) | 纯存储（ARP 表） | 待定 |
| 8 | `grp_icmp_rx_process_fu_1942`（HLS） | 2.0 | 0.6% | 慢路径(HLS) | 纯存储 | 待定 |
| 9 | `grp_tcp_send_fu_2113` / `grp_tcp_send_1_fu_2055`（HLS） | 2.0 / 2.0 | 各 0.6% | 慢路径(HLS) | 纯存储 | 待定 |
| 10 | `grp_udp_tx_process_fu_2004`（HLS） | 2.0 | 0.6% | 慢路径(HLS) | 纯存储 | 待定 |
| — | `frame_fifo` 512×73 ×3（`u_slow_rx.u_ff` / `u_slow_tx.u_wf` / `u_udp_split.u_uf`） | 1 / 1 / 1 | 各 0.3% | RX/TX 快路径 + RX 快路径 | **FIFO**（整帧 `rollback` 语义） | **待定/低优先**（太浅） |
| — | **全部其余手写 RTL** | **0** | **0%** | —— | —— | 已是 LUTRAM |

> ⚠️ 第 5–10 名**全是 HLS 一个父节点下的子块**，加起来 15.5 tile（4.5%）。
> 换句话说：**除 HLS 与 XDMA 外，手写数据面对 BRAM 的贡献只有 19 tile（5.5%），其中 16 tile 是那一个 echo frame_fifo。**

---

## §4 大块点名（单个 ≥ 16 tile 的，共 **3 个**，占 348 的 **94.5%**）

> ⚠️ **2026-09-30 订正**：本节原写 **88.5%**，**算术不成立** —— `256+37+36 = 329`，`329/348 = 0.9454` ⇒ **94.5%**。
> （88.5% 与本表三个数**对不上**；同批订正见 `P7B_BRAM_REPORT.md` §0-#2 与五份引用它的文档。）

| 块 | tile | 是谁 | 关键文件:行 | 备注 |
|---|---|---|---|---|
| ⭐ **`retx_ram`** | **256** | 我们手写 | `rtl/retx_ram.v:119-120`；例化 `rtl/tcp_tx_frame.v:580` | 唯一被工具点名 URAM 候选；唯一值得动的目标 |
| **`xdma_0`** | **36** | 厂商 IP | `board/wrapper_p4.v:3749`；`board/build_p7b_ku5p.tcl:110-124` | 不可改；是"要不要保留 PCIe 观测通道"的成本 |
| **`udp_echo`（HLS）** | **37** | HLS 生成 | `hls/slowstack_prj/solution1/syn/verilog/` | 20 个实例；至少 2 片 RAMB36 + ~24 片 RAMB18 装的是几百 bit |

**没有任何 4–15 tile 的中块** —— 数据面是"一个巨人 + 一串侏儒"的结构。

---

## §5 URAM 可替代性初步标记

**前提事实**：`URAM = 0/64`，**64 个 URAM288 全部空闲**。URAM288 容量 = `4096 × 72 = 294,912 bit`，
有 **`BWE_A/BWE_B[8:0]` 字节写使能**（已按本机 `C:/AMDDesignTools/2025.2/Vivado/data/verilog/src/unisims/URAM288_BASE.v:65-66` 核对）。

### §5.1 ⭐ 最强候选：`retx_ram`（256 tile → **29 个 URAM**）

**容量**：8,388,608 bit ÷ 294,912 = **28.4 ⇒ 29 个 URAM288**（64 个里用 29 个 = 45%）。
**收益**：348 → **92 tile = 19.2%**（降 53 个百分点）。

**接口匹配度（逐条核对）**：

| retx_ram 的需求 | URAM288 是否满足 |
|---|---|
| 单时钟（`clk` 单域） | ✅ URAM288 单时钟 |
| 1 读口 + 1 写口（简单双口） | ✅ 两个口可各配 R/W |
| 数据宽 64 bit | ✅ URAM288 数据宽 72 bit（64 用得上） |
| **字节写使能 ×8** | ✅ **`BWE_A[8:0]` = 9 位字节写使能**（`rtl/retx_ram.v:124-131` 的 8 条 lane 写正好映射） |
| 无初值 / 无复位 | ✅（URAM 同样无复位写块） |

**⛔ 唯一的硬条件 = 读流水深度**（工具亲口说的，verbatim）：

```
INFO: [Synth 8-6792] Large memory block ("retx_ram:/g_byte[1].mem_o_reg") is implemented using BRAM
      instead of URAM due to insufficient pipeline registers. Use of ram_style="ultra" and/or
      providing sufficient pipeline registers is recommended
INFO: [Synth 8-6793] RAM ("retx_ram:/g_byte[1].mem_o_reg") is implemented using BRAM instead of URAM
      due to insufficient pipeline registers. Available pipeline stages = 0,
      Minimum required pipeline stages = 3
```
（`board/p7b_ku5p_stdout.txt:1473-1516`，`mem_e`/`mem_o` 各若干条；**全设计只有这 2 个存储器拿到这条消息**）

⇒ 现状 **2 级读流水**（地址寄存 `rd_en` 拍 + 读出寄存 `rd_d1` 拍，`rtl/retx_ram.v:98-108,134-142`），
需要 **≥3 级** ⇒ 要**再加 1~3 拍读延迟**，并同步把调用方 `tcp_tx_frame` 的 ring 消费窗口整体后移。
⚠️ **这是有先例的改动**：P6 时序修复"步骤 3"（2026-09-12）已经把消费窗口整体后移过 1 拍
（`rtl/retx_ram.v:88-97` 头注释），但当时是**为了时序**；这次是**为了存储类型**，代价相同量级。

**风险点（不是"不可"，但要算）**：
- 读延迟从 2 拍 → ≥5 拍 ⇒ RTT/重传时序、`rb_snd_nxt` 的读点、`tap_seq` 游标都要重新对账；
- `rtl/retx_ram.v:56-63` 记录过一条硬事实：**同一 mem 数组出现两个写地址信号会被判为多写口、RAMB 推断失败**
  （当时的解法是把地址复制交给 `max_fanout` 在**推断之后**做）。改 URAM 后 `max_fanout=64` 那套复制策略要重做。
- 分支内既有 K7（`RAMB36E1`）与 KU5P 两条路径（`rtl/frame_fifo.v` 是显式例化；`retx_ram` 是推断，无分支）。

### §5.2 其余标记

| 块 | tile | 标记 | 理由 |
|---|---|---|---|
| `tcp_echo.u_fifo`（frame_fifo 8192×73） | 16 | **候选（次优先）** | URAM288 = 4096×72 ⇒ 8192 深用 **2 个 URAM**（73 位里多出的 1 位另放）。当前是**显式 `RAMB36E2` x72 SDP + `DOA_REG=0`（1 拍读）**，改成 URAM 要重写 `frame_fifo` 的 `gen_mem`（换 `URAM288` 原语或 `xpm_memory` 的 `MEMORY_PRIMITIVE=ultra`）并补地址流水。⚠️ 该模块还有 **`snap`/`rollback` 整帧语义**与"非显示片 DOA 冻结需掩码"的机制（`rtl/frame_fifo.v:116-119`），改存储类型必须同时保住这些。收益 16 tile。 |
| 3 个 512×73 frame_fifo | 1+1+1 | **待定 / 低优先** | **太浅**：512×73 = 37,376 bit，一个 URAM288（294,912 bit）是它的 **7.9 倍**。用 1 个 URAM 换 1 片 RAMB36 在"URAM 全空"时**不算浪费**，但要改 module 且总收益只 3 tile。 |
| HLS `udp_echo` 全体 | 37 | **待定（要动 HLS 源码）** | Vitis HLS 可用 `#pragma HLS bind_storage variable=<x> type=RAM_2P impl=URAM`。⚠️ 但其中 **~24 片 RAMB18 装的是 3 项 ~30 位的小表**（`tcp_conn_*`），换 URAM 后**每个小表各吃 1 个 URAM288** ⇒ 20 个实例 ≈ 20 个 URAM，**面积反升**（虽然 URAM 现在全空，但这是把"免费"用光的最快方式）。**更便宜的方向是相反的那一边**：把这些小表推回 **LUTRAM**（工具自己在 `8-7082` 里就是这么建议的），可回收 ~12 tile。 |
| `xdma_0` | 36 | **不可** | 厂商 IP，内部 RAM 不可改（配置项里无开关）。**唯一"减法"是不要 PCIe 观测通道**（那是产品决策，不是技术决策）。 |
| 所有手写 FIFO（§1.3 全部 19 条） | **0** | **不可 / 无意义** | 已经是分布式 RAM，**不占 BRAM**；且它们是 FWFT/组合读，**本来就推不成 BRAM**。 |

### §5.3 URAM 路线的"一口价"总结

| 做到哪一步 | BRAM tile | URAM 用量 | 涉及改动 |
|---|---|---|---|
| 现状 | **348 / 480 = 72.5%** | 0 / 64 | —— |
| **只搬 `retx_ram`** | **92 / 480 = 19.2%** | 29 / 64 | `rtl/retx_ram.v` 加流水 + `ram_style="ultra"`；`tcp_tx_frame` 消费窗口后移 |
| 再搬 echo frame_fifo | 76 / 480 = 15.8% | 31 / 64 | 重写 `rtl/frame_fifo.v` 的 `gen_mem`（4 个实例共用，注意 512 深的那 3 个要不要跟着改） |
| 再搬 HLS | 39 / 480 = 8.1% | ~50 / 64 | 改 HLS 源码 + 重综合 + 全部 HLS 门重跑 |

---

## §6 方法与不确定

### §6.1 方法（可复现）

1. **RTL 侧**：全仓 grep 出**所有**存储数组（`reg [...] name [0:N]` + `(* ram_style *)` 前缀变体）
   与**所有** FIFO 例化点（`fifo_sync# / frame_fifo# / fifo_async# / udp_split_fifo#`），
   再按 `board/build_p7b_ku5p.tcl` 的 `import_files` 清单与 `verilog_define` 判定**哪些分支真的在编**。
2. **例化深度/宽度**：直接读例化参数（`.W/.D/.AW/.DataWidth/.AddressRange`），不读注释。
3. **tile 归属**：用 `report_utilization -hierarchical -hierarchical_depth 2` 的**分层报告**
   （P6a KU5P 与 P6 K7 两份，逐实例一致）**加** 本构建综合期报告（281/62）**加**
   `_proj_pcie/pcie_min_util.rpt`（XDMA in-context = 36）。
4. **IP**：读各自的 **OOC 综合报告**（`*_synth_1/*_utilization_synth.rpt`）+ netlist 里原语计数
   + 同配置的**最小可跑构建**（pcie_min）做 in-context 校验。
5. **工具的态度**：直接引用综合日志的 `8-6792 / 8-6793 / 8-6904 / 8-7082` 四条消息
   （`board/p7b_ku5p_stdout.txt`），不自己替工具下结论。

### §6.2 不确定 / 未验证（**逐条列，不许读成"不存在"**）

1. **`retx_ram = 256` 没有从本 P7b 构建的分层报告里直接读到** —— 本轮的 `impl_1` 报告**没有**层级分解。
   它来自 ① P6a(KU5P)/P6(K7) 分层报告逐点显示 `u_retx = 256`（两份一致）+ ② RTL 注释自述 + ③ 容量反算，
   **三方同值**。⇒ 结论很硬，但**证据不是本轮读数**。
2. **XDMA OOC 38 vs in-context 36 的 2 片去向未定位**（是 `link_design`/`opt_design` 裁掉的，还是 OOC 报告口径差异）。
   **不影响 348 的对账**（用 in-context 的 36 时差额为 0）。若日后要精确到"哪 2 片"，需对本轮 impl 跑一次
   `report_utilization -hierarchical`。
3. **§1.3 的 LUTRAM 逐条求和是估算**（≈3,665 LUT6 当量 vs 实测 RTL 侧 ≈4,836），**差 ~1,170 LUT 未逐条对账**。
   候选：HLS 内部 LUTRAM、`retx_ram` 地址网的扇出复制（`rtl/retx_ram.v:93` 记 `384/1152` 份）、F7/F8-Mux 计法。
4. **HLS 的 RAMB18 细账**：分层报告列出的 depth-2 行逐行相加 = **50**，父行 = **62**；
   **差 12 片在 depth-3 节点**（本轮用的报告只到 depth 2）。本文件已按 62 记账，但**没有逐片定位那 12 片**。
5. **`retx_ram` 换成 URAM 后能否收敛时序**：**未验证**。加了流水会改变 `tcp_tx_frame` 的最差路径。
   （本路无权启动 Vivado；且当时有全实现构建在跑。）
6. **`retx_ram` 的 URAM 容量算式**假设 Vivado 用 `4096×72` 直铺；若它选择别的拼接方式（例如 18 个 URAM 装
   一个 bank），片数会变。**29 这个数是上界估计**，实际 29±3。
7. ~~**`rtl/udp_echo.v`（旧手写版）没参与本构建**这一点没有反向确认~~ ⇒ ✅ **已收口**（见 §1.6）：
   综合日志 `board/p7b_ku5p_stdout.txt:623` 显示综合的是 `.../imports/verilog/udp_echo.v:9`（HLS 版），
   且 `p7b_ku5p_prj.xpr` 里没有 `rtl/udp_echo.v` ⇒ **`u_hls` = HLS 的 `udp_echo`，6+62 归属成立**。
8. **`retx_ram` 的"2 级读流水"计数**是按 RTL（`rtl/retx_ram.v:101-108` 地址寄存 + `:134-142` 读出寄存）读出来的；
   工具消息只给了"Available pipeline stages = 0, Minimum required = 3"，**没有说它数到了几级**。
   "现状 2 级 / 需再加 1~3 级"是**推断**，落地前应以工具复跑为准。

### §6.3 复现命令（**本路没跑，留给下一路**；必须先确认构建已结束）

```bash
# 唯一的"逐条复核"路径（会启动 Vivado，务必等 impl 构建结束）
# 在 open_run impl_1 之后：
report_utilization -hierarchical -hierarchical_depth 2 -file /path/to/p7b_util_hier.rpt
report_ram_utilization -file /path/to/p7b_ram_util.rpt
```

---

## §7 附：本文件用到的证据文件（全部只读）

| 用途 | 绝对路径 |
|---|---|
| 本构建·实现·放置（**348 的主读数**） | `D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4_utilization_placed.rpt` |
| 本构建·综合（**281/62 的主读数**，XDMA 黑盒） | `D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\synth_1\wrapper_p4_utilization_synth.rpt` |
| XDMA OOC（38） | `D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\xdma_0_synth_1\xdma_0_utilization_synth.rpt` |
| PCS OOC（**0**） | `D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\pcs64_synth_1\pcs64_utilization_synth.rpt` |
| **XDMA in-context（36）** | `D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\pcie_min_util.rpt` |
| 分层归属（KU5P / K7 各一份，逐实例） | `D:\repo\XCKU5PMini\udp_hls_10g\p6a_ku5p_verify\p6a_t6p4_util_hier.rpt` ／ `...\p6_verify\p6_t6p4_util_hier.rpt` |
| 工具态度（`8-6792/6793/6904/7082`） | `D:\repo\XCKU5PMini\udp_hls_10g\board\p7b_ku5p_stdout.txt` |
| 构建清单与宏 | `D:\repo\XCKU5PMini\udp_hls_10g\board\build_p7b_ku5p.tcl` |
| URAM288 原语接口 | `C:\AMDDesignTools\2025.2\Vivado\data\verilog\src\unisims\URAM288_BASE.v` |
