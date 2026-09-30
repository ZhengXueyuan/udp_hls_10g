# P7B_BUILD_FINAL.md —— P7b 合并构建（TX 时序修复 + lane4 修复）时序终检

- 日期：2026-09-30
- 触发：两轮 RTL 修复（`P7B_MAC_TIMING_FIX.md` 的 `mac_tx_10g.v` padrem 化简 + `P7B_LANEFIX.md` 的
  `mac_rx_10g.v` lane4 重对齐）**都已落地**，按任务书跑一次**合并构建**并验时序。
- 性质：**测量报告**。本 agent **未改任何 RTL / XDC / 构建脚本 / strategy**，**未烧板**（无
  `program_hw_devices`）、**未写 QSPI**、**未动 license**、**未碰 `D:\repo\perfv`**、**未做任何 git 写操作**。
- 构建命令 = `cmd //c 'board\run_build_p7b_ku5p.bat'`（脚本原样，strategy = `Performance_ExtraTimingOpt`）。
- 耗时：`2026-09-30 12:01:12` → `12:22:41`（**~21.5 min**）。
- 上一轮记录在 `_proj_10g/notes/P7B_TIMING_RERUN.md`（**本文件不覆盖它**）。

---

## 0. 一页结论

> ### ✅ **收敛。**
> **`P7B_WNS = +0.128` / `P7B_WHS = +0.010`**；`report_timing_summary` 总表
> **setup / hold / pulse-width 三类失败端点全 0**（`All user specified timing constraints are met.`
> `board/p7b_ku5p_timing.rpt:159`）；**11 个 intra clock group 逐组三类失败端点全 0**。
> 上一轮的主目标组 `txoutclk_out[0]_1`（= 本轮 `txoutclk_out[0]_3`，指纹 2376→2381 端点）
> **`−0.173 / 39 失败` → `+0.765 / 0 失败`，改善 +0.938 ns**（MAC-only 预测 +0.478 的 2 倍，
> 预测方向正确、幅度**超预期**）。
> 新全局 WNS 瓶颈落回 **`g_hw.clk_out0`（156.25 MHz 数据面域）`+0.128`** —— 与修复前 `+0.218` 同族、量级相当。
> 位流已产出：`vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`，**15,431,261 B**，
> sha256 `0e1c8088d3907bd52915fa1a1a291ceeb627ed1b5252e421f825c9abdd7fb557`。
> ⚠️ 位流虽出，**本轮未烧板**（按纪律）。

---

## 1. 证据新于源码的凭据（构建前 / 构建后两次独立取样，逐字相同）

取样命令：`stat -c '%y'` + `sha256sum`，取样点 = 构建启动前与构建结束后各一次。

| 文件 | mtime | sha256 前 16 | 构建后复核 |
|---|---|---|---|
| **`_proj_10g/p7b_mac/rtl/mac_tx_10g.v`**（TX 修复件） | 2026-09-30 **10:44:16** | `034282a37764b9ff` | ✅ 逐字未变 |
| **`_proj_10g/p7b_mac/rtl/mac_rx_10g.v`**（lane4 修复件） | 2026-09-30 **11:25:55** | `23fb46069a3c35cc` | ✅ 逐字未变 |
| `_proj_10g/p7b_mac/rtl/crc32_64.v` | 2026-09-29 21:20:48 | `9db328c7fe1a3140` | ✅ |
| `board/wrapper_p4.v` | 2026-09-30 02:49:15 | `4b120b24f04db132` | ✅ |
| `rtl/rx_classify.v` | 2026-09-29 23:48:08 | `f64e2169d9bfe26e` | ✅ |
| `board/ku5p_p7b_gt.xdc` | 2026-09-30 00:05:18 | `1ef474ea20a942fb` | ✅ |
| `board/ku5p_p7b_cdc.xdc` | 2026-09-30 00:05:24 | `db0c69c5db618162` | ✅ |
| `board/ku5p_p6e_pcie.xdc` | 2026-09-29 00:29:57 | `ef6836b802dbaf7f` | ✅ |
| `board/ku5p_p6b_sysclk.xdc` | 2026-09-29 10:01:35 | `95d07576056a03b7` | ✅ |
| `board/build_p7b_ku5p.tcl` | 2026-09-30 00:05:44 | `d23865d5f4d562b8` | ✅ |
| `board/run_build_p7b_ku5p.bat` | 2026-09-30 00:05:53 | `78933137dcd200fb` | ✅ |

⇒ **全部源码早于构建启动（12:01:12），且构建后逐字未变** ⇒ 本轮读数**有效**，网表对应上述源码。

### 1.1 「网表是否混入半改副本」的独立排除【实测】

任务书点名的风险（同名的 11 份 `mac_rx_10g.v` / `mac_tx_10g.v` 副本），做了**两道**核查：

1. **工具实际读了哪一份**：`vivado_prj/p7b_ku5p_prj.runs/synth_1/runme.log` 里 MAC 源路径只有
   `.../p7b_ku5p_prj.srcs/sources_1/imports/rtl/mac_{rx,tx}_10g.v` 两条，**无第三份**；
   构建脚本只 `import_files ${mac_dir}/…`（`board/build_p7b_ku5p.tcl:99-100`，`mac_dir = _proj_10g/p7b_mac/rtl`）。
2. **导入副本与 canonical 源逐字节比对**（sha256，构建后取样）：
   `mac_rx_10g.v` `23fb46069a3c35cccbe1…` == `_proj_10g/p7b_mac/rtl/` 原件；
   `mac_tx_10g.v` `034282a37764b9ffe8b9…` == 原件；`wrapper_p4.v` `4b120b24f04db1327c41…` == `board/` 原件。
   导入副本的 **mtime 也与 canonical 完全相同**（`import_files` 保时间戳）

⇒ **网表只含修复后源码，无半改/陈旧副本。**

---

## 2. 判据逐条读数【实测】

### 2.1 位流与 banner

| # | 判据 | 读数 | 判定 |
|---|---|---|---|
| 1 | `BITSTREAM-OK` + `P7B_BIT_EXISTS = 1` | bat 控制台尾行 `BITSTREAM-OK`；`board/p7b_ku5p_stdout.txt` = `1` | ✅ |
| 2 | `BUILD_EXIT` | `0` | ✅ |
| 3 | `DROPPED-CONSTRAINT-FAIL`（键 `12-4739`） | **0** | ✅ |
| 4 | `IMPLICIT-NET-FAIL` | **0** | ✅ |
| 5 | `DRC-KEY-FAIL` | **0** | ✅ |
| 6 | 位流指纹 | 15,431,261 B；sha256 `0e1c8088d3907bd52915fa1a1a291ceeb627ed1b5252e421f825c9abdd7fb557` | ✅ |

### 2.2 硬门逐串命中数 —— **主 stdout 与 OOC run 日志分两栏**（不得合并成一个数）

**栏 A：主 `board/p7b_ku5p_stdout.txt`**（bat 三条硬门 + 五个推荐键全部键在同一处）

| 键 | 命中 |
|---|---|
| `12-4739` / `NSTD-1` / `UCIO-1` / `AVAL-326` / `Opt 31-155` / `Opt 31-67` / `Route 35-7` | **0 / 0 / 0 / 0 / 0 / 0 / 0** |
| `Synth 8-11241` | **0** |
| `undeclared symbol` | **0** |
| `VRFC 10-3091] actual bit length 1 differs from formal bit length` | **0** |
| `VRFC 10-2989` | **0** |
| `implicitly declared` | **0** |
| 字面 `DROPPED-CONSTRAINT-FAIL` / `IMPLICIT-NET-FAIL` / `DRC-KEY-FAIL` | **0 / 0 / 0** |

**栏 B：OOC / 子 run 日志**（⚠️ 独立一栏）

| run | `Synth 8-11241` | `undeclared symbol` | `VRFC 10-3091…` | `VRFC 10-2989` | `implicitly declared` |
|---|---|---|---|---|---|
| `pcs64_synth_1/runme.log` | **28** ⚠️已知例外 | **28**（同批，见下注） | 0 | 0 | 0 |
| `xdma_0_synth_1/runme.log` | **5** ⚠️同类 | **5** | 0 | 0 | 0 |
| `synth_1/runme.log` | 0 | 0 | 0 | 0 | 0 |
| `impl_1/runme.log` | 0 | 0 | 0 | 0 | 0 |

> **注（不许误读）**：`undeclared symbol` 的 28/5 **与 `Synth 8-11241` 的 28/5 是同一批消息** ——
> `Synth 8-11241` 的**消息正文本身就含 "undeclared symbol"** 字样：
> `INFO: [Synth 8-11241] undeclared symbol 'gtwiz_reset_qpll0reset_out', assumed default net type 'wire'
> [ …/pcs64_wrapper.v:288]`。**不是第二类独立问题**，两者**不得相加**。

- **主 stdout 侧 0 命中** ⇒ P7b 自写 RTL **没有**隐式网，硬门真通过（非 banner 假通过）。
- **OOC 侧 28 条** = 任务书预先点名的**已知例外**，与上轮同源：
  **38 处出自厂商 `pcs64_wrapper.v`**、8 处 `pcs64_top.v`（1 位 ↔ 1 位，无实质影响）；
  xdma 侧 5 条出自厂商 `axidma_fifo.vh` / `xdma_0_core_top.sv`。**均为厂商 IP 生成件，非本轮改动面。**

### 2.3 DRC

`board/p7b_ku5p_drc.rpt`：`Critical` / `Error` 级 **0 条**；仅 **`REQP-1858` Warning ×41**
（`RAMB36E2_writefirst_collision_advisory`，厂商 BRAM 写先冲突提示，非本轮引入）。
bat 的 `DRC-KEY-FAIL` 键（NSTD/UCIO/AVAL/Opt 31-155/Opt 31-67/Route 35-7）**0 命中**。

---

## 3. 设计时序总表（`board/p7b_ku5p_timing.rpt`）

```
| Design Timing Summary                                                        (:150)
    WNS      TNS   TNS-Fail   TNS-Eps   |  WHS      THS   THS-Fail   THS-Eps   |  WPWS    TPWS  TPWS-Fail  TPWS-Eps
   0.128    0.000          0    236509  |  0.010    0.000          0    236509  |  0.000   0.000          0     77137
All user specified timing constraints are met.                                  (:159)
```

**三类失败端点（setup / hold / pulse-width）= 0 / 0 / 0**，WNS/WHS 均为正 ⇒ **判据成立**。

---

## 4. 逐 clock group（Intra Clock Table，`board/p7b_ku5p_timing.rpt:200` 起）

⚠️ **组名后缀本轮与上轮不同（见 §4.1），下表用「端点指纹」标明与上轮的对应关系。**

| clock group（本轮名） | 上轮同组名 | WNS | setup fEP | EP | WHS | hold fEP | WPWS | PW fEP |
|---|---|---|---|---|---|---|---|---|
| `rxoutclk_out[0]_2` | `rxoutclk_out[0]` | **+2.242** | 0 | 3429 | +0.011 | 0 | +0.514 | 0 |
| ⭐ `rxoutclk_out[0]_3` | `rxoutclk_out[0]_1` | **+0.209** | 0 | 9674 | +0.010 | 0 | +0.514 | 0 |
| `txoutclk_out[0]_2` | `txoutclk_out[0]` | **+3.213** | 0 | 817 | +0.015 | 0 | +0.616 | 0 |
| ⭐⭐ `txoutclk_out[0]_3` | `txoutclk_out[0]_1`（**上轮 39 失败处**） | **+0.765** | **0** | 2381 | +0.013 | 0 | +0.618 | 0 |
| `txoutclkpcs_out[0]_2` | `txoutclkpcs_out[0]` | +4.141 | 0 | 34 | +0.147 | 0 | +2.828 | 0 |
| `txoutclkpcs_out[0]_3` | `txoutclkpcs_out[0]_1` | +4.633 | 0 | 34 | +0.102 | 0 | +2.828 | 0 |
| `pcie_ref_clk` | 同名 | +7.294 | 0 | 3702 | +0.010 | 0 | +3.200 | 0 |
| `pcie_axi_aclk` | 同名 | +0.163 | 0 | 48637 | +0.010 | 0 | +0.213 | 0 |
| `pipe_clk` | 同名 | +0.917 | 0 | 2400 | +0.013 | 0 | +0.000 | 0 |
| `sys_clk_100` | 同名 | +7.766 | 0 | 716 | +0.042 | 0 | +2.000 | 0 |
| **`g_hw.clk_out0`（全局 WNS 所在）** | 同名 | **+0.128** | 0 | 131435 | +0.011 | 0 | +2.627 | 0 |
| `GTYE4_CHANNEL_TXOUTCLK[0..3]` | 同名 | （无 setup 路径） | 0 | 1/1/1/5 | （无） | 0 | +0.501 | 0 |

**Inter Clock Table（`:230`）**：`txoutclk_out[0]_3 → rxoutclk_out[0]_3` +4.770 / 0 失败（64 端点）；
`pipe_clk ↔ pcie_axi_aclk` +2.285 / +2.637，均 0 失败。

**Other Path Groups（`:242`）**：`**async_default**` 三行（`g_hw.clk_out0` +1.287 / 26500；
`pcie_axi_aclk` +0.162 / 4284；`pcie_ref_clk` +8.708 / 131），**全部 0 失败**。

> ⭐ **任务书点名必查的两组，结论**：
> - **`txoutclk_out*`（本次主目标）**：239-条失败的那一组 → **0 失败 / +0.765**。✅ 目标达成。
> - **`rxoutclk_out*`（lane4 修复给 lane4 帧 +1 拍，基线仅 +0.206「薄」）**：
>   该组端点 **9599 → 9674（+75，lane4 修复的代价如实反映）**，但 WNS **+0.206 → +0.209（+0.003）**
>   ⇒ **lane4 修复没有吃掉 RX 域裕量**，仍稳在 +0.2 ns 档。✅ 无新增风险。

### 4.1 ⚠️ 组名后缀漂移（**必须按指纹读，不能按名字读**）—— 已排除为设计变化

本轮组名（`_2`/`_3`）与**上轮**（裸名 / `_1`）不同。核实过程：

- **同组的端点总数逐一吻合**（本轮 ↔ 上轮）：`rxoutclk` `_2` 3429 ↔ 裸名 **3429（完全相等）**；
  `_3` 9674 ↔ `_1` 9599（**+75 = lane4 修复**）；`txoutclk` `_2` 817 ↔ 裸名 **817（相等）**；
  `_3` 2381 ↔ `_1` 2376（**+5 = TX 修复**）；`txoutclkpcs` 34 ↔ 34；`pcie_ref_clk` 3702 ↔ 3702；
  `sys_clk_100` 716 ↔ 716；`pipe_clk` 2400 ↔ 2400。**11 组一一对上，无歧义。**
- **不是设计变化**：三代构建的 `BUFGCE` 用量为 **6（01:47）/ 4（09:56）/ 5（本轮）**，
  而 BRAM(348) / CARRY8(1413) / GTYE4_CHANNEL(6) **三代逐数相同** ⇒ 漂移来自
  `opt_design` 的**时钟 buffer 插入**（工具侧非确定性），它同时改变自动生成的时钟名与端点在组间的划分。
- ⭐ **"修复前 01:47 归档"用的正是与本轮相同的 `_2`/`_3` 命名** ⇒ §5 的三方对比可直接按名对齐。

---

## 5. 三方对比（**同一套 `_2`/`_3` 命名 + 端点指纹双重对齐**）

| 组（指纹） | 修复前 01:47（`before/`） | 上轮 09:56（`prev_lanefix/`） | **本轮 12:22** |
|---|---|---|---|
| `rxoutclk` 3429-ep 组 | +1.543 / 0 | +1.866 / 0 | **+2.242 / 0** |
| ⭐ `rxoutclk` ~9600-ep 组 | +0.495 / 0 | +0.206 / 0 | **+0.209 / 0** |
| `txoutclk` 817-ep 组 | +3.289 / 0 | +3.420 / 0 | **+3.213 / 0** |
| ⭐⭐ `txoutclk` ~2376-ep 组 | +0.625 / 0 | **−0.173 / 39** | **+0.765 / 0** |
| `txoutclkpcs` ×2 | +4.501 / +4.825 / 0 | +3.905 / +4.747 / 0 | **+4.141 / +4.633 / 0** |
| `g_hw.clk_out0`（数据面 156.25 MHz） | +0.218 / 0 | +0.170 / 0 | **+0.128 / 0** |
| `pcie_axi_aclk` | +0.270 / 0 | +0.327 / 0 | **+0.163 / 0** |
| `pipe_clk` | +1.001 / 0 | +1.115 / 0 | **+0.917 / 0** |
| `sys_clk_100` | +8.137 / 0 | +8.155 / 0 | **+7.766 / 0** |
| `pcie_ref_clk` | +6.942 / 0 | +7.426 / 0 | **+7.294 / 0** |
| **全局 `P7B_WNS` / `P7B_WHS`** | **+0.203 / +0.010** | **−0.173 / +0.010** | **+0.128 / +0.010** |
| **三类失败端点合计** | **0** | **39**（全 setup，全在 txoutclk 组） | **0** |

**与 P6b 基线（上一块已板级验收的位流）对比**：P6b = `WNS +0.168 / WHS +0.010 / WPWS 0.000`，0 失败端点
（`P6B_ACCEPT.md:48`）。本轮 **+0.128 / +0.010 / 0 失败** ⇒ 加入 10G 前端（官方 PCS + 自写 XGMII MAC）
并用掉 348 个 BRAM 后，**WNS 比 P6b 低 0.040 ns，仍为正、仍 0 失败** —— 属于同一档，未劣化到风险区。

**资源（本轮）**：CLB LUTs 70095 (32.31%) / CLB Registers 68471 (15.78%) / CARRY8 1413 (5.21%) /
Block RAM 348 (72.50%) / DSP 4 / Bonded IOB 10 / BUFGCE 5 / BUFG_GT 13 / GTYE4_CHANNEL 6 (37.50%)。

**修复幅度归因**：TX 主目标组 **+0.938 ns**（−0.173 → +0.765），**大于** MAC-only 探针预测的 +0.478 ns；
方向与预测一致、幅度更优。同时 `pcie_axi_aclk`（−0.164）、`sys_clk_100`（−0.389）、`g_hw.clk_out0`（−0.042）
等无关域有 0.04–0.39 ns 的小幅摆动 —— 与 §4.1 的 `BUFGCE` 6/4/5、LUT 69886/69613/70095 同源，
**属工具侧布局/优化漂移**，不需要逐条解释，但它们说明**单组读数的 ±0.1 ns 级差不应过读**。

---

## 6. 归档（本轮落笔，均为新目录，未删任何原件）

| 内容 | 位置 | 5 份 sha256 前 16 |
|---|---|---|
| **上一轮（lane4 修复前，−0.173/39）** 五份读数 | `_proj_10g/notes/p7b_timing_rerun/prev_lanefix/` | stdout `3f0ce7d3dd725733` · timing `24739df85e23ab19` · util `bf2525db201e036e` · drc `3840b6a361726254` · clkinteract `691cedb530bef06d` |
| 修复前基线（+0.203/0，01:47） | `_proj_10g/notes/p7b_timing_rerun/before/`（前一轮 agent 归档，本轮只读） | — |
| 本轮 bat 控制台原文 | `_proj_10g/notes/p7b_timing_rerun/build_console.txt` | — |
| 本轮五份读数（现行） | `board/p7b_ku5p_{stdout,timing,util,drc,clkinteract}.*`（mtime 12:23:33–12:23:39） | — |

---

## 7. 明确结论

> **✅ 收敛。** 两类 RTL 修复合入后，`P7B_WNS = +0.128` / `P7B_WHS = +0.010`，
> **11 个 intra clock group + 3 条 inter-clock + 3 条 async_default 的三类失败端点全部为 0**，
> 主 stdout 硬门 0 命中，位流 sha256 `0e1c8088…` 已产出。
> 上轮 39 条 setup 违例**全部消失**，RX 域裕量未被 lane4 修复侵蚀。
> **可进入下一步（板级闸 2/3/4）的时序前提已满足**；**本轮未烧板**。

### 未结项 / 残余未知（如实列出）

1. **组名后缀逐轮漂移**（裸名/`_1` ↔ `_2`/`_3`），根因已定位到工具侧 `opt_design` 的 clock-buffer 插入
   （`BUFGCE` 6/4/5），**未追到 Vivado 层面的确切机制**。对判据无影响，但后人读旧报告时
   **必须按端点指纹（3429 / 817 / 34 / ~2376 / ~9600）而不是按名字**对齐 clock group。
2. **`g_hw.clk_out0` 端点 131794 → 131435（−359）与 CLB 寄存器 68689 → 68471（−218）** 的
   具体来源**未逐条追查**（两次 RTL 改动都**不在**该域；已核实构建输入集里 09:56→12:01 之间
   **只有**那两个 MAC 文件变过）。与结论 1 归为同一类工具侧漂移。**不影响收敛判定。**
3. 本轮**未做** `report_clock_utilization`，故**未能点名**第 5 个 `BUFGCE` 具体驱动哪条时钟网
   （若后续要收口结论 1/2，这是最省事的下一个探针）。
4. 位流**未烧板**：板级闸 2（真网卡 802.3 裁决）/ 闸 3 / 闸 4 仍待做，且本轮位流是
   **新 MAC 接入 wrapper 后的合并位流**（`board/build_p7b_ku5p.tcl` 各档 `P7B_10G` 分支）。
