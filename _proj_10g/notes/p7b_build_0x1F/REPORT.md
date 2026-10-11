# 构建 agent 报告（M1 载荷镜像窗 / BID `0x1F`）

**边界声明**：未烧录、未连 JTAG/hw_server、未碰板卡、未 ssh 对端、未写 QSPI、未改 `rtl/`·`tb/`·`sim/`、未走 GUI / `vivado_prj` 里那份 BID 0xA 旧 wrapper、未在仓内建任何 `prj_*` scratch。只改了 `board/wrapper_p4.v` 的**一处值 + 一处 BID 注释块**；git 只读（未提交）。本轮**不**下 PASS/FAIL 裁定。

| 项 | 值 |
|---|---|
| 位流 | sha256 **`e365c5ca4fd25335f6713b2a960b4de5af5b42e0bda238c20d41011ca7460133`** / **15,431,261 B** |
| 位流身份 | `BUILD_ID_V = 32'h0000001F`（源码面）；窗口 **71 字**（`SNAP_NW_P6E = 71`，W70 = `app_rx_mirror.drop_bytes`）/ 未实现地址 **`0x14C`**（末寄存器 `MIR_DMA_CNT`@0x148）|
| 构建 | `P7B_WNS = 0.108 / P7B_WHS = 0.011`；三类失败端点 **`0 / 0 / 0`**；`BUILD_EXIT=0` / `BAT_RC=0`；一次收口（未重跑） |
| 矩阵 | **17/17 门 EXIT=0，0 红，`gates failed: 0`，`VERDICT: FROZEN`**，`MATRIX_RC=0` |
| 全局 WNS 身份 | **`g_hw.clk_out0`（DP 域）**：`u_tcp_tx/u_retx/g_byte[1].mem_e_reg_5_bram_0/CLKBWRCLK → u_tcp_tx/ring_d_r_reg[59]/D`，lvl=11 |
| DP 域 setup WNS | **`+0.108`**（0x1E = `+0.034`；**本轮 = 全局最差**；DP 内三类失败端点 0/0/0） |
| ⭐ M1 面（后布线真判据） | M1 最紧路径 slack **`+0.674`**（lvl 2/7）；**M1 cell 在全局 top5 / DP top10 / DP top50 = 0 命中**；synth 面曾报 DP `−0.377`（325 端点）⇒ 后布线 **DP `+0.108` / 0 失败端点** |

## 步骤 1：预核

- 开工时 `git status --porcelain`：已跟踪文件**全干净**（只有 `.claude/`、一排 `_tmp_*.py`、`sim/aliasgate/_selftest/`、`sim/p4sim/P4_MATRIX_FINGERPRINT_20261011_{092750,102015,103606}_*` 等 untracked）⇒ `rtl/`·`tb/`·`sim/`·`board/` 无改动。**开工 HEAD = `00f439c`**（与派单一致）。
- `p7b_buildF_build/F/` = **17 件**（逐件 sha256 → 本目录 `F_PRE_BUILD_INVENTORY.txt`）。锚点：`wrapper_p4.bit` = **`89e89f31…0f45`**（构建 F / 0x1A）、`wrapper_p4_routed.dcp` = **`737a1418…ef6e`** —— 与 0x1E 报告所记**逐字相同** ⇒ 17 件未被动。
- ⚠️ **HEAD 在矩阵跑动期间被推进（并发面，已核）**：矩阵日志 `GIT_HEAD` BEFORE=`00f439c` / AFTER=**`939210f`**。核 `git diff --stat 00f439c..939210f` = **只有 `CLAUDE.md`(+10/−4) 与 `_proj_10g/notes/P7B_TL_LEDGER_20261010.md`(+20)** 两个**文档**文件 ⇒ **不涉 RTL/顶层/构建**；且矩阵自身的 `DIGEST_COMPILE`(212) / `DIGEST_ALL`(257) BEFORE=AFTER **逐位相同** ⇒ 冻结判据不受影响（该提交落盘时刻 = 11:03:02）。
- ⭐ **时间线核实（"本构建 = M1 的首个位流"成立）**：M1 期 A 提交 `94abaf8` @ **10:02:20**、期 B 接线收口 `f6b37eb` @ **10:41:03**；而 0x1E 位流出在 **04:09–04:41**（其报告自记几何 = 70 字 / `0x138`，wrapper 工作树 sha256 = `a32dace1…` / 278,420 B）⇒ **0x1E 位流不含任何 M1 内容**，本轮位流是 M1（期 A + 期 B 接线 + 快照第 71 字）第一次进 place & route。⇒ 下文所有 "vs 0x1E" 的资源/端点/族差值 = **M1 整体 + P&R 重排**的合并量，**无拆刀臂 ⇒ 不归因**。
- **换行约定（引用哈希别踩）**：`core.autocrlf=true` ⇒ 仓库存 LF 归一化 blob、工作树为 CRLF；本报告的 `wrapper_p4.v` sha256 **都是工作树 CRLF 口径**。开工时工作树 sha256 = `319ec48bc0876fecdadee3dba89f7f15dc371274a77affec92260d5af1de99be`（295,345 B / 4707 行）。

## 步骤 2：`board/wrapper_p4.v`（一处值 + 一处 BID 注释块）

| 项 | 改前 | 改后 |
|---|---|---|
| `.BUILD_ID_V` | `32'h0000001E`（行 `:4324`） | **`32'h0000001F`**（行 `:4324`，现读） |
| BID 注释块 | 顶部 = `//   ⭐ 本轮构建 (2026-10-11): **0x1D → 0x1E**。` | **新增 0x1F 块**（19 行）：内容 = **M1 载荷镜像窗**（UDP/TCP **`src_sel`** 双源；tap = app RX 口 → XOR 0xA5 → 异步 FIFO → `axi_regs` 新读口）+ **C2H DMA 环**（`rtl/mir_dma_ring.v`）+ **H2C 丢弃从机**（`rtl/aximm_h2c_discard.v`）；模块五件套 = `rtl/app_rx_mirror.v` / `rtl/aximm_c2h_win.v` / `rtl/mir_dma_ring.v` / `rtl/aximm_h2c_discard.v` + `_proj_pcie/rtl/axi_regs.v` 的 MIR 寄存器组；⚠️ 窗口 70 → **71**（W70 = `app_rx_mirror.drop_bytes`）、未实现地址 `0x138` → **`0x14C`**（末寄存器 `MIR_DMA_CNT`@0x148）；⛔ **回退点 = 运行期写 `MIR_CTRL[0] = cap_en = 0`**（复位默认即 0，不需重烧），或回滚 M1 提交；**历史链保留** = 0x1E snd_wnd / 0x1D persist / 0x1C 缺陷刀 / 0x1B 已分配未构建 / 0x1A 构建 F。原 0x1E 块降级进新的 `---- (以下为历史, 逐字保留) ----` 段（块内其余一字未动） |

**核验**：`git diff --stat` = **`1 file changed, 21 insertions(+), 2 deletions(-)`**，**只有一个 hunk**（`@@ -4321,8 +4321,27 @@`，`-U0` 口径 `@@ -4324,2 +4324,21 @@`）⇒ 无别的行被碰；`git status --porcelain board/ rtl/ tb/` = **只有 ` M board/wrapper_p4.v`**。**CRLF**：改后 **4,726 行 / CRLF 4,726 / 裸 LF=0 / 裸 CR=0 / 以 CRLF 结尾**（4707 + 19 = 4726）。改后工作树 sha256 = **`3b95c220ca9463495297ded2049b1391802229319dc5743961a73011d276faa9`**（**297,332 B**）。

**改前先核（与派单描述逐条对照，全部相符）**：`SNAP_NW_P6E = 71` 现读 `:3256`（注释"总字数 W0..W70 (未实现地址 = 0x14C = word 83)"）；W70 = `app_rx_mirror.drop_bytes` 现读 `:3246`/`:4051`/`:4105`；`MIR_CTRL` 位语义现读 `_proj_pcie/rtl/axi_regs.v:188` = `[0]=cap_en [1]=clr toggle [2]=src_sel [3]=dma_en`，且 `:227-238` 复位默认 `32'd0` + 注释逐字"**复位即回退态**"；`src_sel` 双源 mux 现读 `board/wrapper_p4.v:3790-3801`（`src_sel=0 → UDP` / `=1 → TCP`，pcie→dp 2FF 同步）；M1 五件套文件全部在位。

⚠️ **一处未动、但已变陈旧的注释（登记，供 TL 决定，我未改）**：`board/wrapper_p4.v:2144` 的 persist 注释头仍写 `// ⭐ 现役构建配置 (persist 自 **0x1D** 起开; 本版 **0x1E** 沿用):` —— 按派单"不许动别的行"未触碰；本版实为 **0x1F** ⇒ 该句的"本版 0x1E"已落后一版。

## 步骤 3：全量常驻矩阵（17 门）

`MSYS_NO_PATHCONV=1 cmd /c 'sim\p4gates\run_matrix_p4dfix.bat'` —— **`MATRIX_RC=0`**。⚠️ 捕获口径（与 0x1E 同形）：stdout 直播只到 `---- summary ----`；摘要正文/指纹写在 `sim/p4sim/matrix_p4dfix.log`。原始行（副本 = `matrix_log_summary.txt`；GBK 原件 + UTF-8 转写 = `matrix_stdout.txt` / `matrix_stdout_utf8.txt`）：

```
BEFORE  DIGEST_COMPILE=615e2ee5d1d748103d4e9fd310586b1cacdefd2fd2547515882b1bedd7960af6  FILES=212  DIGEST_ALL=89b0a92e214b6ea19fa6d45e84d0d5d0b6e22d9824a92e94953a5ae53a3c5d9a  HEAD=00f439c
AFTER   DIGEST_COMPILE=615e2ee5d1d748103d4e9fd310586b1cacdefd2fd2547515882b1bedd7960af6  FILES=212  DIGEST_ALL=89b0a92e214b6ea19fa6d45e84d0d5d0b6e22d9824a92e94953a5ae53a3c5d9a  HEAD=939210f
VERDICT: FROZEN -- all 257 hashed files byte-identical across the run; this log is bound to revision DIGEST_ALL(content)=13f32092f24e5e4300acb983727f4d18ef199f9783d4d9f925a1b71f0ca57e1e
gates run   : 17 / 17
gates failed: 0
MATRIX DONE 2026/10/11 周日 11:23:56.40
```

- **17 门逐门 `EXIT=0`**：chain · burst200 · trunc50 · trunc100 · halfdrop · txdrop50 · gate4096 · dupstorm · pcackoob · vlanchain · vlanburst · stallgate · unit_retx · unit_fifo · unit_vlan · unit_uart · p5_wrapper。
- **跑动期间零源码漂移**：`DIGEST_COMPILE`(212) / `DIGEST_ALL`(257) BEFORE/AFTER 逐位同（**HEAD 变了、文件内容没变** —— 见步骤 1）。
- **静默门复核**：`unit_retx` = **`ALL 7 GROUPS PASS`**（`$finish` @111,486 ns）；`unit_fifo` = **`PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700`**（C=616302 与全仓既存基线逐字相同）。
- 环境变量警告行 = **14 行 / 4 组**（trunc50×4 / trunc100×4 / halfdrop×4 / pcackoob×2；GBK 解码后逐行 = `环境变量 <TOKEN> 没有定义`，与 0x1E 同量、既存显示瑕疵）；矩阵日志 `grep -i "fail|error"` = **2 命中，均为非判定行**（:14 = 文件头说明文字 "…exits non-zero on FAIL:"；:254 = `gates failed: 0`）⇒ **0 条实质红**。
- **`p5_wrapper` 门尾部读数**（逐字）：`wrapper GMII: 3 帧 (conn0 数据 3 / 其它 0 / 坏 FCS 0)` · `wrapper 图案: 3 帧 / 4380 B, 覆盖 [12345679, 12346795)` · `P5 WRAPPER OK`。

### ⛔ 覆盖声明（"空证据"面，照实报）

6 个 manifest = `chain_src.f` · `fifo_src.f` · `p5wrapper_src.f` · `retx_src.f` · `uart_src.f` · `vlan_src.f`。逐条现核：

1. **四个 M1 新件 + `axi_regs.v` 不在任何 manifest**（`grep -icE "app_rx_mirror|aximm_c2h_win|mir_dma_ring|aximm_h2c_discard|axi_regs"` 对 6 份 manifest 全部 = **0**）⇒ **17 门里没有一门编译 M1 代码**。
2. 唯一编译 `board/wrapper_p4.v` 的门 = `p5_wrapper`，而 `p5wrapper_src.f` 头部**逐字自述**：`config : -d APP_MODE ONLY. No DP_156MHZ / PCIE_OBS / P7B_10G / UDP_TX_OVL / TCP_TX_OVL -- this is the wrapper's single-domain legacy branch, NOT the board build.` + `COVERAGE WARNING … it therefore also cannot see anything that only exists inside an ifdef DP_156MHZ / ifdef P7B_10G branch.` ⇒ **M1 三层宏块（`APP_MODE ∧ PCIE_OBS ∧ DP_156MHZ`）在该门里根本没被 elaborate**。
3. ⇒ **本轮 17/17 FROZEN 只对既有数据面/慢路径成立；对 M1 = 空证据**（同 0x1E 对 `sim/p3sim_sw` 的处置）。M1 自己的门（`sim/p6e_pcie/run_tb_p6e_pcie.bat` 108 PASS、`sim/p7b_h2cdisc/`、`p7b_biz_win/check_window.py` 等）**不在 17 门内、本轮未跑**（它们在 M1 期 B 轮跑过，见 `_proj_10g/notes/p7b_m1p2b_impl_20261011/REPORT.md`）。

## 步骤 4：构建（一次收口、无停滞）

时间线（本机时钟）：预归档 **11:30:41** → 11:32:16 `launch_runs` 起 `xdma_0_synth_1` + `pcs64_synth_1` + `synth_1` → **`xdma_0` OOC 11:35:04 正常收口**（`pcs64` 11:33:31；**构建 F run1 的 `xdma_0` 停滞未再现**）→ `synth_1` **11:41:02 finished** → opt 00:54 → place 08:51 → phys_opt 00:12 → route 05:14 → **位流 12:00:07** → `BUILD_EXIT=0`（bat 退出码 0，`BAT_RC=0`）。**一次收口，未重跑**。预归档：`ARCHIVE_SHA256_OK` + `ARCHIVE_DONE 20261011_113041 files=19`，其中 `wrapper_p4.bit` sha256 = **`e489ae4a4b868695cff1c6dfc2fbdef70de29d391cdb9a43e0a08accd342be1a`（= 0x1E 位流，逐字相同）**、`wrapper_p4_routed.dcp` = `51bd6427…5eb4`（= 0x1E 报告所记）⇒ 第二重保险成立。

```
ARCHIVE_SHA256_OK
ARCHIVE_DONE 20261011_113041 files=19 dir=D:\repo\XCKU5PMini\udp_hls_10g\board\..\_proj_10g\notes\p7b_build_archive\20261011_113041
BUILD_EXIT=0
P7B_CONVERGED_AT_ROUND = 2
P7B_IS_LOCKED_POSTGEN = 0
P7B_WNS = 0.108
P7B_WHS = 0.011
P7B_WPWS = 0.011 0.011 0.015 0.016 0.017 0.023 0.023 0.030 0.042 0.050 0.051 0.064 0.066 0.066 0.102 0.107 0.108 0.129 0.227 0.370 0.418 0.490 1.140 1.705 3.171 4.466 4.721 6.610 6.811 6.843 6.850 6.852 7.903 998.909
P7B_BIT_EXISTS = 1
P7B DONE
BITSTREAM-OK
BAT_RC=0
```

`P7B_VERILOG_DEFINE = APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1`（与 0x1E 同表）。**硬门**：12 键 + 3 标记（`DROPPED-CONSTRAINT-FAIL / IMPLICIT-NET-FAIL / DRC-KEY-FAIL`）在 `board/p7b_ku5p_stdout.txt` 命中 **全 0**（bat 控制台亦 0）。

**三类失败端点（原始行）**：

```
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.108        0.000                      0               260537        0.011        0.000                      0               260537        0.000        0.000                       0                 84660
```

`All user specified timing constraints are met.`（`wrapper_p4_timing_summary_routed.rpt:160`）。`Slack (VIOLATED)` 计数 = **0**（`wrapper_p4_timing_summary_routed.rpt` 与 `board/p7b_ku5p_timing.rpt` 双件现核都为 0）。Critical Warning 共 **3 条**（既存、与 0x1E 逐条相同）：`Constraints 18-1056`×2（`gtrefclk0` 覆盖 `gt_refclk_p`）+ `Vivado 12-1790`（IP 评估许可提示）。

## 步骤 5：定向查询（归档 dcp 副本上跑；`query/`）

**全局 WNS 身份**（`G #1..5`，**Path Group 全部 = `g_hw.clk_out0`**，`global_top5.rpt` `:21/:134/:247/:360/:488` 逐条现读）：

```
G #1 slack=0.108 lvl=11 sp=u_tcp_tx/u_retx/g_byte[1].mem_e_reg_5_bram_0/CLKBWRCLK ep=u_tcp_tx/ring_d_r_reg[59]/D
G #2 slack=0.110 lvl=11 sp=同上 ep=u_tcp_tx/ps_stage_byte_reg[3]/D
G #3 slack=0.112 lvl=11 sp=u_tcp_tx/u_retx/g_byte[1].mem_o_reg_7_bram_8/CLKBWRCLK ep=u_tcp_tx/ring_d_r_reg[29]/D
G #4 slack=0.126 lvl=16 sp=u_tcp_tx/u_fifo_a/wptr_reg[6]/C ep=u_tcb/rcv_nxt_r_reg[8][11]/CE
G #5 slack=0.126 lvl=16 sp=u_tcp_tx/u_fifo_a/wptr_reg[6]/C ep=u_tcb/rcv_nxt_r_reg[8][12]/CE
```

细节（G #1）：`Data Path Delay 5.855 ns (logic 2.930 = 50.0% / route 2.925 = 50.0%)`；`Logic Levels 11 (LUT4=1 LUT5=1 LUT6=2 RAMB36E2=7)`；skew −0.402。**与 0x1E 的 `u_tcp_tx/u_fifo_a/rptr_reg[6]_replica/C → u_tcb/rcv_wnd_r_reg[2][9]/CE` 是否同一对象 —— 按 #66 逐条：不是**（① 组相同（都是 `g_hw.clk_out0`，**不构成同族证据**）；② 源不同：`u_retx/g_byte[1].mem_e_reg_5_bram_0/CLKBWRCLK`（RAMB36E2）vs `u_fifo_a/rptr_reg[6]_replica`；③ 宿不同：`ring_d_r_reg[59]/D`（FDCE）vs `rcv_wnd_r_reg[2][9]/CE`；④ 级数不同（11 vs 16）；⑤ 结构不同 = **新最差路径含 7 个 RAMB36E2 器件延迟**）。

**DP 域**：intra-clock 行 `g_hw.clk_out0  0.108 0.000 0 143215  0.015 0.000 0 143215  2.627 0.000 0 51044` ⇒ **DP setup WNS = `+0.108`**（0x1E `+0.034`，**+0.074**；**本轮 = 全局最差**）；DP 端点 141,473→**143,215**（+1,742）；DP 内三类失败端点 0/0/0。⚠️ DP 余量 = **1.69%**（0x1E = 0.53%）—— 只报读数。

**DP 前 10**（10/10 组 = `g_hw.clk_out0`；slack 阶梯 0.108→0.160，0x1E 为 0.034→0.076，整梯上移 ≈0.074–0.084）：**三个族**——(a) **4 条** `u_tcp_tx/u_retx/g_byte[1].mem_{e,o}_reg_*_bram_*` **BRAM 时钟 → 输出**（宿 `ring_d_r_reg[{59,29,22}]/D`(0.108/0.112/0.140) 与 `ps_stage_byte_reg[3]/D`(0.110)）；(b) **5 条** `u_tcp_tx/u_fifo_a/wptr_reg[6]/C → u_tcb/rcv_{nxt,wnd}_r_reg[8][*]/CE`（0.126–0.160）；(c) **1 条** 旧族 `u_app_udp/u_txf/dout_reg[68]/C → u_udp_tx/ip_csum_r_reg[1][15]/D`（0.158）。

**⭐ DP 前 50 的源族"整体换位"（第 4 次；按 #66 只登记、不归因）**：

| 源族 | 0x1E `dp_top50` | 本轮 `dp_top50` |
|---|---|---|
| `u_tcp_tx/u_fifo_a/rptr_reg[6]_replica` | **49 / 50** | **0** |
| `u_tcp_tx/ctrl_seq_reg[2]` | 1 | 0 |
| `u_tcp_tx/u_fifo_a/wptr_reg[6]` | 0 | **39** |
| `u_tcp_tx/u_retx/g_byte[1].mem_*_bram_*`（CLKBWRCLK） | 0 | **11**（`grep -c` 全文命中 162 次，含宿端） |
| `u_app_udp/u_txf/dout_reg[68]` | 0 | 2 |
| `tick_cnt`（0x1D 的 141 命中） | — | **0** |
| `u_tcp_rx`（0x1E 曾以中间 cell 进 top50 = 100 次） | 100 | **0** |

⚠️ **大移位、无拆刀臂 ⇒ 不归因**；`wptr` vs `rptr` 是**不同寄存器**（不是同一族的改名）。

**⭐⭐ M1 族定向（本轮核心读数）**：

| 族（模式） | ncell | from_worst | to_worst |
|---|---|---|---|
| `*u_mir*`（全 = app_rx_mirror + ring + c2h + h2c） | **1,279** | **0.674** lvl=2（`u_mir/u_fifo/rbin_r_reg[1]/C → u_mir_ring/mem1_reg_bram_0/DINADIN[21]`） | **0.674**（同一条） |
| `*u_mir/*`（app_rx_mirror 内部） | 858 | 0.674（同上，宿在 ring） | **0.678** lvl=7（`u_mir/pend_keep_reg[2]/C → u_mir/u_fifo/mem_reg_0_63_21_27/RAMF/I`） |
| `*u_mir_ring*` | 44 | **1.703** lvl=1（`u_mir_ring/wr_words_reg[1]/C → mem1_reg_bram_0/WEA[2]`） | 0.674（上游 `u_mir` FIFO 读指针 → DINADIN） |
| `*u_mir_c2h*` | 352 | **0.939** lvl=5（`u_mir_c2h/cur_r_reg[7]/C → u_mir_c2h/rdata_reg[24]/CE`） | 0.939（同一对） |
| `*u_mir_h2c*` | 24 | **2.320** lvl=2（`u_mir_h2c/w_done_reg/C → u_pcie_xdma/…/wdlen_ff_reg[6]/CE`，出到 XDMA IP 内） | **0.825** lvl=0（`u_pcie_xdma/…/user_reset_reg/C → u_mir_h2c/bid_r_reg[0]/CLR` = **复位恢复族，非 setup 数据路径**） |
| `*mir_axi*`（⚠️ **wire 非 cell**） | **NOCELL**（预期） | — | — |
| `*mir_axi*` **net→pin** 口径 | **221 nets / 453 pins** | **1.493** lvl=2（`u_mir_c2h/rvalid_reg/C → u_mir_c2h/rdata_reg[24]/CE`） | **to_NOPATH**（这些网多为 XDMA 主口输出方向，无路径以之为宿） |
| M1 cell 在 **DP 组内** | 1,279 | **0.678** lvl=7（`u_mir/pend_keep_reg[2]/C → u_mir/u_fifo/…RAMF/I`） | 0.678（同一对） |

⇒ **M1 最紧路径 slack = `+0.674`**，比全局/DP 最差（`+0.108`）**宽 +0.566 ns ≈ 6.2×**；**M1 cell 在 `global_top5` / `dp_top10` / `dp_top50` 全文件 grep = 0 命中**（`u_mir|mir_` 逐文件计数：0/0/0）。

**⭐ synth 面 → 后布线的对照（派单点名）**：synth 臂曾报 DP 域 `−0.377` / **325 失败端点**（`_proj_10g/notes/p7b_m1p2b_synth/synth_m1p2b_timing_summary.rpt:208` 与 `:1885` 逐字；该臂最差路径 = `u_tcp_tx/FSM_sequential_rx_state_reg[0]/C → u_app/stg_reg[0]/CE`，lvl=22），且当时 `dp_worst` 报告面 `u_mir*` **0 命中**（`_proj_10g/notes/p7b_m1p2b_impl_20261011/REPORT.md:127`）。**后布线真判据（本轮）**：DP 域 **`+0.108`**、**0 失败端点**（全设计三类 0/0/0）、且 M1 族**离最差 6.2×** ⇒ synth 面的 −0.377 **未在后布线兑现**（⚠️ 只报读数；synth→impl 的差额同时含 P&R 优化与**该臂是 synth-only、文件集 444 vs 本轮全流程**的差别，**不归因**）。

**persist 族 / 缺陷刀族 / 0x1E 族复核（挤动复核；括号 = 0x1E）**：

| 族 | ncell（0x1E） | from_worst（0x1E） | to_worst（0x1E） |
|---|---|---|---|
| `ps_timer` | 420（—） | 0.904（1.761） | 0.513（0.591） |
| `ps_phase` | 48（—） | 2.108（2.434） | 0.516（0.532） |
| `ps_stage` | **21**（21） | 0.699（0.770） | **0.110**（0.344）⚠️ = 全局 G #2 的**同一宿**（`ps_stage_byte_reg[3]/D`） |
| `ps_rd_d1` | 1（—） | 5.475（6.068） | 0.556（1.277） |
| `ps_rd_d2` | 1（—） | 4.535（4.958） | 0.556（2.011） |
| `ctrl_probe` | **NOCELL**（NOCELL） | — | — |
| `tx_is_probe` | 2（—） | 4.087（3.261） | 0.398（1.961） |
| `ctrl_pld` | 8（—） | 1.953（1.721） | 0.396（1.960） |
| `probe_net`（`*probe_sel*`） | **NOCELL**（NOCELL） | — | — |
| `whi_r`（缺陷刀） | **514**（—） | 2.703（2.881） | 0.709（0.573） |
| `ring_hi`（缺陷刀） | **132**（132） | 1.916（1.774） | 0.530（1.084） |
| `pend_wnd`（0x1E 内容） | 123（143） | 2.865（2.379） | 0.528（0.972） |
| `ackok`（0x1E 内容） | 194（194） | 4.541（4.200） | 0.548（1.774） |
| `ack_adv` | 277（278） | 4.071（3.924） | 0.501（0.766） |
| `dup_l_reg` | 75（75） | 4.309（4.045） | 0.527（0.788） |

- 两族**全部有移位**（多数 `to_worst` 变小），但**最紧的一条（0.110）= 全局 G #2 的同宿**，仍 **> DP WNS 的 1.0×**（它是"最差族里的一个宿"，不是新缺陷）；其余全部远高于临界。
- ⚠️ **0.39–0.83 那一档 `to_worst` 几乎都是 `u_clkgen/rel_sr_reg[3]/C → <reg>/CLR` = 复位恢复（async_default）族**，**不是 DP setup 数据路径** —— 读这一列时别与 setup 混。
- ⚠️ ncell 变化（143→123、278→277 一类）按**网名归并/优化产物**登记，不作族变化证据（#90）。
- ⚠️ **无拆刀臂 ⇒ 方向性归因判不了**（只报"移位"）。

**route / DRC / 资源（与 0x1E 并列）**：logical nets **196,138**（191,386）· routable/fully routed **137,237/137,237**（134,038/134,038）· routing errors **0** · CLB LUTs **77,536 (35.74%)**（75,558 = 34.83%；**+1,978**）· CLB Reg **74,657 (17.21%)**（72,886；**+1,771**）· BRAM tile **352 (73.33%)**（348；**+4** —— 与查询里 `u_mir_ring` 的 **4×RAMB36E2**（`mem0..mem3_reg_bram_0`）逐数吻合）· URAM 0 · DSP 4 · Bonded IOB 10 · GTYE4 6 · setup 端点 **260,537**（252,078；**+8,459**）· WPWS 端点 **84,660**（82,226）· board DRC roster **逐字相同**（`DPIP-2`×4 · `DPOP-3`×2 · `DPOP-4`×4 · `DPOR-2`×18 · `REQP-1858`×41 = **Checks found: 69**，**0 Error/Critical**）。⚠️ 资源/端点增量 = **M1 整体 + P&R 重排**的合并量（见步骤 1 时间线），**无拆刀臂 ⇒ 不归因**。

## 任何红 / 异常

- **构建 0 红 / 矩阵 0 红**（见上）。
- 异常（均非红）：① env 警告 14 行/4 组（既存）；② **HEAD 在矩阵跑动中被推进**（`00f439c`→`939210f`，**仅两个文档文件**；文件内容指纹 BEFORE=AFTER ⇒ 冻结判据不受影响）；③ **全局/DP 最差源族第 4 次整体换位**（`rptr_reg[6]_replica` 49/50 → **0**；`u_retx` 的 BRAM 时钟源**首次**成为全局最差；`u_tcp_rx` 从 0x1E 的 100 次 → **0**）—— 机理未定位、不归因；④ `ctrl_probe` / `probe_net`（`*probe_sel*`）网表无名（NOCELL，既存未变）；⑤ `board/wrapper_p4.v:2144` 的 persist 注释头仍写"本版 0x1E 沿用"（本版实为 0x1F）—— 按派单未动，**登记供 TL**；⑥ `sim/p6e_pcie/run_tb_p6e_pcie_counters.bat` 的既存落后常量（TB 期望 BID `0x1D`，树现为 `0x1F`）—— **不在 17 门内、本轮未跑**，属既登记项，随 BID 提升再落后一版。
- **并发面（#47）**：矩阵 `GIT_HEAD` BEFORE=AFTER 的**文件指纹**逐位同（HEAD 名不同但内容集未变）；构建后 `git status` 除 `board/wrapper_p4.v` 外只有构建自身重写的 `board/p7b_ku5p_{stdout,timing,drc,util,clkinteract}` 与 `sim/p4sim/matrix_p4dfix.log` ⇒ **无孤零零异常红**。
- **未做**：① 未烧录 / 未连 JTAG / 未碰板卡 / 未 ssh 对端（红线）；② **M1 自己的门本轮未跑**（不在 17 门内；其读数见 M1 期 B 轮原件）；③ **M1 的拆刀 A/B 未做**（无法把资源/端点/族换位归因给 M1 的具体件）；④ 读侧未动（`00f439c` 已把默认链同步到 `0x1F` / `71` / `0x14C`；本刀未触碰任何读侧文件）；⑤ **所有 M1 功能证据仍是零板级**（本轮到"位流在盘"为止）。

## 附：本目录清单

`wrapper_p4.bit`(`e365c5ca…0133`, 15,431,261 B) · `wrapper_p4_routed.dcp`(`acda88e4…b334`, 63,613,976 B) · `query/{q_0x1F.tcl, run_q.bat, q_stdout.txt, out/{global_top5,dp_top10,dp_top50}.rpt}` · `timing_summary_raw.txt` · `matrix_stdout.txt`(GBK) · `matrix_stdout_utf8.txt` · `matrix_log_summary.txt` · `build_console.txt` · `P4_MATRIX_FINGERPRINT_20261011_105821_{before,after}.txt` · `board_rpt/`(5 件) · `F_PRE_BUILD_INVENTORY.txt`(17 条) · `SHA256SUMS.txt`(22 条 = 21 件 + `REPORT.md`，**不含自身**；REPORT.md 的行 = 落盘后补条) · **REPORT.md（本件）**
