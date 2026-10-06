# P7b `wu` 修复 —— 构建轮报告（`09d2189`）

- 日期：**2026-10-07**　性质：**构建 agent 报告**（本轮只构建 + 读报告，**未烧板、未写 QSPI、未做 git 写操作、未改任何 `rtl/` 文件**）。
- 结论一句话：**位流已产出，`WNS +0.147 / WHS +0.010 / 三类失败端点 0/0/0`，比基线（`+0.077`）**好 +0.070**；
  位流 sha256 **`1076e50e…1160`**（15,431,261 B，与基线同尺寸、不同内容）。⚠️ **这是构建读数，不是板级读数** —— 板子上一版仍是旧的 `d20c08c9…5ed5`。

---

## 0. 交付物 / 原件索引

| 件 | 路径 | sha256 |
|---|---|---|
| 位流 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`（15,431,261 B，mtime 2026-10-07 02:17:25） | `1076e50e6d80e155538122ea6918a608c1d9427dafef188c5111b7317f1e1160` |
| 时序报告 | `board/p7b_ku5p_timing.rpt`（596,724 B，02:18:28） | `448a07b3496f0c778ac016e7faefd3ee41dc5fe5dd2035df643a39a07e1b907d` |
| 资源报告 | `board/p7b_ku5p_util.rpt` | `314d54b443b0c2505a67e004fae4e4bfe6d1f5b496eba1e61c6e839219b18795` |
| DRC 报告 | `board/p7b_ku5p_drc.rpt` | `0f4c06b2a9bec08403de95d766b4b3a022c64cb602927726fdd27bc43fa92a26` |
| 主 stdout | `board/p7b_ku5p_stdout.txt`（528,690 B） | `f281686eca8db240753d3bde056adddb7e92ba91d31f92da66a5ecea4ee18c03` |
| bat 控制台 | `_proj_10g/notes/p7b_wu_build/build_console.txt` | —— |
| 两栏门输出 | `_proj_10g/notes/p7b_wu_build/gatecheck_out.txt` | —— |
| 基线快照（构建前原样拷贝） | `_proj_10g/notes/p7b_wu_build/baseline_snapshot/{p7b_ku5p_timing,p7b_ku5p_util,p7b_ku5p_drc}.rpt` | timing = `82d91784…77e2`（**与 `_proj_10g/notes/p7b_biz_build/` 归档件逐字节相同**） |

---

## 1. 逐字命令 + 起止时刻 + 耗时

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g && cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'
```

| 项 | 值 |
|---|---|
| 开始 | **2026-10-07 01:50:57 +0800** |
| 结束 | **2026-10-07 02:18:35 +0800** |
| **耗时** | **27 min 38 s**（基线 BIZ 轮为 21.4 min；本轮有 3 个并发 agent ⇒ 慢 +6 min，**未单独测量归因**） |
| bat 退出 | `BUILD_EXIT=0`、`BITSTREAM-OK`、`BAT_RETURNED=0`（`build_console.txt`） |
| 宏（stdout 自证） | `P7B_VERILOG_DEFINE = APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1`（`board/p7b_ku5p_stdout.txt:269`） |
| 文件数 / top | `P7B_NFILES = 440`（`:275`）· `P7B_TOP = wrapper_p4`（`:273`） |
| license | `P7B_IS_LOCKED_POSTGEN = 0`、`P7B_CONVERGED_AT_ROUND = 2`（同基线） |
| 未测到的宏 | `WU_LEGACY` **不在**任何构建宏里 ⇒ 落 RTL 默认值 `1'b0` = **修复后逻辑**；`board/wrapper_p4.v` 里 `WU_LEGACY` 出现 **0** 次（`rtl/app_ctrl.v:250` 是唯一定义点） |

⚠️ **构建的确实是被修的 `app_ctrl.v`**（防"构建了另一个 checkout/旧拷贝"）：
工程内导入副本 `vivado_prj/p7b_ku5p_prj.srcs/sources_1/imports/rtl/app_ctrl.v`（synth 日志实读的那一份）
sha256 = `c38b3b9640d55e501e747e5e8e25e0dba7103bdc93b2cecc5a0d198a222bd2bf` = **与 `rtl/app_ctrl.v` 现核逐字节相同**、mtime 同为 01:25:41；
且 `grep -rl "repo/ECO/udp_hls_10g" vivado_prj/p7b_ku5p_prj.runs/*/runme.log` = **空**（无真空门）。

---

## 2. 两栏门结果（主 stdout vs 4 份 runme.log）

命令（逐字）：`bash _proj_10g/notes/p7b_biz_build/gatecheck.sh /d/repo/XCKU5PMini/udp_hls_10g`
⚠️ `gatecheck.sh` 自己 `exit 0`（`:58`）⇒ **下表是我读它的输出判的，没拿退出码当判据**。
栏 B = `runs/{synth_1,impl_1,pcs64_synth_1,xdma_0_synth_1}/runme.log` 四份（四份都存在，脚本 `:13-15` 逐个纳入）。

**12 个硬键**（`gatecheck_out.txt:7-19`）：

| KEY | 主 stdout | 4×runme.log | 判定 |
|---|---:|---:|---|
| `12-4739` | 0 | 0 | 过 |
| `Synth 8-11241` | 0 | **33** | 见下归属 |
| `undeclared symbol` | 0 | **33** | 同上一批（同一批日志行） |
| `VRFC 10-3091] actual bit length 1 differs from formal bit length` | 0 | 0 | 过 |
| `VRFC 10-2989` | 0 | 0 | 过 |
| `implicitly declared` | 0 | 0 | 过（2025.2 下本就恒 0 的哑门） |
| `NSTD-1` / `UCIO-1` / `AVAL-326` / `Opt 31-155` / `Opt 31-67` / `Route 35-7` | 0 | 0 | 过 |

**33 条的归属（不是"新增"，是厂商 IP 生成源码）**：
- 逐文件：`pcs64_synth_1` **28** + `xdma_0_synth_1` **5** = 33（`gatecheck_out.txt:31` / `:60` / `:66` / `:95`）；`synth_1` = 0、`impl_1` = 0。
- 逐源目录：`vivado_prj/p7b_ku5p_prj.gen/sources_1/ip/pcs64` **28** + `…/ip/xdma_0` **5**。
- 归属判据（我方源码命中数）：`grep -h -E "Synth 8-11241|undeclared symbol" runs/*/runme.log | grep -c -E "udp_hls_10g/(rtl|board|_proj_pcie)/"` = **0** ⇒ **我们自己的 RTL 一条都没有**。
- **与基线逐项相同**：归档 `_proj_10g/notes/p7b_biz_build/gatecheck_out.txt` 的四个 header 行是
  `x28 in …/pcs64_synth_1/runme.log`、`x5 in …/xdma_0_synth_1/runme.log`，两键各一份 ⇒ **33/33 与同一 split，一字不差**。

**附加宽面**（`gatecheck_out.txt:22-29`）：

| KEY | 主 stdout | RUNLOGS | 基线对照 |
|---|---:|---:|---|
| `^ERROR` | 0 | 0 | 0 / 0 |
| `^CRITICAL WARNING` | 3 | 3 | 3 / 3（**同样三条**：`Constraints 18-1056` ×2 + `Vivado 12-1790` Evaluation License ×1；见 `board/p7b_ku5p_stdout.txt:1274,3325,4284` vs 基线 `:1260,3306,4226`） |
| `VRFC 10-` | 0 | 0 | 0 / 0 |
| `Synth 8-` | 1384 | 2469 | 1366 / 2435（**非门**，仅信息量差异） |
| `xelab` | 0 | 0 | 0 / 0 |
| `\[Synth 8-36\]` | 0 | 0 | 0 / 0 |

---

## 3. 时序对照表（与基线逐项）

原件：新版 `board/p7b_ku5p_timing.rpt:156`（表）/ `:159`（"All user specified timing constraints are met."）；
基线 `_proj_10g/notes/p7b_wu_build/baseline_snapshot/p7b_ku5p_timing.rpt:156` / `:159`（同样一行"met"）。

| 指标 | 基线（`d20c08c9`） | **本轮（`1076e50e`）** | 差值 |
|---|---:|---:|---:|
| **WNS (ns)** | **+0.077** | **+0.147** | **+0.070** |
| TNS (ns) | 0.000 | 0.000 | 0 |
| **setup 失败端点** | **0** / 242723 | **0** / 242080 | **0**（总端点 −643） |
| **WHS (ns)** | **+0.010** | **+0.010** | **0** |
| THS (ns) | 0.000 | 0.000 | 0 |
| **hold 失败端点** | **0** / 242723 | **0** / 242080 | **0** |
| **WPWS (ns)** | 0.000 | 0.000 | 0 |
| **pw 失败端点** | **0** / 79028 | **0** / 78746 | **0**（总端点 −282） |
| `Slack (VIOLATED)` 行数 | 0 | **0** | 0 |
| `P7B_WPWS` 逐组最小（bat 读数行） | 0.010（34 组） | 0.010（34 组） | 0 |

⇒ **三类失败端点 0/0/0，无违例端点族可比**（因为一条违例都没有）。

### 3.1 ⭐ 全局最差路径**换了族**（基线 → 本轮）

| | 基线最差（0.077） | 本轮最差（0.147） |
|---|---|---|
| 报告位置 | 基线 rpt `:3434-3443` | 新版 rpt `:2010-2019` |
| Path Group | `**async_default**` | `g_hw.clk_out0`（数据面 156.25 MHz，period 6.400） |
| Path Type | **Recovery** | **Setup** |
| Source | `u_pcie_xdma/inst/pcie4_ip_i/inst/user_reset_reg/C` | `u_app_udp/u_txf/dout_reg[68]/C` |
| Destination | `u_pcie_regs/snap_words_r_reg[174]/CLR` | `u_udp_tx/ip_csum_r_reg[0][5]/D` |
| Data Path Delay | 3.402（logic 0.096 = 2.8% / route 3.306 = **97.2%**） | 6.038（logic 2.685 = 44.5% / route 3.353 = 55.5%） |
| Logic Levels | **0** | **20**（CARRY8=6 LUT1=1 LUT2=2 LUT3=1 LUT4=1 LUT5=4 LUT6=5） |

**基线那条"快照阵列异步复位 Recovery"族还在，但已不是最差**：同源 `u_pcie_xdma/…/user_reset_reg/C` 在本轮的最大延迟路径现在是
**0.496 ns** → `u_snap_dp/dout_a_reg[145]/CLR`（新版 rpt `:3500-3503`）⇒ **0.077 → 0.496（+0.419）**。
⇒ **两个方向都是"变好"**，且**不是同族内换最差位**（连 Path Group/Path Type 都换了）。

⚠️ 诚实边界：本轮新最差路径 `u_app_udp/u_txf/dout_reg[68] → u_udp_tx/ip_csum_r_reg[0][5]/D`
在**基线报告里一次都没出现**（`grep` = 0 命中）；但 `report_timing_summary` 只列每组的**前若干条**，
所以**不能据此断言它是"新增路径"**，也**不能断言它当时余量更好**。能证明的只有：**它与基线的两条最差路径都不是同一条物理路径**。

### 3.2 Intra Clock Table 逐时钟对照（新版 rpt vs 基线 rpt）

| Clock | 基线 WNS | 本轮 WNS | Δ | 失败端点（本轮） |
|---|---:|---:|---:|---:|
| **g_hw.clk_out0**（DP 域） | 0.192 | **0.147** | **−0.045** ← 本轮全局最差 | 0 / 135245 |
| pcie_axi_aclk | 0.308 | 0.351 | +0.043 | 0 / 49497 |
| pipe_clk | 0.755 | 1.511 | +0.756 | 0 / 2400 |
| rxoutclk_out[0]_2 | 1.671 | 1.789 | +0.118 | 0 / 3429 |
| rxoutclk_out[0]_3 | 0.668 | 0.534 | −0.134 | 0 / 9674 |
| txoutclk_out[0]_2 | 3.405 | 3.431 | +0.026 | 0 / 817 |
| txoutclk_out[0]_3 | 0.417 | 0.424 | +0.007 | 0 / 2381 |
| txoutclkpcs_out[0]_2 | 4.735 | 4.349 | −0.386 | 0 / 34 |
| txoutclkpcs_out[0]_3 | 4.415 | 4.957 | +0.542 | 0 / 34 |
| pcie_ref_clk | 7.398 | 7.412 | +0.014 | 0 / 3702 |
| sys_clk_100 | 8.059 | 8.173 | +0.114 | 0 / 716 |
| GTYE4_CHANNEL_TXOUTCLK[0..3] | 0.501 | 0.501 | 0 | 0 / 1,1,1,5 |
| xdma_0_…_n_31 | 0.000 | 0.000 | 0 | 0 / 1 |

⚠️ 三条 Δ 为负（`g_hw.clk_out0` −0.045、`rxoutclk_out[0]_3` −0.134、`txoutclkpcs_out[0]_2` −0.386）
**全是布局/布线噪声**（多条路径 logic levels ≤ 1），**没有一条跳到违例**；`g_hw.clk_out0` 那条见 §3.1（20 级逻辑，不是噪声）。

⚠️ **余量仍然薄**：全局最差 0.147 ns = 6.400 ns 周期的 **2.3%**；hold 侧 `WHS +0.010` 与基线同薄。
**下一步若还往快照窗口加字**（⚠️ 本句原文此处写 "每 +10 字 ≈ +320 FF，走异步复位 Recovery" —— **已于 2026-10-07 订正，见下**），先看这一轮 `g_hw.clk_out0` 与 pcie 两条。

> ⚠️ **2026-10-07 订正（出处 `P7B_WU_TIMING_DELTA.md` §5.3）：三处改写** ——
> ① 那句原本说的是 **pcie 域**快照阵列（`u_pcie_regs/snap_words_r_reg[174]/CLR`，`pcie_axi_aclk`，机制 = `user_reset` **异步复位**网的 **Recovery**）那一族 —— **不是**数据面 setup 路径；
> ② 该族**本轮快照窗口没动**（仍 61 字）**也自己 +0.419**（0.077 → 0.496，宿端换成 `u_snap_dp/dout_a_reg[145]/CLR`）⇒ **幅度的大头是 P&R 重排**（零 FF 变化下同族 +0.419 ⇒ "扩窗必吃 WNS"的幅度不能全归给 FF 数）；
> ③ **真实成本 ≈ 96 FF/字**（= DP 域 `snap_cdc.hold_b` 32 + pcie 域 `dout_a` 32 + pcie 域 `snap_words_r` 阵列 32 三份），**不是 32** ⇒ "每 10 字 +320 FF"**只数了阵列那一份**；总数 ≈ **960 FF/10 字，其中 320 落在数据面域**。下一轮扩窗的可测风险排序：① `async_default` 两族（pcie **0.496** / DP **0.743**）；② 数据面域 FF 数（+32/字）与布局压力。
> ⚠️ 该原句的同款还出现在 `CLAUDE.md` / `PORT_NOTES.md`（出处清单见 `P7B_WU_TIMING_DELTA.md` §5.3 的引用行：`CLAUDE.md:64-66`、`PORT_NOTES.md:5168-5170,5263`）—— **本轮订正范围不含那两个文件**，那两处**仍是原句**。

---

## 4. 资源对照

原件 `board/p7b_ku5p_util.rpt`（本轮）vs `baseline_snapshot/p7b_ku5p_util.rpt`（基线）。

| 项 | 基线 | **本轮** | Δ |
|---|---:|---:|---:|
| CLB LUTs | 71,516 | **71,238** | **−278** |
| ├ LUT as Logic | 64,862 | 64,584 | −278 |
| └ LUT as Memory | 6,654 | 6,654 | 0 |
| CLB Registers | 70,026 | **69,744** | **−282** |
| CARRY8 | 1,424 | 1,428 | +4 |
| **Block RAM Tile** | **348**（72.50%） | **348**（72.50%） | **0** |
| ├ RAMB36E2 only | 317 | 317 | 0 |
| └ RAMB18E2 only | 62 | 62 | 0 |
| **URAM** | **0** / 64 | **0** / 64 | **0** |
| DSPs | 4 | 4 | 0 |
| Bonded IOB | 10 | 10 | 0 |
| GTYE4_CHANNEL | 6 / 16 | 6 / 16 | 0 |

⇒ **资源几乎不动**（LUT/FF 各降 ~280，符合 `app_ctrl.v` `+78/−8` 行替换掉一整套 `fq/wcalc` 增长比较链的规模）；
**BRAM/URAM 零变化**。

---

## 5. DRC

`board/p7b_ku5p_drc.rpt`：`Checks found: 69`，**全部 Warning**，逐条与基线**逐行相同**：

| Rule | Severity | Checks |
|---|---|---:|
| DPIP-2 | Warning | 4 |
| DPOP-3 | Warning | 2 |
| DPOP-4 | Warning | 4 |
| DPOR-2 | Warning | 18 |
| REQP-1858 | Warning | 41 |

⇒ **0 Error / 0 Critical**（stdout 亦有 `INFO: [Vivado 12-3199] DRC finished with 0 Errors`）。

---

## 6. 位流

| 项 | 值 |
|---|---|
| 路径 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit` |
| **sha256** | **`1076e50e6d80e155538122ea6918a608c1d9427dafef188c5111b7317f1e1160`** |
| 字节数 | **15,431,261**（与基线**同尺寸**） |
| mtime | 2026-10-07 02:17:25 +0800 |
| 基线（对照） | `d20c08c9e3483359d278893f58b69e921c02b33427430ebe1664571ec0655ed5`，同 15,431,261 B |

⚠️ **同尺寸 ≠ 同内容**（本工程已有先例）：本轮位流与基线**尺寸完全相同、sha256 不同** ⇒ 日后核身份**只能看 sha256，不能看字节数**。
⚠️ **板子上跑的仍是旧的 `d20c08c9…`**（本轮**没有烧板**，也不许烧）。

---

## 7. 修订漂移检查（前后各一次）

| 文件 | 构建**前** sha256 | 构建**后** sha256 | 一致？ | mtime |
|---|---|---|---|---|
| `rtl/app_ctrl.v` | `c38b3b9640d55e501e747e5e8e25e0dba7103bdc93b2cecc5a0d198a222bd2bf`（84,669 B） | 同左 | ✅ | 2026-10-07 01:25:41（**构建开始前**） |
| `board/wrapper_p4.v` | `ab67100fc1126b284676382d041c42254f7daa5504ddb4fca43451fda7d6a994`（228,016 B） | 同左 | ✅ | 2026-09-30 19:30:21（**构建开始前**） |

⇒ **构建期间没有并发 agent 改动这两个文件，本轮不作废**。
（旁证：`board/wrapper_p4.v` mtime 仍停在 09-30，与 `09d2189` 提交信息"`wrapper_p4.v` 一字未动"吻合；
本轮构建轮内**唯一**看到的外部改动是 `udp_hls_10g/CLAUDE.md`（另一 agent 的文档订正），**不进综合**。）

---

## 8. 我**没能证明**的部分（别把本报告读成比它更大）

1. **板级行为一个字都没证** —— 本轮**未烧板**（纪律：构建期间不得从被构建的工程烧位流）。`wu` 修复的
   **功能效果**（`J6`/`J15` 是否达标）必须由测量轮在**新位流烧进板子之后**另行给读数，且**必须带 pace 值**。
2. **新最差路径的来历不可判** —— 见 §3.1 尾注：它不在基线报告里，但报告只列前若干条 ⇒ 既不能说"新增"，也不能说"当时更好"。
3. **门只覆盖 12+6 个键** —— 宽面扫描是粗网；**未列举的告警形态仍可能逃逸**（尤其 `Synth 8-` 这一族 1384/2469 条我没有逐条读）。
4. **没有独立复算宏语义** —— 六个宏我读的是 stdout 自证行（`p7b_ku5p_stdout.txt:269`），**没有**逐条回到 RTL 证明它们都真的生效。
5. **耗时 +6 min 的归因未测** —— 归到"3 个并发 agent"，但**没有做过对照**（单跑一轮才有资格说）。
6. **构建可重复性未验** —— 本轮只跑了一次；**没有**证明同源码第二次构建给出同位流 sha256。
7. **`P7B_WPWS` 的 34 个值我只看了最小值**（0.010，同基线），**没有逐组对照**。
8. **DRC 只跑了默认 ruledeck** —— 换更严的 rule deck 会不会出新问题，不在本轮范围。
