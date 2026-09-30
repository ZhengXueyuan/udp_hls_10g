# P7B-BIZ 合并构建（四组 RTL 改动一次合体）—— 构建 + 时序报告

- 日期：**2026-09-30**　性质：**构建 + 时序测量报告**（本 agent **未改任何 RTL/XDC/strategy/seed**，
  唯一的源码改动 = `BUILD_ID_V` 自增 7→8 及其期望值同步，见 §1）。
- **未烧板**（脚本内无 `program_hw_devices`；本 agent 未跑任何 `program_*.tcl`）、**未写 QSPI**、
  **未动 license**、**未碰 `D:\repo\perfv`**、**未做任何 git 写操作**（TL 统一做）。
- 构建命令 = `cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'`（脚本原样，strategy 仍 `Performance_ExtraTimingOpt`）。
- 构建窗口：**19:32:19 → 19:53:43**（~21.5 min；上一版 17:25→17:50 为 ~27 min）。构建前后无其它 Vivado/xsim 在跑。
- 留档目录 = `_proj_10g/notes/p7b_biz_build/`（主 stdout、4 份 runme.log、timing/util/drc/clkinteract、
  两轮指纹表、门 grep 输出、构建前后源码 sha256）。

---

## 0. 一页结论

> ### ✅ **构建收敛、时序三条硬门全过（0 失败端点）。**
> **`P7B_WNS = +0.077` / `P7B_WHS = +0.010` / `P7B_WPWS` 最小 0.010**；
> `report_timing_summary` 总表 **setup / hold / pulse-width 三类失败端点 = 0 / 0 / 0**
> （`All user specified timing constraints are met.`，`board/p7b_ku5p_timing.rpt`），
> 逐组（intra / inter / other 三张表）**每一组的三个失败端点数也都逐格为 0**。
> **全局 WNS 从上轮 +0.136 降到 +0.077（−0.059）**，**归因明确**：
> 全局最差路径 = `**async_default** pcie_axi_aclk` 的 **Recovery** 检查
> `u_pcie_xdma/…/user_reset_reg/C → u_pcie_regs/snap_words_r_reg[174]/CLR` ——
> **宿端是我们自己的快照寄存器阵列**（`_proj_pcie/rtl/axi_regs.v`，本轮 51 → **61 字** ⇒ +320 FF）。
> 该路径 **Logic Levels = 0、route 3.306/3.402 ns = 97.2%** ⇒ **纯扇出/布线代价**，不是逻辑深度问题。
> **上轮的全局最差是同一族**（`user_reset_reg/C → u_snap_dp/dout_a_reg[254]/CLR`，net fanout 4267）
> ⇒ 本条**是"同一端点族内换了最差那一位"**，不是新出现的缺陷族。
> 位流：`vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`，**15,431,261 B**，
> sha256 `d20c08c9e3483359d278893f58b69e921c02b33427430ebe1664571ec0655ed5`。
> ⚠️ 位流虽出，**本轮未烧板**（按纪律）。**构建期间源码逐字未变**（§7 漂移核对）。

---

## 1. BUILD_ID_V 自增 7 → 8（本 agent 唯一的源码改动）

本轮三路 agent 共改 `board/wrapper_p4.v`，按 `P7B_BIZ_WINDOW.md` **R6** 的约定
"合体时统一自增一次" ⇒ 本次自增。源码注释里 **8 = P7B-BIZ / 61 字**的说明**本轮已由写窗口的 agent 预置**，
故只动数字。

| # | 文件:行 | 改动 |
|---|---|---|
| 1 | `board/wrapper_p4.v:3832` | `.BUILD_ID_V (32'h00000007)` → **`32'h00000008`** |
| 2 | `_proj_pcie/p7b_gate4_accept.sh:108` | `EXPECT_BID=${EXPECT_BID:-0x00000007}` → **`0x00000008`**（同行尾注 `# P7b = 7 (…:3701…)` → `# P7B-BIZ = 8 (…:3832…)`） |
| 3 | `_proj_pcie/p6e_snap_check.sh:43` | `EXPECT_BID` 默认值 → **`0x00000008`** |
| 4 | `_proj_pcie/p7b_biz/p7b_snap.sh:35` | `EXPECT_BID` 默认值 → **`0x00000008`** |
| 5 | `_proj_pcie/p7b_gate4_selftest.sh:72` | 假板子 `0X04) V=0x00000008`（**必须跟着改**：自证脚本用默认 `EXPECT_BID` 跑 `p6e_snap_check.sh`，不改则正例必 FAIL） |
| 6 | `_proj_pcie/p6e_snap_selftest_fix2.sh:67` | 同上（假板子 BID） |
| 7 | `_proj_pcie/p7b_gate4_livefake.sh:79` | 假对端快照块 `BID 0x00000008` |
| 8 | `_proj_pcie/p7b_gate4_negctrl.sh:50` | 负对照的**规范快照** `BID 0x00000008` |

- 定位法 = 任务给的 `grep -rn "00000007" _proj_pcie/ | grep -i bid`，**7 处 .sh 全部命中且全部改到**
  （改后 `grep -rn "0x00000007" --include="*.sh" _proj_pcie/` = **0 命中**）。
  其余 4 处命中是 `_proj_pcie/probe/**.gen/**`、`vivado_prj/**.gen/**` 里 Xilinx IP 自己的
  `.INIT(64'h…0007)` 常量，与位流身份无关，**未动**。
- **刻意未动**：`_proj_pcie/p6b_accept.sh:80` 与
  `p6b_accept_final/srv_p6b_final_accept.sh:45` 的 `EXPECT_BUILD_ID=0x00000006` ——
  那是 **P6b（36 字）位流自己的身份**，那份位流仍在、仍需可被识别，**不是本轮该改的期望值**
  （且本轮 grep 键是 `00000007`，这两处不命中）。
- **只改了位流身份相关的期望值**，其它常量（`SNAP_WORDS`/`NW`/`UNIMPL_ADDR`/频率标称/容差…）**一字未动** ——
  本轮它们**本来就已是 61 / 0x114**（上一轮扩窗 agent 已改），无需跟进。
- ⚠️ **未改的陈旧注释（留给 TL 决定）**：`p7b_gate4_accept.sh:128`、
  `p6e_snap_check.sh:57` 里 `"…(默认几何 61 字 / BID=7)"`、`p7b_biz/p7b_snap.sh:2` 的
  `"(P7B-BIZ: BID=7 (合体后 8))"` —— 这些行**不含 `0x00000007` 字面量**，不在任务给的 grep 面内，
  且不影响任何判据（判据读的是 `EXPECT_BID` 变量）。**未擅自改**。

### 1.1 define 行（原文，`board/p7b_ku5p_stdout.txt:270`）

```
P7B_VERILOG_DEFINE = APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1
```
六个宏与任务要求逐字一致。旁证（同一份 stdout）：`P7B_CONVERGED_AT_ROUND = 2`、
`P7B_IS_LOCKED_POSTGEN = 0`、`P7B_TOP = wrapper_p4`、`P7B_NFILES = 440`。
`board/build_p7b_ku5p.tcl` 与 `board/run_build_p7b_ku5p.bat` **本轮未改**
（sha256 与上轮记录 `01f0770a…`/`78933137…` 相同）。

---

## 2. ⭐ 三条硬门：逐串 grep（**两栏**）

**面为什么必须分两栏**：`run_build_p7b_ku5p.bat` 的三条门 `findstr … p7b_ku5p_stdout.txt` **只扫主 stdout**，
且**命中只打 banner、不置退出码**（照样 `exit /b 0`）⇒ 覆盖面上缺**整个 OOC run 日志这一半**。
本次**两栏都量**（原始输出 = `_proj_10g/notes/p7b_biz_build/gatecheck_out.txt`）。

| KEY | 主 stdout | 4 份 run 日志合计 |
|---|---:|---:|
| `12-4739`（约束被静默丢弃） | **0** | **0** |
| `Synth 8-11241` | **0** | **33** |
| `undeclared symbol` | **0** | **33**（与上行同 33 行） |
| `VRFC 10-3091] actual bit length 1 differs from formal bit length` | **0** | **0** |
| `VRFC 10-2989` | **0** | **0** |
| `implicitly declared` | **0** | **0** |
| `NSTD-1` / `UCIO-1` / `AVAL-326` | **0** / **0** / **0** | **0** |
| `Opt 31-155` / `Opt 31-67` / `Route 35-7` | **0** / **0** / **0** | **0** |
| （宽面）`^ERROR` | **0** | **0** |
| （宽面）`^CRITICAL WARNING` | **3** | **3** |
| （宽面）`VRFC 10-` / `xelab` / `[Synth 8-36]` | **0** / **0** / **0** | **0** |
| （宽面）`Synth 8-` | 1366 | 2435 |

### 2.1 那 33 条的来源（**逐条落到文件**，全部是厂商 IP 生成源码，**我们自己的 RTL = 0 条**）

- **28 条** 在 `runs/pcs64_synth_1/runme.log`，**同一份文件**：
  `vivado_prj/p7b_ku5p_prj.gen/sources_1/ip/pcs64/xxv_ethernet_v5_0_2/pcs64_wrapper.v`
  （`qpll0/1clk_in[*]`、`qpll0/1refclk_in[*]`、`gtwiz_reset_qpll*`、`gt_txusrclk2_*`、`gt_rxusrclk2_*`、`drprst_in_*`）
  ⇒ 与任务预告的"**OOC run 日志里有同族 28 条不在默认 grep 面内**"**逐数吻合**。
- **5 条** 在 `runs/xdma_0_synth_1/runme.log`（`RdDeQ`、`cfg_config_space_enable`、`cfg_hot_reset_in`、
  `usr_irq_fail`、`conf_mcap_design_switch_o`）⇒ 厂商 `xdma` 源码。
- **归属判据（不是推断）**：`grep -h "Synth 8-11241" runs/*/runme.log | grep -cE "udp_hls_10g/(rtl|board|_proj_pcie)/"`
  = **0**。33 条的路径全部落在 `….gen/sources_1/ip/…`（IP 生成目录）。
- ⚠️ **两条对该面的事实更正**（供后续引用）：
  1. **任务里说"厂商 `pcs64_pkt_gen_mon*.v` 有 10 条已登记不修"**：**本构建里那些文件根本不存在**
     （`find vivado_prj/p7b_ku5p_prj.gen -iname "*pkt_gen_mon*"` = 空；4 份 runme.log 里 0 命中）。
     全仓该文件只存在于**闸 1 / example 工程**：`_proj_10g/xxv_loop/rtl/pcs64_pkt_gen_mon_ds.v`、
     `_proj_10g/xxv_gate2/v2/rtl/pcs64_pkt_gen_mon_g2.v`、`_proj_10g/p7b_mac_synth/xxv_mac/rtl/…`、
     `_proj_10g/xxv_probe/*/imports/*pkt_gen_mon.v`（共 6 个，**一个都不在 `board/build_p7b_ku5p.tcl` 的导入表里**）
     ⇒ 那 10 条**不是被修掉了，而是本轮构建面里没有它们**（example design 不进合体构建）。
  2. **主 stdout 栏恒 0 是"结构性"的**：`launch_runs` 的子进程日志进 `runs/*/runme.log`，
     只有部分消息回灌控制台；`8-11241` 恰好一条都不回灌 ⇒ **bat 的第一/二条门在主 stdout 上对本坑永久为 0**。
     本轮 33 条的发现**全部来自我另开的那一栏**。

### 2.2 `VRFC 10-3091` 面（任务点名"本轮没有自动化覆盖"）的**替代检查**

包装级 `xelab` 跑不动（要 IP 生成物），故按任务指示改用 **`synth_design` 的 `Synth 8-` 面 + 人工比对端口位宽**：

> **（a）`Synth 8-` 面**：主 stdout 的 `Synth 8-` 消息 ID 直方图与上轮基线**逐 ID 同族**，
> 仅计数微动（`8-4490` 93→101、`8-7023` 37→38），**没有出现任何新 ID，也没有 `8-11241`/`8-36`**。
> 面内 ID 全是既有的 `8-3886/3333/3332/7129/7071/7052/6157/6155/4490/6793/6792/6904/3936/3971/6014/3354/802/5546`
> ⇒ **无"隐式 1 位网"与"位宽不符"族的新增签名**。
>
> **（b）人工逐端口位宽比对（本轮新增的三根线 + 61 字装配）**：
>
> | 源端口（声明） | 包装侧线网（声明） | 结论 |
> |---|---|---|
> | `app_udp_pattern.stat_tx_ovf`：`output reg [31:0]`（`rtl/app_udp_pattern.v:132`） | `udpapp_tx_ovf`：`wire [31:0]`（`wrapper_p4.v:1291`），接于 `:2510` | 32↔32 ✅ |
> | `slow_rx_adp.stat_fifo_ovf`：`output reg [31:0]`（`:66`） | `srx_stat_fifo_ovf`：`wire [31:0]`（`:2172`），接于 `:2371` | 32↔32 ✅ |
> | `slow_tx_adp.stat_fifo_ovf`：`output reg [31:0]`（`:30`） | `stx_stat_fifo_ovf`：`wire [31:0]`（`:2172`），接于 `:2413` | 32↔32 ✅ |
> | `frame_fifo.full_next` / `.ovf_pulse`：`output wire`（1 位，`rtl/frame_fifo.v:89-90`，**端口表末尾**） | `slow_tx_adp` 侧 `wf_full_next`/`wf_ovf`：`wire`（`:77`），接于 `:86-87` | 1↔1 ✅ |
> | 同上 | `slow_rx_adp` 的 `u_ff`（`:94-100`）**未接**这两个新口 | **故意、已核实不是漏接**：该实例的 `ff_wr` 是**组合**门 `wire ff_wr = … && !ff_full;`（`:87`），写决策与落笔同拍 ⇒ 用本拍 `full` 本就精确；只有"写决策已寄存"的位点才需要 `full_next`（`app_udp_pattern`/`slow_tx_adp`/`slow_rx_adp` 的字节口/mac_rx_64 四处正是如此） |
> | `axi_regs` 的 `ar_word/w_word/r_word` 6→7 位（`_proj_pcie/rtl/axi_regs.v:152,192,193`） | 取 `[8:2]`；`r_word[6:0]` 与 `SNAP_NW` 派生的 `r_word - 8` 下标配套 | ✅ |
>
> **（c）61 字装配逐项核对**（`wrapper_p4.v:3630-3656`）：拼接项 = `p7bdp` 18 项（槽 21..12 与 11..6、1、0）
> + `txsnap` 4 项（W41..W44）+ `p7bfe` 3 项（W36..W38）+ `snap_dout` 36 字（W35..W0）
> = **25 + 36 = 61 项**，且字序**严格递减 W60→W0、无缺号无重复**；
> 每项恰 32 位，总线 `SNAP_NW_P6E*32 = 1952` 位 = 61×32 ✅。
> `SNAP_P7BDP_NW = 22`（`:3122`）：`generate` gi=0..11 覆盖槽 0..11 + **逐槽显式 assign** 槽 12..21
> ⇒ 22 槽无重叠、无空洞 ✅（槽 2..5 是留给 tx 束的常量位，不出现在拼接里，符合注释）。
>
> ⚠️ **这一面的强度声明**：它证明的是"**本轮新增连线没有位宽不符/隐式网的签名，且装配项数与字序正确**"；
> 它**不等于**跑了包装级 `xelab`（本工程坑 24 说得很清楚：`synth_design` 与 `xelab` 是**两个检测点**）。

---

## 3. ⭐⭐ 时序（**硬门**）：三个数 + 三类失败端点

### 3.1 全局（`board/p7b_ku5p_timing.rpt` 的 `| Design Timing Summary`）

| 项 | 本构建 (BIZ) | 上轮 (RATE) | Δ |
|---|---|---|---|
| **WNS** | **+0.077** | +0.136 | **−0.059** |
| TNS / setup 失败端点 | 0.000 / **0** | 0.000 / 0 | — |
| setup 总端点 | 242723 | 240450 | +2273 |
| **WHS** | **+0.010** | +0.010 | 0 |
| THS / hold 失败端点 | 0.000 / **0** | 0.000 / 0 | — |
| **WPWS** | **0.000** | 0.000 | 0 |
| TPWS / 脉宽失败端点 | 0.000 / **0** | 0.000 / 0 | — |
| 结论行 | `All user specified timing constraints are met.` | 同 | — |

> **三类失败端点 = 0 / 0 / 0** ⇒ **按铁律，本构建"构建通过"成立。**
> 另核对 `report_drc`：**0 ERROR / 0 CRITICAL**；summary 表与上轮**逐行相同**
> （DPIP-2×4、DPOP-3×2、DPOP-4×4、DPOR-2×18、REQP-1858×41，**全部 Warning 级**，
> 且全在 HLS/DSP/RAMB 建议项上，`NSTD-1`/`UCIO-1`/`AVAL-326` 无命中）。

### 3.2 **按端点指纹**逐组对比（⚠️ 不按 clock group 名；名后缀 `_2/_3` 会跨轮漂移）

方法 = `_proj_10g/notes/p7b_biz_build/fingerprint.py`（本轮新写；输出 = `prev_fingerprint.txt` / `new_fingerprint.txt`），
对每个 (From Clock, To Clock) 块取**最差 setup 路径的 Source→Destination 端点**，并把 `…_N` 后缀归一化。
本轮**各组的端点总数与上轮几乎逐一相同**（3429/9673→9674/817/2380/34/3702/48636→49500/2400/716/135218→135648）
⇒ 分组**未被重编号**，指纹与计数**双证对齐**。

| 组（指纹对齐） | 最差端点（本构建） | WNS 本构建 | WNS 上轮 | Δ |
|---|---|---:|---:|---:|
| `**async_default** pcie_axi_aclk`（**= 全局 WNS**） | `user_reset_reg/C → u_pcie_regs/snap_words_r_reg[174]/CLR` | **0.077** | 0.136 | **−0.059** |
| `g_hw.clk_out0` intra（**DP 域**） | `u_tcp_tx/u_retx/ra_o_r_reg[2]_rep__11/C → …g_byte[1].mem_o_reg_7_bram_6/ADDRBWRADDR[5]` | **0.192** | 0.295 | **−0.103** |
| `**async_default** g_hw.clk_out0` | `rstb_sync_reg[1]/C → hold_b_reg[516]/CLR` | 0.966 | 0.897 | +0.069 |
| `rxoutclk_out[0]_2` intra | `<hidden>→<hidden>`（PCS 内部） | 1.671 | 1.891 | −0.220 |
| `rxoutclk_out[0]_3` intra（**FE/gmii 域**） | `… → u_mac_rx/stat_crc_err_reg[28]/CE` | **0.668** | 0.342 | **+0.326** |
| `txoutclk_out[0]_2` intra | `<hidden>→<hidden>` | 3.405 | 3.191 | +0.214 |
| `txoutclk_out[0]_3` intra | `u_mac_tx/padrem_reg[1]/C → pcs64_top/<hidden>` | **0.417** | 0.141 | **+0.276** |
| `txoutclkpcs_out[0]_2` / `_3` | `gen_powergood_delay…` | 4.735 / 4.415 | 4.837 / 4.807 | −0.102 / −0.392 |
| `pcie_ref_clk` intra | `GTYE4_CHANNEL_PRIM_INST/DRPCLK → do_r_reg[14]/CE` | 7.398 | 7.342 | +0.056 |
| `pcie_axi_aclk` intra | `m_axis_rq_tvalid_d_ff_reg/C → rreq_head_rcb_ok_ff_reg[0]/D` | 0.308 | 0.288 | +0.020 |
| `**async_default** pcie_ref_clk` | `arststages_ff_reg[1]/C → rst_n_internal_i_reg[0]/CLR` | 8.424 | 8.374 | +0.050 |
| `**async_default** pipe_clk` | `…async_rst…/PRE` | 0.831 | 2.808 | −1.977 |
| `**async_default** rxoutclk_out[0]_2` / `_3` | `s_out_d4_reg/C → …` | 5.286 / 1.801 | 3.730 / 2.781 | +1.556 / −0.980 |
| `**async_default** txoutclk_out[0]_2` / `_3` | `s_out_d4_reg/C → …` | 5.650 / 2.665 | 5.059 / 2.532 | +0.591 / +0.133 |
| `pipe_clk` intra | `rst_psrst_n_r_rep_reg/C → …eios_det_extend_reg[1]/R` | 0.755 | 0.850 | −0.095 |
| `sys_clk_100` | `master_watchdog_1_reg[25]/C → …[16]/R` | 8.059 | 7.881 | +0.178 |
| inter `txoutclk_out[0]_3 → rxoutclk_out[0]_3` | `stat_abort_reg[22]/C → hold_b_reg[214]/D` | 4.679 | 4.908 | −0.229 |
| inter `pipe_clk ↔ pcie_axi_aclk` | `rst_psrst_n_r_rep_reg/C → …` | 1.322 / 2.707 | 1.430 / 2.611 | −0.108 / +0.096 |
| hold（全部组）最小 | — | **0.010** | 0.010 | 0 |

### 3.3 两处**变差**的归因（**逐条给证据，不是"看起来像布局漂移"**）

**① 全局 WNS −0.059**：`**async_default** pcie_axi_aclk` 的 **Recovery** 检查
（异步复位 `user_reset` 撤除，宿 = FF 的异步 `CLR` 脚）：

- 宿端 **`u_pcie_regs/snap_words_r_reg[174]/CLR`** ⇒ **我们自己的**快照寄存器阵列，
  正是**组 ③**（`_proj_pcie/rtl/axi_regs.v`，窗口 51→61 字 ⇒ 该阵列 1632 → 1952 位，**+320 FF**）。
- 该路径 `Data Path Delay 3.402 ns = logic 0.096 (2.8%) + route 3.306 (97.2%)`，**Logic Levels = 0**
  ⇒ **源 FF 经纯布线直抵宿 CLR**，没有任何可优化的逻辑；变差的机制只能是**复位网扇出/布线变长**。
- **同一族的直接旁证（上轮读数，原文在案）**：上轮全局最差 = `user_reset_reg/C → **u_snap_dp/dout_a_reg[254]/CLR**`
  （`dout_a` 在 `rtl/snap_cdc.v:58`，是**我们**的另一处快照寄存器），该行还印着 **`net (fo=4267, routed)`**
  ⇒ 这条复位网本来就有 4267 的扇出，**加 320 个 FF 必然拉长它**。
- 该组的端点数 **4284 → 4859（+575）**，与 "+320 FF(阵列) + 96 FF(三个新计数器) + …" 量级一致。
- 影响面（**重要**）：这是**异步复位的 Recovery/Removal 检查**，判据要求复位撤除相对于时钟沿的裕量；
  0.077 ns **为正**且 0 失败端点 ⇒ **无功能影响**（它约束的是"复位撤除晚 0.077 ns 是否会被某个 FF 采到"，
  而该 FF 采的是我们自己的快照镜像寄存器）。

**② DP 域 intra −0.103**：`u_tcp_tx/u_retx/ra_o_r_reg[2]_rep__11/C → u_tcp_tx/u_retx/g_byte[1].mem_o_reg_7_bram_6/ADDRBWRADDR[5]`：

- 该模块 = **`rtl/retx_ram.v`（重传 RAM）**，**本轮四组改动一处都没碰它**。取证（只读 `git status --short`）：

  ```
   M _proj_pcie/rtl/axi_regs.v      M rtl/app_udp_pattern.v     M rtl/frame_fifo.v
   M board/wrapper_p4.v             M rtl/slow_rx_adp.v         M rtl/slow_tx_adp.v
  ```
  = **恰好就是任务表的四组**（组③的 `axi_regs.v` + 组① + 组② + 我本轮的 `BUILD_ID_V` 那一行），
  且 `git status --short -- rtl/retx_ram.v` **为空**（`retx_ram.v` 逐字未改）。
- `Data Path Delay 5.725 ns = logic 0.096 (1.7%) + route 5.629 (98.3%)`，**Logic Levels = 0**
  ⇒ **源 FF 直连 BRAM 地址脚**，纯布线 ⇒ **归因 = 布局漂移**（与上轮自己给 `cw_len_reg → pcs64` 那条的归因同款）。
- 且该组 WNS 虽然降了 0.103，**仍是正的（0.192）**，且该组是 **DP 域**（新逻辑的主要落点）——
  也就是说**新逻辑所在的域整体仍有 0.192 ns 裕量**。

### 3.4 两处**变好**（反向证据，说明不是"整体被压垮"）

- `rxoutclk_out[0]_3`（**FE / gmii 域**，我们 10G MAC 的落点）0.342 → **0.668（+0.326）**，
  且最差端点仍是 `u_mac_rx/stat_crc_err_reg[28]/CE`（**同一端点，指纹未变**）。
- `txoutclk_out[0]_3`（MAC TX）0.141 → **0.417（+0.276）**，最差源端点从 `u_mac_tx/cw_len_reg[3]/C`
  换成 `u_mac_tx/padrem_reg[1]/C`（仍是 MAC TX 内部，**未被新逻辑占据**）。

---

## 4. ⭐ 对任务点名的两个时序风险点的逐条回应

### 风险点 A：`app_udp_pattern.v` 的 `full_next` 进了 `gen_ok → txf_wr` 锥（上一轮 WNS 只有 +0.136）

| 判据 | 读数 | 结论 |
|---|---|---|
| 该锥是否成为**全局**最差？ | 全局最差 = pcie async 的 snp 复位 Recovery（0.077），与 app_udp 无关 | **否** |
| 该锥是否成为**DP 域**最差？ | DP 域 intra WNS = **0.192**，最差端点 = `u_tcp_tx/u_retx/…`（retx_ram，0 逻辑级） | **否** |
| 该锥是否出现在报告的最差路径集里？ | `grep -c "txf_wr\|full_next\|stat_tx_ovf" board/p7b_ku5p_timing.rpt` = **0 / 0 / 0** | **否** |
| **该锥的裕量下界**（可下结论的强判据） | `Intra Clock Table` 的 `g_hw.clk_out0` 行 WNS = **0.192** 是**该组真实最差值**（不是抽样）；`app_udp_pattern` 属该域（旁证：脉冲宽度表里 `u_app_udp/u_txf/mem_reg_0_63_0_6/RAMA/CLK` 明确标在 `Clock Name: g_hw.clk_out0` 下）⇒ **该域内任意路径裕量 ≥ 0.192 ns** | **≥ 0.192 ns** ✅ |
| 新改的那只 FIFO 自身的脉宽检查 | DP 域脉宽最差 = `u_app_udp/u_txf/mem_reg_0_63_0_6/RAMA/CLK`：Required **0.573** / Actual **3.200** / Slack **2.627** | ✅ 2.627 ns 裕量 |

⇒ **判据成立：这个锥没有变成临界路径，也没有产生任何失败端点。**
⚠️ **强度声明**：本结论的依据是"**分组 WNS 是该组真实最差**"，**不是**逐路径遍历（报告只印最差路径，
不印第 2 名）；我没有重建 `report_timing` 单独点这条路径（那要另开 Vivado 打开 routed DCP，
超出本 agent 边界且会污染构建窗口）。若 TL 要"该锥的精确裕量"，建议在**不构建**的前提下另外派人做一次
`open_checkpoint …_routed.dcp` + `report_timing -from …/txf_wr* -to …`。

### 风险点 B：`frame_fifo` 两个新端口、两个适配器各一个 32 位计数器、窗口多 10 个字 + `axi_regs` 位宽 6→7

| 改动 | 所在域 | 该域 WNS 变化 | 结论 |
|---|---|---|---|
| `frame_fifo.full_next/ovf_pulse` + `slow_tx_adp/slow_rx_adp` 的两个 32 位计数器 | DP（`g_hw.clk_out0`） | **0.295 → 0.192（−0.103）**，但该域最差端点是 **retx_ram 的纯布线**（与本次改动无关） | 未成为瓶颈 ✅ |
| 快照窗口 +10 字 / `axi_regs` 6→7 位 | `pcie_axi_aclk` | intra **+0.020（变好）**；**async（复位）−0.059（变差）** | **本轮唯一可归因于改动的变差**，见 §3.3 ① ✅（仍为正、0 失败） |
| 全设计 | — | setup/hold/pw 失败端点 **0/0/0** | ✅ |

**位宽/扇出之外的旁证**：`CLB Registers 69287 → 70026（+739）`、`CARRY8 1410 → 1424（+14）`、
`CLB LUTs 71727 → 71516（−211）`、`Block RAM 348 → 348（逐数不变）`、`DSP 4`、`IOB 10`、`GTY 6`（不变）
⇒ 新增资源量级与"三段 RTL 改动（两处 32 位计数器 + 一处 32 位计数器 + 窗口 320 FF + 64 FF 发生器 + 2×27 位寄存器）"相符，
**没有意外的大宗资源变化**（尤其 BRAM 未动，符合"两支适配器只加计数器、帧缓冲结构不变"）。

---

## 5. 产物与身份

| 项 | 值 |
|---|---|
| 位流路径 | `D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4.bit` |
| 字节数 | **15,431,261 B**（上轮同为 15,431,261 B） |
| sha256 | **`d20c08c9e3483359d278893f58b69e921c02b33427430ebe1664571ec0655ed5`** |
| 上轮位流 sha256 | `4eeb0f5f38537615cefbd63e6dc3608e8a6ae1c0362905b06d46cbde394b3133`（**不同** ⇒ 确实换了位流） |
| `P7B_IMPL_STATUS` | `write_bitstream Complete!`；`P7B_BIT_EXISTS = 1`；bat 末行 `BITSTREAM-OK` |
| BUILD_ID_V（板级读 `0x04` 的期望） | **`0x00000008`** |

**板侧前置闸（留给后续上板的人）**：读 `0x04` 必须 = `0x00000008`、`0x00` = `0x50360001`、
`0x14` = `0xdeadbeef`；窗口 **61 字**（`0x20..0x110`），未实现地址 **`0x114`**（必须回 `0xffffffff`），
**绝不能挑 ≥ `0x200`**（7 位译码会回绕到 word 0 = MAGIC ⇒ 假 FAIL）。

---

## 6. 构建产物留档（`_proj_10g/notes/p7b_biz_build/`）

| 文件 | 内容 |
|---|---|
| `p7b_ku5p_stdout.txt` | **主 stdout 原件**（524,901 B） |
| `runme_synth_1.log` / `runme_impl_1.log` / `runme_pcs64_synth_1.log` / `runme_xdma_0_synth_1.log` | **四份 run 日志原件**（"OOC 那一栏"的原始面） |
| `p7b_ku5p_timing.rpt` / `p7b_ku5p_util.rpt` / `p7b_ku5p_drc.rpt` / `p7b_ku5p_clkinteract.rpt` | 四份报告原件 |
| `timing_key_sections.txt` | 全局汇总 + 三张分组表的关键段抽取 |
| `gatecheck.sh` / `gatecheck_out.txt` | 三条硬门的**两栏** grep 脚本与输出（含 33 条逐条明细） |
| `fingerprint.py` / `prev_fingerprint.txt` / `new_fingerprint.txt` | 端点指纹抽取器 + 两轮指纹表 |
| `build_console.txt` | bat 的控制台输出（含 `BUILD_EXIT=0` 与读数行） |
| `src_sha256.before.txt` / `src_sha256.after.txt` | 9 个源文件构建前后的 sha256（**diff 为空**） |
| `prev/` | 预留目录（本轮未用；上轮原件已由 RATE 轮存在 `../p7b_ratebuild/new/`，我**未覆盖**它） |

---

## 7. 未做 / 风险 / 待办

1. **未烧板**（纪律）。**位流未上板验证** ⇒ `W56/W59/W60` 三个新观测字、`BUILD_ID_V=8`、
   以及组 ① 的"每帧不再丢 8 B"**都还没有板级读数**。板级前置闸见 §5 末。
2. **未跑 `sim/**` 的任何门**（另一个 agent 正在改 `sim/**`，且任务划为禁写区）。
   ⇒ 组 ①/② 的功能性（"`full_next` 真的消掉了那一字丢失"）**本轮无功能证据**，
   只有结构/装配证据（§2.2）+ 时序证据（§4）。
3. **未验证 `ifdef` 的四组合**（`P7B_10G` × `PCIE_OBS` 等）。本轮只构建了
   `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1` **一种**配置。
   `P7B_BIZ_WINDOW.md` 提到的"快照语义静默失真"（单域 + PCIE_OBS 组合）**本轮依旧未测**。
4. **`VRFC 10-3091` 的自动化覆盖仍然是缺的**：本轮用 §2.2 的替代面顶了一次，
   但**没有门**会在下次改动时自动跑这一面（`synth_design` 只覆盖端口连接形态，`xelab` 面要 IP）。
   ⇒ 建议后续把"**主 stdout + 全部 run 日志**"两栏都纳入 `run_build_p7b_ku5p.bat` 的 grep 面
   （本次已证明单栏会漏掉 33 条；且现在的三条门"命中只打 banner、不置退出码"也不构成门）。
5. **全局 WNS 余量变薄**：+0.136 → **+0.077**。虽然 0 失败端点，但**下一位往窗口里加字
   （快照阵列再长）会直接吃掉这条复位 Recovery 的裕量**（每 +10 字 ≈ +320 FF）。
   建议在"再加字"之前处理这条族（**改法由 TL 定，我未实施**）。可选最小改法，按代价排序：
   - **(a) 给快照阵列的复位加一级本域同步**：把 xdma 的 `user_reset` 在 `pcie_axi_aclk` 域内
     打两拍（`(* ASYNC_REG *)`）后再驱动 `snap_words_r` 的异步 CLR ⇒ 源端从"厂商 FF 经长网"
     变成"我们自己的 FF"，长网消失。**代价**：复位撤除晚 2 拍（对"快照镜像寄存器"无功能影响，
     但要确认 `snap_words_r` 的复位语义确实只是"清快照"）。
   - **(b) 给该复位网加 `max_fanout` / `(* max_fanout = N *)`** 强制工具复制驱动 ⇒ 扇出摊薄。
     **代价**：可能引入新的复位偏斜（各复制份撤除时刻不同），对本设计应先评估。
   - **(c) 接受现状**：0.077 ns 为正、0 失败端点，且这是**恢复检查**（不是功能路径）。
     **代价**：下一次加字就很可能翻负 —— 那才是真正需要停下来的时候。
6. **两处变差的归因强度**：§3.3 ② 的 retx_ram 路径我判为"布局漂移"，
   证据是"该模块本轮未改 + 0 逻辑级 + 98.3% route"，**属强旁证而非判决性证据**
   （判决性证据 = 同源码重跑一次 impl 看该路径是否重现/消失；本轮**未做**第二次构建）。
7. **一条留给文档的口径**：本文件里所有"上轮"读数均取自
   `_proj_10g/notes/p7b_ratebuild/new/`（RATE 轮 17:50 原件），**未覆盖**；
   `P7B_RATE_BUILD.md` 记载的 `+0.136 / 0 失败 / sha256 4eeb0f5f…` 与之逐字一致。
