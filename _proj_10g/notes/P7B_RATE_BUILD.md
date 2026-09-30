# P7B 线速测量合并构建（8 路发生器 + 组帧器乒乓重叠）—— 时序终端报告

- 日期：**2026-09-30**　性质：**构建 + 时序测量报告**。
  本 agent **未改任何 RTL / XDC / strategy / seed**；**未烧板**（脚本无 `program_hw_devices`）、
  **未写 QSPI**、**未动 license**、**未碰 `D:\repo\perfv`**、**未做任何 git 写操作**（只读 `git status --short`）。
- 构建命令 = `cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'`（脚本原样；strategy 仍为 `Performance_ExtraTimingOpt`）。
- 构建窗口：`2026-09-30 17:23:25` → `17:50:47`（**~27.4 min**；上一版 12:01→12:22 为 ~21.5 min）。
- 上一版基线记录在 `_proj_10g/notes/P7B_BUILD_FINAL.md`（**本文件不覆盖它**）；上一版五份读数已归档到
  `_proj_10g/notes/p7b_ratebuild/prev/`（**构建前**拷贝，未经覆盖）。

---

## 0. 一页结论

> ### ✅ **收敛。**
> **`P7B_WNS = +0.136` / `P7B_WHS = +0.010`**；`report_timing_summary` 总表
> **setup / hold / pulse-width 三类失败端点全 0**
> （`All user specified timing constraints are met.` `board/p7b_ku5p_timing.rpt:159`）；
> **全部 intra / inter / other path group 逐组三类失败端点全 0**。
> **两处重点**：
> ① ⭐ **`txoutclk_out[0]_3`（TX 侧 73 位 mux 所在时钟域组）`+0.765 → +0.141`（−0.624 ns）**，
>    **但仍为正、仍 0 失败**；且该组本轮 worst path 的源/宿是 **`u_mac_tx/cw_len_reg[3]` → `pcs64_top`**
>    （**MAC TX CRC/padrem 局部簇，17 级逻辑、route 占 4.105/6.140 ns = 67%**），**路径里没有本轮新逻辑**
>    ⇒ 归因为**布局漂移**，不是新逻辑压垮。
> ② ⭐ **RAMB/LUTRAM 映射与预测吻合**：两个 256×73 bank **都落 LUTRAM（`RAM64M8 x 44` 各一）**，
>    **`Block RAM Tile` 348 → 348、`RAMB36/FIFO` 317 → 317、`RAMB18` 62 → 62（逐数不变）**；
>    **`LUT as Memory` 6318 → 6654（+336）**，与乒乓报告"≈ +340 LUTRAM"的分析值吻合。
> 位流：`vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`，**15,431,261 B**，
> sha256 `4eeb0f5f38537615cefbd63e6dc3608e8a6ae1c0362905b06d46cbde394b3133`。
> ⚠️ 位流虽出，**本轮未烧板**（按纪律）。

---

## 1. 构建脚本的 define 改动（**本 agent 唯一的源码改动**）

### 1.1 改动前后完整 define 列表

| | `verilog_define` 列表（逐字） |
|---|---|
| **改动前** | `{APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1}` |
| **改动后** | `{APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1}` |

- **只新增 `UDP_TX_OVL=1`，既有五个宏（含 `P7B_10G`）一字未动、顺序未动**。
- 改动处（`board/build_p7b_ku5p.tcl:140` 前）加了 **6 行注释**，逐字说明：
  "这一版是为了**线速测量**而打开 `UDP_TX_OVL`（组帧器乒乓重叠）……关掉这个 define 就回到 HEAD 的帧器行为
  （帧器 378 拍/帧 → 191 拍/帧）。同时 `P7B_10G` 内的 8 路并行图案发生器一并生效。两者叠加 = 本次线速测量构建；
  既有四个宏与 `P7B_10G` 一字未动。"
- **附带 1 行只读回显**（为让"宏真的生效"成为日志里可 grep 的读数，而非只能推断）：
  `puts "P7B_VERILOG_DEFINE = [get_property verilog_define [current_fileset]]"`
  ⇒ 实测输出（`board/p7b_ku5p_stdout.txt:270`）：
  `P7B_VERILOG_DEFINE = APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1`
  ⚠️ 这是本 agent 在"只加 define"之外**唯一的**脚本增行（无副作用、不参与综合），在此显式披露。
- 脚本 sha256：改动前 `d23865d5f4d562b8ac6bee71bad78cf5a2434da77aba3f41467f5bc13a757a9a`
  → 改动后 `01f0770afb6e18a9bff3b1b3c58f34e7591bcd465a3fdff27847d54faff4647b`（mtime `17:23:14`，**早于构建启动**）。
  副本留档：`_proj_10g/notes/p7b_ratebuild/build_p7b_ku5p.tcl.ovl`。

### 1.2 宏生效的**直接证据**（不是靠推断）

`board/p7b_ku5p_stdout.txt:1043-1044`（综合期端口例化）与 `:2712-2713 / :2913-2914`（LUTRAM 映射表）：

```
WARNING: [Synth 8-7023] instance 'u_fifo_a' of module 'fifo_sync' has 14 connections declared, but only 8 given [.../rtl/udp_tx_frame.v:161]
WARNING: [Synth 8-7023] instance 'u_fifo_b' of module 'fifo_sync' has 14 connections declared, but only 8 given [.../rtl/udp_tx_frame.v:167]
|u_udp_tx | u_fifo_a/mem_reg | Implied | 256 x 73 | RAM64M8 x 44 |
|u_udp_tx | u_fifo_b/mem_reg | Implied | 256 x 73 | RAM64M8 x 44 |
```

- `u_fifo_a`/`u_fifo_b` **只存在于 `ifdef UDP_TX_OVL` 分支**（默认分支是单个 `u_fifo`，`:517`）
  ⇒ **网表里同时出现两个 bank = 宏确实生效**。
- **上一版基线的 stdout 里 `u_fifo_b` 命中 0**（`grep -c` = 0）⇒ 与基线可区分。
- ⚠️ 那条 `8-7023`（"14 connections declared, but only 8 given"）是**本仓既有风格**，上一版 36 条 → 本轮 37 条
  （+1 = 第二个 bank），**不是新问题、不在任何硬门键里**。

### 1.3 源码 sha256 凭据（**构建前 / 构建后两次独立取样，逐字相同**）

| 文件 | mtime | sha256（前 16） | 构建后复核 |
|---|---|---|---|
| **`rtl/app_udp_pattern.v`**（8 路并行发生器） | 2026-09-30 **16:55:10** | `b6985b7d8e5e8786` | ✅ 逐字未变 |
| **`rtl/udp_tx_frame.v`**（乒乓重叠帧器） | 2026-09-30 **16:46:03** | `ab96d7af1f196be2` | ✅ 逐字未变 |
| `board/wrapper_p4.v` | 2026-09-30 13:38:12 | `ed2b834d76aefb6a` | ✅ |
| `board/build_p7b_ku5p.tcl`（本 agent 改后） | 2026-09-30 **17:23:14** | `01f0770afb6e18a9` | ✅ |
| `_proj_10g/p7b_mac/rtl/crc32_64.v` | 2026-09-29 21:20:48 | `9db328c7fe1a3140` | ✅ |
| `_proj_10g/p7b_mac/rtl/mac_rx_10g.v` | 2026-09-30 11:25:55 | `23fb46069a3c35cc` | ✅ |
| `_proj_10g/p7b_mac/rtl/mac_tx_10g.v` | 2026-09-30 10:44:16 | `034282a37764b9ff` | ✅ |

⇒ **全部源码早于构建启动（17:23:25），构建后逐字未变** ⇒ 本轮读数有效。

**"网表只含定版源码"的独立核查**：`import_files` 导入副本与 canonical 源逐字节比对 ——
`app_udp_pattern.v` `b6985b7d…` == `rtl/` 原件；`udp_tx_frame.v` `ab96d7af…` == `rtl/` 原件；
`mac_tx_10g.v` `034282a3…` / `mac_rx_10g.v` `23fb4606…` == `_proj_10g/p7b_mac/rtl/` 原件；
`wrapper_p4.v` `ed2b834d…` 两侧相同 ⇒ **无半改/陈旧副本混入**。

---

## 2. 判据逐条读数

### 2.1 位流与 banner

| # | 判据 | 读数 | 判定 |
|---|---|---|---|
| 1 | `BITSTREAM-OK` | bat 控制台尾行 `BITSTREAM-OK` | ✅ |
| 2 | `P7B_BIT_EXISTS = 1` | `1`（console + stdout） | ✅ |
| 3 | `BUILD_EXIT` | **0** | ✅ |
| 4 | `P7B_IS_LOCKED_POSTGEN` / `P7B_CONVERGED_AT_ROUND` | `0` / `2`（与上版一致） | ✅ |
| 5 | 位流指纹 | **15,431,261 B**；sha256 `4eeb0f5f38537615cefbd63e6dc3608e8a6ae1c0362905b06d46cbde394b3133` | ✅ |

⚠️ **bat 的三条硬门只打 banner、不置退出码** ⇒ 下面由本 agent 自行 grep 计数（不是引用 bat 的 banner）。

### 2.2 硬门逐串命中数 —— **主 stdout 与 OOC 分两栏**

**栏 A：主 `board/p7b_ku5p_stdout.txt`**

| 键 | 命中 |
|---|---|
| `12-4739` | **0** |
| `Synth 8-11241` | **0** |
| `undeclared symbol` | **0** |
| `VRFC 10-3091] actual bit length 1 differs from formal bit length` | **0** |
| `VRFC 10-2989` | **0** |
| `implicitly declared` | **0** |
| `NSTD-1` / `UCIO-1` / `AVAL-326` / `Opt 31-155` / `Opt 31-67` / `Route 35-7` | **0 / 0 / 0 / 0 / 0 / 0** |
| 字面 `DROPPED-CONSTRAINT-FAIL` / `IMPLICIT-NET-FAIL` / `DRC-KEY-FAIL` | **0 / 0 / 0** |

**栏 B：OOC / 子 run 日志**（⚠️ 独立一栏，不得与栏 A 相加）

| run | `Synth 8-11241` | `undeclared symbol` | `VRFC 10-3091…` | `VRFC 10-2989` | `implicitly declared` |
|---|---|---|---|---|---|
| `pcs64_synth_1/runme.log` | **28**（**已知例外**） | **28**（同批，见注） | 0 | 0 | 0 |
| `xdma_0_synth_1/runme.log` | **5**（同类） | **5** | 0 | 0 | 0 |
| `synth_1/runme.log` | 0 | 0 | 0 | 0 | 0 |
| `impl_1/runme.log` | 0 | 0 | 0 | 0 | 0 |

> **注（不许误读）**：`undeclared symbol` 的 28/5 **与 `Synth 8-11241` 的 28/5 是同一批消息** ——
> `Synth 8-11241` 的消息正文本身含 "undeclared symbol" 字样。**两者不得相加**。
> 28 与任务书预告的"OOC `pcs64_synth_1` 预计 ~28 条"**逐数吻合**，来源仍是厂商 `pcs64_wrapper.v`；**非本轮改动面**。

### 2.3 DRC

`board/p7b_ku5p_drc.rpt` 的 REPORT SUMMARY 表与上一版**逐行相同**（`diff` 退出 0）：
`DPIP-2 ×4 / DPOP-3 ×2 / DPOP-4 ×4 / DPOR-2 ×18 / REQP-1858 ×41`，共 69 项，
**Critical / Error 级 0 条**（全为 Warning）。bat 的 `DRC-KEY-FAIL` 六键 **0 命中**。

---

## 3. 设计时序总表（`board/p7b_ku5p_timing.rpt:150`）

```
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints  ...  WHS(ns)  ...  THS Failing  THS Total  ...  WPWS(ns)  TPWS Failing  TPWS Total
      0.136        0.000                      0               240450  ...    0.010  ...            0     240450  ...     0.000             0       78289
All user specified timing constraints are met.                                                                      (:159)
```

**三类失败端点（setup / hold / pulse-width）= 0 / 0 / 0**，WNS/WHS 均为正 ⇒ **判据成立**。
⚠️ 总表 `WPWS 0.000` 与上一版**同值同形**（逐组 pulse-width 松量见 §4，全部为正、0 失败）——
它是"无可行 pulse-width 检查"的报表形态，**不是违例**（TPWS Failing Endpoints = 0）。

⭐ **全局 WNS `+0.136` 的来处（本轮与上版不同）**：本轮它不是 `g_hw.clk_out0`，而是
**`**async_default**` 组的一条 recovery 检查**：
`u_pcie_xdma/…/user_reset_reg/C` → `u_snap_dp/dout_a_reg[254]/CLR`（**0 级逻辑、route 占 97.4%**，复位恢复路径），
**0 失败**。属既存形态（与快照逻辑挂钩），非本轮新增逻辑。

---

## 4. 逐 clock group（Intra Clock Table，`board/p7b_ku5p_timing.rpt:200` 起）

| clock group | WNS | setup fEP | EP | WHS | hold fEP | WPWS | PW fEP |
|---|---|---|---|---|---|---|---|
| `rxoutclk_out[0]_2` | +1.891 | **0** | 3429 | +0.019 | **0** | +0.514 | **0** |
| `rxoutclk_out[0]_3` | +0.342 | **0** | 9673 | +0.011 | **0** | +0.514 | **0** |
| ⭐ `txoutclk_out[0]_2` | +3.191 | **0** | 817 | +0.019 | **0** | +0.618 | **0** |
| ⭐⭐ `txoutclk_out[0]_3` | **+0.141** | **0** | 2380 | +0.011 | **0** | +0.618 | **0** |
| `txoutclkpcs_out[0]_2` | +4.837 | **0** | 34 | +0.019 | **0** | +2.828 | **0** |
| `txoutclkpcs_out[0]_3` | +4.807 | **0** | 34 | +0.084 | **0** | +2.828 | **0** |
| `pcie_ref_clk` | +7.342 | **0** | 3702 | +0.012 | **0** | +3.200 | **0** |
| `pcie_axi_aclk` | +0.288 | **0** | 48636 | +0.010 | **0** | +0.213 | **0** |
| `pipe_clk` | +0.850 | **0** | 2400 | +0.011 | **0** | +0.000 | **0** |
| `sys_clk_100` | +7.881 | **0** | 716 | +0.016 | **0** | +2.000 | **0** |
| **`g_hw.clk_out0`**（数据面 156.25 MHz） | **+0.295** | **0** | 135218 | +0.010 | **0** | +2.627 | **0** |
| `GTYE4_CHANNEL_TXOUTCLK[0..3]` | +0.501 ×4 | **0** | 1/1/1/5 | （无） | **0** | — | — |
| 三条 GTwiz CPLL-cal 时钟（`…/bufg_gt_txoutclkmon_inst/O`） | +6.619 / +6.707 / +6.895 | 0 | 50 ×3 | +0.044…+0.066 | 0 | +3.725 | 0 |
| `…/phy_clk_i/bufg_gt_intclk/O`（XDMA） | +998.821 | 0 | 20 | +0.059 | 0 | +499.725 | 0 |

**Inter Clock Table（`:230`）**：`txoutclk_out[0]_3 → rxoutclk_out[0]_3` **+4.908** / 0 失败（64 端点）；
`pipe_clk ↔ pcie_axi_aclk` +1.430 / +2.611，均 0 失败。

**Other Path Groups（`:242`）**：`**async_default**` **十二行**（`g_hw.clk_out0` +0.897/26662；
`pcie_axi_aclk` **+0.136**/4284 ← 全局 WNS；`pcie_ref_clk` +8.374/131；`pipe_clk` +2.808/13；
`rxoutclk_out[0]_2` +3.730/12；`rxoutclk_out[0]_3` +2.781/1307；`txoutclk_out[0]_2` +5.059/3；
`txoutclk_out[0]_3` +2.532/639；四条 XDMA CPLL-cal +7.261…+7.359/18）—— **全部 0 失败**。

### 4.1 ⭐ 任务书点名的两处

**① `txoutclk_out*`（帧器/TX 载荷侧）**

- `txoutclk_out[0]_3` 端点 **2381 → 2380（−1）** ⇒ **按端点指纹与上一版同组**（命名沿用同款 `_2`/`_3`）。
- WNS **+0.765 → +0.141（−0.624 ns）**，**仍为正、仍 0 失败**。
- **本轮该组 worst path 的身份**（`:764-800`）：
  `u_mac_tx/cw_len_reg[3]/C` → `u_mac_tx/u_crc/…` → `wrapper_p4/pcs64/…/pcs64_top_24/<hidden>`；
  **17 级逻辑（LUT6×8 + MUXF7×2）、Data Path Delay 6.140 ns 里 route 占 4.105 ns（66.9%）**。
  **上一版该组 worst path** 是 `u_mac_tx/padrem_reg[1]/C` → 同一 `pcs64_top_24` 簇（+0.765）。
  ⇒ **两轮 worst path 同属 `u_mac_tx` 的 CRC/padrem 局部簇**，本轮路径里**没有任何本轮新逻辑**
  （帧器 `udp_tx_frame` 属数据面 `dp_clk` 域 = `g_hw.clk_out0`，跨到 TX 侧要经 wrapper 的 `u_txcdc`
  异步 FIFO ⇒ 帧器的 73 位 mux **不在本组**；`u_udp_tx` 在整份 `p7b_ku5p_timing.rpt` 里 0 次出现，可佐证）
  ⇒ 归因为**布局/布线漂移**
  （DP 域 +3783 端点、+1632 LUT 改变全局布局压力），**不是新逻辑压垮**。
  ⚠️ 但这是本轮的**最薄处（+0.141）之一**，加逻辑前应先看它。

**② RAMB / LUTRAM 映射（乒乓的第二份 256×73 bank）**（`board/p7b_ku5p_util.rpt`）

| 项 | 上一版 | **本轮** | Δ |
|---|---|---|---|
| `Block RAM Tile` | 348 | **348** | **0** ✅ |
| `RAMB36/FIFO*`（`RAMB36E2 only`） | 317 | **317** | **0** ✅ |
| `RAMB18`（`RAMB18E2 only`） | 62 | **62** | **0** ✅ |
| `LUT as Memory` | 6318 | **6654** | **+336** ✅ |
| `CLB LUTs` | 70095 | **71727** | **+1632** |
| `CLB Registers` | 68471 | **69287** | **+816** |
| `CARRY8` | 1413 | 1410 | −3 |
| `F7 Muxes` / `F8 Muxes` | 3612 / 1237 | 3530 / 1230 | −82 / −7 |
| `URAM` / `DSPs` / `Bonded IOB` / `BUFG_GT` / `GTYE4_CHANNEL` | 0 / 4 / 10 / 13 / 6 | 0 / 4 / 10 / 13 / 6 | 0 |
| `BUFGCE` | 5 | **4** | −1 |

- **两个 bank 都落 LUTRAM**（`RAM64M8 x 44` 各一，见 §1.2）⇒ 与乒乓报告 §5 的**主分析路径一致**，
  且**排除了它预告的那条备选可能**（"若综合把其中一份改判成 BRAM，资源账会变成 +1 RAMB36 级"）——
  **实测没有发生**：BRAM 三类逐数不变。
- LUTRAM **+336 ≈ 预测 +340**（吻合 1%）；CLB LUT **+1632** 近似 = 第二份 `fifo_sync`（≈+579，其中 336 LUTRAM）
  + 73 位 mux ×2/FSM/帧上下文 + 8 路并行发生器的 `M^8` 常量 XOR 网。
- `BUFGCE 5→4` 是 `opt_design` 侧时钟 buffer 插入的非确定性（上一版对比里已两次出现 6/4/5 摆动），**非设计变化**。

---

## 5. 与上一版基线的并列表（同一套 `_2`/`_3` 命名 + 端点指纹双重对齐）

| 组（指纹 EP） | **上一版 12:22**（`P7B_BUILD_FINAL.md`） | **本轮 17:50** | Δ WNS |
|---|---|---|---|
| `rxoutclk` 3429-ep 组 | +2.242 / 0 | **+1.891 / 0** | −0.351 |
| `rxoutclk` ~9673-ep 组 | +0.209 / 0（9674） | **+0.342 / 0**（9673） | **+0.133** |
| `txoutclk` 817-ep 组 | +3.213 / 0 | **+3.191 / 0** | −0.022 |
| ⭐ `txoutclk` ~2380-ep 组 | +0.765 / 0（2381） | **+0.141 / 0**（2380） | **−0.624** |
| `txoutclkpcs` ×2 | +4.141 / +4.633 / 0 | **+4.837 / +4.807 / 0** | +0.696 / +0.174 |
| **`g_hw.clk_out0`（数据面 156.25 MHz）** | +0.128 / 0（131435） | **+0.295 / 0**（**135218**） | **+0.167**（EP **+3783**） |
| `pcie_axi_aclk` | +0.163 / 0 | +0.288 / 0 | +0.125 |
| `pipe_clk` | +0.917 / 0 | +0.850 / 0 | −0.067 |
| `sys_clk_100` | +7.766 / 0 | +7.881 / 0 | +0.115 |
| `pcie_ref_clk` | +7.294 / 0 | +7.342 / 0 | +0.048 |
| `txoutclk_out[0]_3 → rxoutclk_out[0]_3`（inter） | +4.770 / 0 | +4.908 / 0 | +0.138 |
| **全局 `P7B_WNS` / `P7B_WHS`** | **+0.128 / +0.010** | **+0.136 / +0.010** | **+0.008** |
| **三类失败端点合计** | **0** | **0** | — |
| **位流** | 15,431,261 B / `0e1c8088…b557` | 15,431,261 B / **`4eeb0f5f…b3133`** | 字节数相同、内容不同 |

**判据（三类全 0、WNS/WHS 为正）：两版都成立；本轮在两刀（8 路发生器 + 乒乓重叠，+1632 LUT / +336 LUTRAM）
落地后仍成立，全局 WNS 反而 +0.008。**

**读数的可信粒度（不许过读）**：本轮有 5 个与改动无关的域摆动 0.02–0.70 ns（`rxoutclk` −0.351、
`txoutclkpcs` +0.696、`pcie_axi_aclk` +0.125、`sys_clk_100` +0.115），与 `BUFGCE 5→4`、
CLB LUT 变化同源 ⇒ **单组 ±0.1 ns 级差属工具侧漂移**；但 **`txoutclk` 组的 −0.624 ns 超出该噪声带**，
故 §4.1 对它做了路径级归因（同簇、无新逻辑、route 主导）。

---

## 6. 归档与证据路径

| 内容 | 位置 |
|---|---|
| 本轮五份读数（现行） | `board/p7b_ku5p_{stdout,timing,util,drc,clkinteract}.*`（mtime 17:50:41–17:50:47） |
| 本轮五份读数（冻结副本） | `_proj_10g/notes/p7b_ratebuild/new/`（stdout `961d5034…`、timing `2d54aea8…`、util `d02c9800…`、drc `c8dddb39…`、clkinteract `61990a33…`） |
| **上一版**五份读数（**构建前**冻结） | `_proj_10g/notes/p7b_ratebuild/prev/`（stdout `a70825f6…`、timing `2d8b87f6…`、util `2628e3d6…`、drc `108ce429…`、clkinteract `dc73110c…`） |
| bat 控制台原文 | `_proj_10g/notes/p7b_ratebuild/build_console.txt` |
| 改后构建脚本副本 | `_proj_10g/notes/p7b_ratebuild/build_p7b_ku5p.tcl.ovl` |
| 位流 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`（15,431,261 B） |

**未改动的证据**：`board/build_p7b_ku5p.tcl` 除 §1 那一处外逐字未动；strategy 仍 `Performance_ExtraTimingOpt`；
**未换 seed、未换 strategy**（不靠凑收敛）。

---

## 7. 观察项（不需处理，但要记账）

1. **`Synth 8-589` 1 → 9**（`replacing case/wildcard equality operator !== with logical equality operator !=`），
   新增 8 条全部落在 `rtl/app_udp_pattern.v` 的新 `P7B_10G` 行（如 `:579/:601/:602`）。
   **是工具把 `!==` 替成 `!=` 的良性提示**（硬件无 X 态），且 RTL 已过 xsim 等价门；**不在任何硬门键里**。
2. **`Synth 8-3332` WARNING ×1（新增）**：`FSM_onehot_drn_reg[0] is unused and will be removed from module tcp_rx`
   —— 落在**本轮未触碰的 `tcp_rx`**，属优化侧非确定性，与两刀无关。
3. **`8-3917` 1 → 0**（纯优化提示减少）、**`8-7023` 36 → 37**（第二个 bank，见 §1.2）。
4. **位流大小与上一版逐字节相同（15,431,261 B）但 sha256 不同** —— 大小相同是巧合，**不要当成"内容未变"**。
