# P7b WU 构建 —— 数据面域 WNS `0.192 → 0.147`（−0.045）时序归因（只读取证）

- 日期：**2026-10-07**　性质：**只读取证报告**（本 agent **未构建、未跑 Vivado、未烧板、未动 `rtl/`·`board/wrapper_p4.v`·`tb/`·`vivado_prj/`·`sim/`**；未做任何 git 写操作）。
- 依据物 = 两份 routed 报告（本轮 `board/p7b_ku5p_timing.rpt` + 基线快照 `_proj_10g/notes/p7b_wu_build/baseline_snapshot/p7b_ku5p_timing.rpt`）+
  实现 run 目录里 Vivado 自己生成的 `-max_paths 10` 版报告（只读引用）+
  **RATE 原件/重建件**（第三方对照）+ RTL 源码与 wrapper 连接性 + 文件哈希/mtime + git 历史。

---

## 0. 结论（先给要点）

1. ⛔ **题面里"那条关键路径"与 `wu` 修复之间没有逻辑通路** —— 该路径的组合锥内**没有任何 `u_app_ctrl` 单元**，且结构性上 `app_ctrl` 的输出**物理上到不了** UDP TX 数据通路（§1）。
2. ⭐ **−0.045 是"换 netlist ⇒ 布局/布线重排（reflow）"**，而且**不是运行间随机抖动**：本流程在输入不变时是**确定性**的（RATE 原件 vs RATE 重建件：WNS、每分组端点计数**逐字相同**，§4.4）。⇒ 变化只可能来自"输入网表变了"。
3. ⭐ **重排幅度远大于 0.045**：17 条**同一物理路径**（两端单元逐字相同、锥内逻辑与 `app_ctrl` 无关）在两轮之间移动 **−0.591 … +1.302 ns**（10/17 条 |Δ| > 0.045）；15 个 **app_ctrl 不可能出现的时钟分组**里 **10 个**的组最差移动 > 0.045（最大 +0.756）（§4.1/§4.2）。
4. ⚠️ **"这条路径自己在基线上是多少"= 无法判定**（题面前提不成立）：两份报告都是**每组只列 1 条 max + 1 条 min**（各 62 条 `Slack (` 行），基线报告里这条路径的**每一个中间单元都不出现**（§2）。
5. ⚠️ **"`app_ctrl` 自己变差没有"= 无法从两轮报告判定**（两轮 `u_app_ctrl` 命中均 = 0）；只有**综合级**旁证说"没变差"（§3）。
6. ⚠️ **`CLAUDE.md` 那句"扩窗会继续吃这条"必须重新表述**：它原本说的是 **pcie 域**快照阵列的**异步复位 Recovery** 族，不是数据面 setup 路径；且该族**本轮没动窗口也自己动了 +0.419**（§5.3）。

**归因一句话**：这条路径**不是** `wu` 修复在逻辑上的直接后果；它是"输入网表变了 ⇒ P&R 重解"的**伴随产物**——同一逻辑的路径在两轮之间全场重分布，这条恰好落到了 0.147（而基线里那条更差的 `retx` 路径同时升到 ≥0.147 没被报出来）。

---

## 1. 这条路径到底经过谁（**它不经过 `app_ctrl`**）

### 1.1 逐字报告行（本轮）

| 项 | 值 | 行 |
|---|---|---|
| Slack (MET) | **0.147 ns** | `board/p7b_ku5p_timing.rpt:2010` |
| Source | `u_app_udp/u_txf/dout_reg[68]/C`（FDCE，`g_hw.clk_out0` 6.400 ns） | `:2011`（物理位 SLICE_X90Y110 `:2052`） |
| Destination | `u_udp_tx/ip_csum_r_reg[0][5]/D`（FDCE，同域） | `:2013`（物理位 SLICE_X81Y110 `:2117`） |
| Data Path Delay | 6.038 ns（logic **2.685** = 44.5% / route **3.353** = 55.5%） | `:2018` |
| Logic Levels | **20**（CARRY8=6 / LUT6=5 / LUT5=4 / LUT2=2 / LUT1·LUT3·LUT4=1） | `:2019` |

路径 20 级逐级（`:2055-2117`）：`dout_reg[68]/Q` → `…/plen_r[1][3]_i_7` → `…/plen_r[1][1]_i_3` → `…/plen_r[1][3]_i_2` →
`u_udp_tx/plen_r[1][10]_i_3` → `u_udp_tx/plen_r[1][6]_i_2` → `u_udp_tx/total_len_r[1][10]_i_2` →
`u_udp_tx/ip_csum_r[1][15]_i_78/_86/_45/_8/_15` → `u_udp_tx_cfg/ip_csum_r_reg[1][15]_i_38`（CARRY8）→
`…/ip_csum_r_reg[1][7]_i_8/_3` → `…/ip_csum_r_reg[1][15]_i_3` → `…/ip_csum_r_reg[1][7]_i_2` → `u_udp_tx_cfg/ip_csum_r[1][5]_i_1` → 终点 `/D`。

**锥的归属（按信号名，不按层次前缀）**：
- `dout_reg` / `mem_reg_0_63_*` / `wptr_reg` = **`fifo_sync`** 的寄存器（`rtl/fifo_sync.v:38` `output reg [W-1:0] dout`）；
  `u_txf` = `app_udp_pattern` 的 73 bit 字 FIFO（`rtl/app_udp_pattern.v:497`）。
- `plen_r[1][*]` / `total_len_r[1][*]` / `ip_csum_r[*][*]` / `id_cap` = **`udp_tx_frame`** 的信号
  （`rtl/udp_tx_frame.v:145-148` 三个 2 bank 寄存器；`:204` `rd_tx`；`:270-273` 组头收尾时对 `plen_r/total_len_r/ip_csum_r` 的写入）。
  `u_udp_tx` = `udp_tx_frame` 实例（`board/wrapper_p4.v:2578`），`u_udp_tx_cfg` = `udp_tx_cfg` 实例（`wrapper_p4.v:2533`）。
- ⇒ 物理含义：**app 的 TX 字 FIFO 输出（bit 68 = tkeep[4]）→ UDP 组帧器的 plen 累加/总长/IP 校验和锥 → `ip_csum_r` 的 D 端**。

⚠️ **命名陷阱（已实测排除）**：路径上出现 `u_app_udp/u_txf/plen_r[...]` 这种"FIFO 层次里挂着 udp_tx 信号"的名字。
`fifo_sync` 与 `app_udp_pattern` 里**都没有** `plen_r`（grep：`rtl/app_udp_pattern.v` 仅 1 处注释命中 `plen`，`rtl/fifo_sync.v` 0 处；`plen_r` 只存在于 `rtl/udp_tx_frame.v` 与 `rtl/tcp_tx_frame.v`），
且 `app_udp_pattern` 只例化了一个 `u_txf`（无其它子模块）。
**独立反证**：本轮 `wrapper_p4_control_sets_placed.rpt` 里 `FSM_onehot_txs_reg`（RTL 上属于 `app_udp_pattern` 的状态机）被印成 `u_app_udp/u_txf/FSM_onehot_txs_reg`
⇒ **这些层次前缀是 opt/phys_opt 之后的命名产物，不能当"逻辑属于哪个模块"的证据**。所以 §1.2 用**连接性**而不是前缀来定案。

### 1.2 结构性排除 `app_ctrl`（三条独立论据）

① **该路径的终点锥只吃三样东西**：`udp_tx_frame` 的输入 = `s_axis_*`（来自 `u_udp_tx_cfg`，`wrapper_p4.v:2578-2583`）、`cfg_*`（来自 `utx_cfg_*` 即 `u_udp_tx_cfg` 的 `o_*`，`:2559-2565`）、`m_axis_tready`（来自 `u_tx_udp_arb`）。
② **`u_udp_tx_cfg` 的输入**= `frame_busy`(←`utx_busy`)、`peer_*`(←`udp_split` 的学习事件，`:2542-2546`)、`cfg_*`(常量，`:2547-2558`)、`s_axis_*`(←`app_udp_pattern.m_*`)、`m_axis_tready`(←`utx_tready`)。
③ **app 的 `i_tx_ready` 不是 `app_ctrl` 给的**：`.i_tx_ready (app_udp_tx_ready)`（`wrapper_p4.v:2490`），而 `app_udp_tx_ready` 的唯一驱动是 **`u_udp_tx_cfg.o_ready`**（`:2573`，peer 表有效）。
    `app_ctrl` 的输出 `app_tx_ready`（`wrapper_p4.v:1255`，另一根线）只接在 `:1182/:1255/:1390` 三个实例上 —— **都不在 UDP TX 链上**。
⇒ `app_ctrl` 的输出（`o_ev_* / fin_req / rst_req / fc_upd_* / wu_* / close_* / reg_* / app_tx_ready`，`:1214-1292`）走的是 **tcb / tcp_tx_frame / 慢路径 / 寄存器总线**；**没有任何一根线接进 `u_app_udp` / `u_udp_tx_cfg` / `u_udp_tx`**。
⇒ 本轮 `wu` 修复改的 `wu_zero / wu_pend / wu_mark` 三个量的下一拍逻辑（`git show 09d2189 -- rtl/app_ctrl.v`，C6 块）**与这条路径的锥不相交**。

### 1.3 这条"最差路径"其实是一个族（同一源寄存器的 fanout 群）

实现 run 自带的 `-max_paths 10` 报告（`vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_timing_summary_routed.rpt`，mtime 02:16，与 `board/p7b_ku5p_timing.rpt` 同一次 `open_run impl_1`）里，**DP 域前 10 条有 6 条同源**：

| # | slack | Source | Destination | 行 |
|---:|---:|---|---|---:|
| 1 | **0.147** | `u_app_udp/u_txf/dout_reg[68]` | `u_udp_tx/ip_csum_r_reg[0][5]/D` | `:13566` |
| 2 | 0.159 | 同上 | `…ip_csum_r_reg[1][5]/D` | `:13706` |
| 3 | 0.159 | 同上 | `…ip_csum_r_reg[0][12]/D` | `:13846` |
| 4 | 0.195 | 同上 | `…ip_csum_r_reg[1][12]/D` | `:13983` |
| 6 | 0.198 | 同上 | `…ip_csum_r_reg[1][13]/D` | `:14203` |
| 10 | 0.229 | 同上 | `…ip_csum_r_reg[0][13]/D` | `:14589` |

（其余 4 条源 = `u_clkgen/rel_sr_reg[3]/C`：`rx_trace_mem` ×3 + `retx` BRAM 地址 ×1，slack 0.198–0.227，`:14120/:14340/:14420/:14506`。）
⇒ **"0.147"不是孤点，是一个跨 0.147–0.229 的 6 条同源簇**（源寄存器同一个 bit、终点是校验和寄存器的不同位）。

---

## 2. 它在基线上是什么 slack —— **无法判定（题面前提不成立）**

**已核事实（我自己 grep，不是转述）**：基线报告 `_proj_10g/notes/p7b_wu_build/baseline_snapshot/p7b_ku5p_timing.rpt` 里
`u_udp_tx/ip_csum` **0 命中**、`plen_r` **0 命中**、`dout_reg[68]` **0 命中**；本轮报告里 `plen_r` 10 命中。

**为什么查不到**：`board/build_p7b_ku5p.tcl:174` 用的是 `report_timing_summary -file …`（默认 **max_paths = 1**）⇒ 每分组只留 **1 条 max + 1 条 min**（两份报告各 **62 条 `Slack (` 行**，结构逐项对应）。

**能证明的界（这是本条唯一可下的定量结论）**：
- 基线 DP 组最差 = **0.192 ns**，且那是一条**完全不同的物理路径**（`u_tcp_tx/u_retx/ra_o_r_reg[2]_rep__11/C → …mem_o_reg_7_bram_6/ADDRBWRADDR[5]`，`baseline:1998-2007`，**Logic Levels 0 / 98.3% 布线**）；
- ⇒ 本轮那条路径在基线里**必然 ≥ 0.192**（否则它才会是基线报告出来的那条最差）⇒ **它自己至少掉了 0.045 ns，上界未知**（否则基线报出来的就会是它，而不是 0.192 那条）。
- 两个"0.192"和"0.147"不是同一条路径 ⇒ **"DP 组最差掉了 0.045" ≠ "这条路径掉了 0.045"**。这两个结论**不同**，且**只有后者**能归因到"这条路径"，而我**无法从现有归档判定后者**。

**为什么拿不到基线的那份 `-max_paths 10` 报告**（已穷举）：
- 实现 run 目录里同名文件 `wrapper_p4_timing_summary_routed.rpt`（8.5 MB，**max_paths 10**）已被本轮的构建覆盖（mtime 02:16）；
- `_proj_10g/notes/p7b_biz_build/prev/` **空**；`timing_key_sections.txt` 只截了 **120 行**（到第 1 个分组就断了，`grep "From Clock:"` 只有 1 条）；
- 全仓 `wrapper_p4_timing_summary_routed.rpt` 只有 2 份与本设计相关：**本轮**的 + `rate_rebuild`（RATE 设计，非基线，见 §4.4）；
- **基线 routed DCP 已被覆盖**（`impl_1/wrapper_p4_{opt,physopt,placed,routed}.dcp` mtime 全为 2026-10-07 02:03–02:16）。

**缺什么才能判**：基线那次构建的 `wrapper_p4_timing_summary_routed.rpt`（或基线 routed DCP）——任一即可让这条路径的基线 slack 变成直读量。

---

## 3. `app_ctrl` 自己的路径 —— **无法从两轮报告判定**

- 两轮报告里 `u_app_ctrl` 出现次数 = **0 / 0**（同一"每组 1 条"抽样的后果）。
- 只能给出**下界**：DP 组最差 = 0.192（基线）/ 0.147（本轮）⇒ `app_ctrl` 的任一 DP setup 路径 slack **≥ 0.192（基线）/ ≥ 0.147（本轮）**。这个界**不能**回答"它自己变差没有"。
- 唯一的旁证是**综合级 A/B**（**不是**实现后读数，原文明写）：`P7B_WU_FIX.md:197-206` —— OOC 综合 6.4 ns：`HEAD` 版 WNS **+2.211**（最差 = `pool_reg[1]/C → pool_reg[0]/D`，15 级，LUT 5661/FF 4541）→ 修复版 **+2.208**（**同一条**最差路径，LUT 5214/FF 4287）
  ⇒ "**C6 不在本模块最差路径上，改动前后最差路径同一条**"。⚠️ OOC 无布局布线，**不能替代**实现后读数（该文件 §7-#2 自己也这么写）。
- **缺什么才能判**：两份 routed DCP 上跑 `report_timing -through [get_cells u_app_ctrl/*]`（基线 DCP 不存在，见 §2）。

---

## 4. 方差判别：我能做的最强版本

### 4.1 样本 A（最强）：**同一物理路径**的两轮 slack 差

方法：把两份报告的 62 条路径按 **(Source, Destination, Path Group, Path Type)** 逐字配对，取交集。
结果：**17 对**（全部落在 `pcs64` / PCIe-GT / `pipe_clk` 域 —— **`app_ctrl` 按构造不可能出现在这些锥里**）。

| Δ(ns) | 组/类型 | 路径（省前缀） |
|---:|---|---|
| **+1.302** | pcie_axi_aclk / Setup | `rst_psrst_n_r_rep_reg → pcie_4_0_init_ctrl_inst/reg_reset_timer_reg[0]/R` |
| **−0.591** | pcie_axi_aclk / Hold | `rst_psrst_n_r_rep_reg → …/reg_phy_rdy_reg[0]` |
| **−0.294** | async / Recovery | `i_pcs64_core_cdc_sync_gt_rx_serdes_resetdone_0/s_out_d4_reg → pcs64_top` |
| **+0.190** | async / Recovery | `…gt_tx_resetdone_0/s_out_d4_reg → pcs64_top` |
| **+0.170 / −0.056** | pipe_clk / Setup, Hold | `as_mac_in_detect_user_reg → as_mac_in_detect_ff_reg` |
| **+0.158** | pcie GT / Setup（998.890→999.048） | `phy_rst_i/intclk_rrst_n_r_reg[4] → wait_cnt_reg[0]/R` |
| **−0.156 / +0.095 / +0.024 / +0.010** | async（cpll_cal[0..2]） | `…/U_TXOUTCLK_FREQ_COUNTER/…` |
| +0.118 / +0.026 / 0.000 / +0.026 / +0.008 / −0.023 | 其余 | pcs64 内部 |

⇒ **10/17 条的 |Δ| > 0.045**，最大 **+1.302 / −0.591**。
⇒ 结论（可证伪的形式）：**若"−0.045 需要被归因到 `wu` 的逻辑"，则必须解释为什么 17 条锥内根本没有 `app_ctrl` 的同路径也动了 10 倍以上** —— 唯一自洽的解释是"全网表重排"，不是"某条逻辑变了"。

### 4.2 样本 B：**`app_ctrl` 不可能出现的时钟分组**的组最差差（Intra Table，`board:200-230` / `baseline:200-230`）

| 分组 | 基线 | 本轮 | Δ |
|---|---:|---:|---:|
| `pipe_clk`（`:218`） | 0.755 | 1.511 | **+0.756** |
| `txoutclkpcs_out[0]_3` | 4.415 | 4.957 | **+0.542** |
| `txoutclkpcs_out[0]_2` | 4.735 | 4.349 | **−0.386** |
| `cpll_cal[2]`(bufg_gt_txoutclkmon) | 6.960 | 6.290 | **−0.670** |
| `cpll_cal[0]` | 6.452 | 6.858 | **+0.406** |
| `rxoutclk_out[0]_3` | 0.668 | 0.534 | −0.134 |
| `rxoutclk_out[0]_2` | 1.671 | 1.789 | +0.118 |
| `cpll_cal[3]` | 6.847 | 6.967 | +0.120 |
| `sys_clk_100`（`:220`） | 8.059 | 8.173 | +0.114 |
| `cpll_cal[1]` | 6.839 | 6.812 | −0.027 |
| `pcie_axi_aclk`（`:217`） | 0.308 | 0.351 | +0.043 |
| `txoutclk_out[0]_2` | 3.405 | 3.431 | +0.026 |
| `pcie_ref_clk` | 7.398 | 7.412 | +0.014 |
| `txoutclk_out[0]_3` | 0.417 | 0.424 | +0.007 |
| `phy_clk_i/bufg_gt_intclk/O` | 998.890 | 999.048 | +0.158 |

**10/15 个分组 > 0.045**（其中 5 个 ≥ 0.386）。另一族（"Other Path Groups"的 `**async_default**` 行，`board:250-255` / `baseline:250-255`）：
`pcie_ref_clk` +0.325 · `pipe_clk` **+1.559** · `rxoutclk_out[0]_2` −0.294 · `rxoutclk_out[0]_3` **−0.764** · `txoutclk_out[0]_2` +0.190 · `txoutclk_out[0]_3` +0.454。

### 4.3 本轮还做到的"逻辑不变"证据（用于把"逻辑"这条支路彻底关掉）

- 该路径涉及的 RTL 在两轮之间**逐字节相同**（两个独立证据）：
  ① **mtime 全部早于基线构建**（基线 BIZ 构建 = 2026-09-30 19:30–19:57）：`rtl/app_udp_pattern.v` 09-30 18:56、`rtl/udp_tx_frame.v` 09-30 16:46、`rtl/fifo_sync.v` 09-29 09:54、`rtl/udp_tx_cfg.v` 09-20 22:37、`board/wrapper_p4.v` 09-30 19:30:21；只有 `rtl/app_ctrl.v` 是 2026-10-07 01:25。
  ② **BIZ 轮构建期取样指纹**（`_proj_10g/notes/p7b_biz_build/src_sha256.{before,after}.txt`，前后逐字相同）里的 9 个文件，我今天重算 sha256 **全部逐字命中**（`wrapper_p4.v ab67100f…`、`app_udp_pattern.v 0a520f5f…`、`udp_tx_frame.v ab96d7af…`、`build_p7b_ku5p.tcl 01f0770a…` 等）。
  ③ `git status` 在 `rtl/`/`_proj_pcie/` 上**干净**；`git diff --stat ff78247 HEAD -- rtl/ board/ _proj_pcie/ tb/ sim/` = **`rtl/app_ctrl.v` 86 行 + 两个新 TB/sim 文件**，别无它物。
- ⇒ 该路径的**逻辑**在两轮之间不变；变化只能发生在**物理实现**（布局/布线/时钟树）层。

### 4.4 ⭐ 决定性对照：**本流程是确定性的**（所以 −0.045 不是"运行间抖动"）

| | RATE **原件**（`_proj_10g/notes/p7b_ratebuild/new/p7b_ku5p_timing.rpt`，09-30 17:50） | RATE **重建件**（`_proj_10g/notes/p7b_biz_tcpreg/rate_rebuild/wrapper_p4_timing_summary_routed.rpt`，10-07 00:53，`git worktree` 另一目录、独立构建、**位流 sha 不同**） |
|---|---|---|
| 全局 WNS / 端点（原件 `:155` / 重建件 `:156`） | 0.136 / 240450 | **0.136 / 240450** |
| DP 组（`:221`） | 0.295 / 135218 | **0.295 / 135218** |
| `async`: g_hw（`:248`） | 0.897 / 26662 | **0.897 / 26662** |
| `async`: pcie_axi_aclk（`:249`） | 0.136 / 4284 | **0.136 / 4284** |
| `async`: pcie_ref_clk / pipe_clk（`:250/:251`） | 8.374/131 · 2.808/13 | **8.374/131 · 2.808/13** |

⇒ **同（近同）输入 ⇒ 读数逐字复现**（连端点计数都一样）。⚠️ 诚实边界：两件**位流 sha 不同**（原件 `4eeb0f5f…3133`，出处 `_proj_10g/notes/P7B_RATE_BUILD.md:29`；重建件 `6475c3ba…`，出处 `_proj_10g/notes/p7b_biz_tcpreg/rate_rebuild/BITSTREAM.sha256`；重建件自登记 caveat = RATE 期盘上 `app_udp_pattern.v` 字节无法复原，见 `P7B_BIZ_TCPREG.md:50,62`），所以"确定性"是**报告读数级**的，不是位流字节级。
**推论**：两轮之间的任何时序差**只能**来自输入（网表）差异 —— 既不能归给"随机种子/运行间抖动"，也不能归给"某条逻辑变了"（§4.3），**只能归给"换网表引起的 P&R 重排"**。

### 4.5 重排的机制在报告里是**看得见**的（不是纯推理）

- **数据面时钟的 BUFG 换位**：同一实例 `u_clkgen/g_hw.u_bufg_out`，基线在 **`BUFGCE_X0Y34`**（`baseline:2037`），本轮在 **`BUFGCE_X0Y32`**（`board:2049`）⇒ 整个 DP 域的时钟根挪了 2 列。
- **同一条时钟网被重新布线**：`u_clkgen/clk_in_100`（驱动端 `BUFGCE_X0Y41` → 负载端 `MMCM_X0Y1`，两端 SITE 固定、fo=485 不变）：发射侧延迟 **1.711 → 2.135 ns（+0.424）**（`baseline:2033` vs `board:2045`），捕获侧 1.533 → 1.918（`baseline:2060` vs `board:2132`）。
  ⇒ **同一根网、同样的两端固定点，布线差 0.4 ns** —— 这是"重排幅度 ≫ 0.045"的最干净单例。
- **扇出/端点数同步变化**：DP 组端点 135,648 → 135,245（`baseline:221` / `board:221`），时钟根网 `fo=48027 → 47747`（`baseline:2039` / `board:2051`）。

### 4.6 我**做不到**的最强版本（如实登记）

- **两条支路的"分离实验"**：真正干净的判别是"在**另一个**无关模块上做**同规模**改动、同流程重建，看 DP 组最差动不动"—— 这需要一次构建（超出本 agent 的只读边界），且会与并发测量 agent 抢工程目录。
- **网表级 diff**（比较两轮 DCP 里该锥的单元集合）：基线 DCP 已被覆盖（§2）。
- ⇒ 现有证据能"**排除逻辑归因**"（§1/§4.3，"锥内无 app_ctrl + 逻辑逐字节不变"是硬证据），能"**排除随机抖动**"（§4.4），也能**给出重排幅度的分布**（§4.1/§4.2）；**不能**把 0.045 分解成"其中 X 来自重排、Y 来自其它"。

---

## 5. 余量与口径（含对 `CLAUDE.md` 那句话的重新表述）

### 5.1 两端时钟域 / 约束口径 —— **干净，无口径问题**

- 两端都是 **`g_hw.clk_out0`**：`{0.000 3.200} / 6.400 ns / 156.250 MHz`（`board:191`，与 `baseline:191` 逐字相同）；`Requirement: 6.400 ns`（`:2017`）、`Path Type: Setup`、无 MCP/假路径/分组例外。
- 该时钟是 MMCM 输出**自动推导**的：`board/ku5p_p6b_sysclk.xdc:36` 只写 `create_clock -period 10.000 -name sys_clk_100`，**`:31` 明写"156.25MHz 的输出时钟不要手写 `create_generated_clock`"**（手写会冲突）⇒ 6.400 来自 MMCM 参数，不是人手写的数字。
- 冗余口径检查：`Clock Uncertainty 0.062`（TSJ/DJ 计算值，`:2024-2027`）、`Clock Path Skew −0.179`（**对 setup 有利**，`:2020-2023`）、CPR −0.226 已扣（`:2140`）。**没有可挑的口径问题。**
- 唯一值得记的结构性事实：**20 级逻辑 / route 55.5%**（§1.1）⇒ 这条路径既不是纯布线型（可比基线那条 98.3% 布线的 `retx` 路径）、也不是纯逻辑型，**两侧都没富余**。

### 5.2 余量

- `0.147 / 6.400 = 2.30%`；hold 侧 `WHS +0.010`（`board:221`，与基线同薄）。三类失败端点 0/0/0（`board:156` / `board:159` "All user specified timing constraints are met."）。
- DP 组内部：该簇 6 条跨 **0.147–0.229**（§1.3）⇒ 下次任何小幅重排都会首先在这 6 条里翻出新的最差。

### 5.3 ⚠️ "每 +10 字 ≈ +320 FF，会继续吃这条" —— **必须重新表述**

逐字原文：`CLAUDE.md:64-66`（"−0.059 已归因 = 本轮扩窗的快照阵列 (+320 FF) 落在异步复位 Recovery 网上 … ⚠️ **含义: 再往窗口加字会继续吃这条** (每 +10 字 ≈ +320 FF)"）、`PORT_NOTES.md:5168-5170`、`PORT_NOTES.md:5263`。

**三处订正/补全（都可核）**：

1. **那句话说的"这条"不是数据面 setup 路径**。它的宿端是 `u_pcie_regs/snap_words_r_reg[174]/CLR`（`baseline:3437`）—— **pcie 域**（`pcie_axi_aclk`）的快照阵列，机制 = `user_reset` 异步复位网的 Recovery（`baseline:3434-3443`，logic 0 / 97.2% 布线）。数据面这条 0.147 是**另一族**（DP setup）。
2. **"扩窗吃时序"的机理里，重排与 FF 数是同量级的两个因素**：本轮**窗口没动**（仍 61 字），同一族的 slack 却从 **0.077 → 0.496（+0.419）**（`baseline:3434` / `board:3500`，同一源 `user_reset_reg/C`，宿端换成 `u_snap_dp/dout_a_reg[145]/CLR`）。
   ⇒ 若把 +320 FF 当成该族 −0.059 的**全部**原因，则无法解释"零 FF 变化下同族 +0.419"。（这不否定 BIZ 轮那条归因的**方向**，但它说明"扩窗必吃 WNS"的**幅度**大部分由重排决定。）
3. **扩窗确实也吃数据面域，但机理要说全**：DP 源字每字 = **+32 FF（DP 域 `hold_b`，`rtl/snap_cdc.v` 的 b 域银行）+ 32（pcie 域 `dout_a`）+ 32（`_proj_pcie/rtl/axi_regs.v` 的 `snap_words_r`）≈ 96 FF/字**
   ⇒ "每 10 字 +320 FF" 只数了**阵列那一份**；**总数 ≈ 960 FF/10 字，其中 320 落在数据面域**（BIZ 轮新增的 W51..W60 正是 `SNAP_P7BDP_NW` 束，b 域 = `dp_clk`，`wrapper_p4.v:3122`）。
   数据面域自己也有同族：`**async_default** g_hw.clk_out0` = **0.743**（`board:248`；基线 0.966，`baseline:248`），本轮最差成员 = `u_snap_dp/rstb_sync_reg[1]/C → hold_b_reg[2]/CLR`（`board:3323-3326`）。
   ⇒ 下一轮扩窗的可测风险排序：① `async_default` 两族（pcie **0.496** / DP **0.743**）；② 数据面域 FF 数（+32/字）+ 布局压力 ⇒ 这条 0.147 的 setup 路径**可能**被挤好或挤坏（不可预判方向）。

---

## 6. 我没能判定的部分 / 缺什么

| # | 判不了的东西 | 缺什么（拿到即可判） |
|---|---|---|
| 1 | **本轮这条路径在基线的 slack**（因此"它自己掉了多少"只有下界 ≥0.045） | 基线那次构建的 `wrapper_p4_timing_summary_routed.rpt`（max_paths 10）或 **基线 routed DCP**（已被本轮覆盖） |
| 2 | **`app_ctrl` 自己的最差路径（两轮各是多少、有没有变差）** | 两份 routed DCP 上 `report_timing -through [get_cells u_app_ctrl/*]`；基线 DCP 不存在 ⇒ 需重建基线 |
| 3 | **"换一个同规模无关改动"的对照构建**（把"改动导致/重排导致"在实验上彻底分开） | 一次构建（本 agent 边界外；且会与并发测量 agent 冲突） |
| 4 | 0.045 的**逐项分解**（多给 / 少给） | 同上（网表级 diff + 时钟树 delay 账） |
| 5 | 基线 DP 组里 `rel_sr_reg[3] → rx_trace_mem/retx` 那一族（本轮 0.198–0.227）在基线是多少 | 同 #1 |

⚠️ 另外两条"读数时的注意"：① §1.3 那份 max_paths-10 报告在 `vivado_prj/` 下，**下次构建会被覆盖**（本轮 mtime 02:16，若未见此文件请以 sha/时间戳核对）；② 本报告引用的"同一路径配对"（§4.1）只在**两份报告都抽到该路径**时成立（各 31 组 × 1 条），**不是**路径全集。

---

## 7. 引用清单（文件:行号，逐字核对过）

**本轮** `board/p7b_ku5p_timing.rpt`：`:159`(全约束满足) `:191`(时钟表 6.400/156.250) `:217`(pcie 0.351) `:218`(pipe 1.511) `:220`(sys 8.173) `:221`(DP 0.147/135245)
`:248`(async DP 0.743/26829) `:249`(async pcie 0.496/4856) `:2010-2019`(最差路径头) `:2011/:2013`(源/宿) `:2045`(clk_in_100=2.135) `:2049`(BUFGCE_X0Y32) `:2051`(时钟根 fo=47747/1.991/5.304) `:2052/:2117`(物理位) `:3323-3326`(u_snap_dp hold_b 0.743) `:3500-3503`(user_reset→u_snap_dp/dout_a 0.496)

**基线** `_proj_10g/notes/p7b_wu_build/baseline_snapshot/p7b_ku5p_timing.rpt`：`:159` `:191` `:217`(pcie 0.308) `:218`(pipe 0.755) `:220`(sys 8.059) `:221`(DP 0.192/135648)
`:248`(async DP 0.966/27065) `:249`(async pcie 0.077/4859) `:1998-2007`(最差路径：`u_tcp_tx/u_retx` BRAM 地址，Logic Levels 0 / 98.3% 布线) `:2033`(clk_in_100=1.711) `:2037`(BUFGCE_X0Y34) `:2039`(时钟根 fo=48027/1.869/4.760) `:3257-3260`(u_snap_p7bdp hold_b 0.966) `:3434-3437`(user_reset→snap_words_r_reg[174]/CLR 0.077)

**实现 run 自带 max_paths-10**（本轮，只读引用，mtime 2026-10-07 02:16）`vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_timing_summary_routed.rpt`：`:13566/:13706/:13846/:13983/:14203/:14589`（DP 前 10 中的同源 6 条）

**对照件**：`_proj_10g/notes/p7b_ratebuild/new/p7b_ku5p_timing.rpt`（RATE 原件，09-30 17:50）：`:155`(全局 0.136/240450) `:221`(DP 0.295/135218) `:248-251`(async 四行)；`_proj_10g/notes/p7b_biz_tcpreg/rate_rebuild/wrapper_p4_timing_summary_routed.rpt`（RATE 重建，10-07 00:53）：`:156` `:221` `:248-251`（**与原件逐字相同**）、`:13812`（同一族的 `dout_reg[69] → ip_csum_r_reg[0][13]` @0.309，第 4 名）、`BITSTREAM.sha256`（worktree 路径 `/d/repo/XCKU5PMini/_wt_p7b_rate/…`）；位流 sha 出处 `_proj_10g/notes/P7B_RATE_BUILD.md:29` / `P7B_BIZ_TCPREG.md:50,62`

**源码/文档**：`rtl/fifo_sync.v:38`；`rtl/app_udp_pattern.v:497`；`rtl/udp_tx_frame.v:145-148,204,270-273`；`board/wrapper_p4.v:1214`(u_app_ctrl),`:2454/:2490/:2573`(app TX ready 通路),`:2533-2576`(u_udp_tx_cfg),`:2578-2600`(u_udp_tx),`:3118-3123`(SNAP_*_NW),`:3583-3596`(三条 snap_cdc)；`rtl/snap_cdc.v:52-56`(W/NW 与 dout_a/hold_b)；`board/ku5p_p6b_sysclk.xdc:31,36`；`board/build_p7b_ku5p.tcl:174`；
`_proj_10g/notes/P7B_WU_FIX.md:197-206`(OOC A/B)；`_proj_10g/notes/p7b_biz_build/src_sha256.{before,after}.txt`(9 文件指纹)；`CLAUDE.md:64-66`、`PORT_NOTES.md:5168-5170,5263`（"+320 FF"原文）；`git show 09d2189 -- rtl/app_ctrl.v`（C6 块 diff）。
