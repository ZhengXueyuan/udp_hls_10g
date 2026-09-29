# clkgen_p6b/ — P6b 时钟发生器的「引脚 / IOSTANDARD / MMCM 合法性」实证

本目录回答四个问题（每条结论都附**原始证据出处**，没有一条来自记忆）：

1. T25/U25 到底是不是 clock-capable 脚？在哪个 bank？能不能进 MMCM？
2. Y1 到底是多少 MHz？
3. `clk_p/clk_n` 该写什么 `IOSTANDARD`？（**结论与主线现有 XDC 不一致，见 §3**）
4. MMCM 参数 `M=12.500 / D=1 / O=8.000 ⇒ VCO 1250 MHz` 合法吗？

复跑：`run_pin_probe.bat`（器件属性）/ `run_mmcm_probe.bat`（CMT site）/
`run_probe.bat`（8 个引脚+IOSTANDARD+MMCM 变体，每个都真跑 synth→opt→place[→route]）/
`run_probe_alts.bat`（次选参数组）/ `run_clkwiz_oracle.bat`（时钟向导独立求解）。
全部**只读**，不烧板。

---

## 1. T25/U25 = clock-capable，bank 65 (HP)，所在时钟区有 MMCM

`pin_probe.log`（`get_package_pins` / `get_sites` 原始读数）：

```
PIN_FUNC = IO_L14P_T2L_N2_GC_A04_D20_65      BANK = 65
  IS_GLOBAL_CLK = 1     IS_DIFFERENTIAL = 1     IS_MASTER = 1
  DIFF_PAIR_PIN = U25
  site = IOB_X0Y80  SITE_TYPE = HPIOB_M   CLOCK_REGION = X0Y1
  site 属性: IS_GLOBAL_CLOCK_PAD = 1

U25: IO_L14N_T2L_N3_GC_A05_D21_65  IS_GLOBAL_CLK=1  DIFF_PAIR_PIN=T25
     site = IOB_X0Y81  SITE_TYPE = HPIOB_S  CLOCK_REGION = X0Y1
```

`mmcm_probe.log`：

```
MMCM site MMCM_X0Y1  CLOCK_REGION=X0Y1      <-- 与 T25/U25 同一个 CLOCK_REGION
BUFGCTRL_X0Y8..X0Y15 也都在 X0Y1
```

`bank_probe.log`（早先）：bank 65 `BANK_TYPE = BT_HIGH_PERFORMANCE`（HP，不是 HDIO）。

**实测判决（负对照，证明这条规则被工具强制）**：`probe_notgc` 变体把 `clk_p/clk_n`
从 T25/U25 挪到 bank 65 里**非** GC 的 `N24/P24`（`IO_L15P/N_T2L_N4/N5_...`），
`place_design` 直接报错：

```
PLCK-58#1 Error  Clock Placer Checks
Sub-optimal placement for a global clock-capable IO pin and BUFG pair.
```
⇒ **clock-capable 不是可选项，是硬约束**；T25/U25 满足它。

## 2. Y1 = 100.000 MHz（三处独立证据）

1. **原理图出图**（`图纸/核心板/XCKU5PMini.pdf` 第 5 页，PyMuPDF 出图 `pg5_osc_wide.png`）：
   位号 **Y1**，丝印型号 **`SG7050VAN-100.000000M-KEGA3`**，`1 OE / 2 NC / 3 GND /
   4 OUT+ / 5 OUT- / 6 VDD`，VDD → **VDD3.3**；`OUT±` → `SYS_CLK_P/SYS_CLK_N`。
2. **厂商 MIG 配置**（`Demo/.../bd/pcie_ddr_bd/ip/pcie_ddr_bd_ddr4_0_0/...xci`）：
   `C0_SYS_CLK.FREQ_HZ = 100000000`，`C0.DDR4_CLKIN_PERIOD = 9996` (ps)。
3. **厂商 OOC XDC**：`create_clock -name sys_ddr_clk_clk_p -period 10 [get_ports sys_ddr_clk_clk_p]`
   且 BD 把 `sys_ddr_clk` 接到 `ddr4_0/C0_SYS_CLK`。
   （`Demo/.../src/PCIe.xdc` 第 43–44 行把 `sys_ddr_clk_clk_p/n` 钉在 **T25/U25**。）

> 注意区分：**位号 Y2**（走 `MGT225_CLK0_P/N` = V7/V6，GT 参考钟）实物已换 156.25 MHz；
> 本目录说的是 **Y1**，与 Y2 无关。第 5 页上还有一颗 **Y3**（单端 CMOS、VDD3.3、
> 输出经 C121 交流耦合 + 1k/1k 偏置到 **VDD1.8**，网络名 `GCLK2`）——也不是 Y1。

## 3. IOSTANDARD：**`DIFF_SSTL12`**，不是厂商的 `DIFF_POD12_DCI`

### 板上实际电路（`pg5_osc_zoom.png` 出图实测）

```
Y1.OUT- pin5 --+-- C118 0.1uF --+-- R52 1k --> VDD1.2        --> SYS_CLK_N
               |                +-- R54 1k --> GND
Y1.OUT+ pin4 --+-- C119 0.1uF --+-- R53 1k --> VDD1.2        --> SYS_CLK_P
                                +-- R55 1k --> GND
        R58 100Ω 跨接 SYS_CLK_P / SYS_CLK_N （差分端接）
```

⇒ FPGA 侧：**交流耦合**、共模 = 1.2/2 = **0.600 V = VCCO/2**、差分摆幅 ≈ LVDS 的
~350 mV、板载 100 Ω 差分端接（**不需要**片内 DCI 端接）。
bank 65 的 VCCO = **1.2 V**：同 bank 的 DDR4 用 `POD12_DCI`，原理图 `VCCO_65 → VDD1.2`。

### 四条候选标准的电气比对（`资料/PDF/ds922-kintex-ultrascale-plus.pdf` 出图实测）

| Vivado 标准 | ds922 出处 | VICM 允许范围 | 本板 0.600 V | 判决 |
|---|---|---|---|---|
| **`DIFF_SSTL12`** | **Table 14**（HP banks 互补差分） | **VCCO/2 ± 0.150 = 0.450–0.750 V**，VID(min)=0.100 V | 正居中 (typ) | ✅ **推荐** |
| `DIFF_POD12` / `DIFF_POD12_DCI` | **Table 15** | **0.76 / 0.84 / 0.92 V** | **低于下限 0.16 V** | ❌ 数据手册不合法 |
| `LVDS` | **Table 19** | DC 耦合 0.300–1.425 V；**AC 耦合 0.600–1.100 V** | 压在**下界**，零裕量 | ⚠️ 可用但无裕量 |

`DIFF_POD12_DCI` 还额外要付出代价：DRC 报 2 条

```
DCIRST-1 Warning: IO port clk_p/clk_n is using DCI IO standard DIFF_POD12_DCI
                  but no DCIRESET primitive is used in the design.  (AR#000038677)
```
（换成 `DIFF_SSTL12`/`DIFF_POD12`/`LVDS` 后 `report_drc` 是 **0 条**。）

### ⚠️ 工具不会替你判这一条 —— 这是本节最重要的结论

`probe_*.log` + `probe_*_drc.rpt` 实测：**四个标准 Vivado 全部接受，0 Error**：

| 变体 | IOSTANDARD | 结果 |
|---|---|---|
| `probe_sstl12_full` | DIFF_SSTL12 | synth→route 全过，**DRC 0 违规** |
| `probe_pod12dci` | DIFF_POD12_DCI | synth→route 全过，2 条 DCIRST-1 **Warning** |
| `probe_pod12` | DIFF_POD12 | place 过，0 Error |
| `probe_lvds` | LVDS | place 过，0 Error |
| `probe_lvcmos33` | LVCMOS33 | **place 失败**（见下） |

工具唯一拦得住的是"bank 类型不匹配"这一类：

```
BIVB-1  Error: The LVCMOS33 I/O standard is not supported for banks of type High Performance.
PLIOSTD-3 Error: I/O port clk_p is differential, but has single-ended IOStandard value LVCMOS33
PLHDIO-5 Error: ... need to be placed in HIGH_DENSITY IO banks ...
```
⇒ **Vivado 不知道板上的 VCCO 是多少**。`LVDS`（要求 VCCO=1.8V）和
`DIFF_POD12`（VICM 下限 0.76V）都能一路过 DRC。
**定案只能靠"原理图 + ds922 的表"**，不能靠"DRC 过了"。

### 与主线现有 XDC 的冲突（需要 TL 裁决）

`board/ku5p_p6b_sysclk.xdc`（第 30 行）写的是 `DIFF_POD12_DCI`，且注释断言
"**必须用** DIFF_POD12_DCI（HP bank 的 LVDS 要求 VCCO=1.8V，用不了）"。按上面两条证据：

1. `DIFF_POD12` 的 VICM 下限 0.76 V > 本板 0.600 V ⇒ 数据手册范围内**不成立**；
2. "LVDS 用不了"**不准确** —— ds922 Table 19 Note 1 明确允许 HP bank 的
   **输入-only** LVDS 在不使能内部端接时跑非 1.8V 的 VCCO；且 AC 耦合 VICM 允许
   0.600–1.100 V，本板 0.600 V 恰好压在下界。

**诚实补充（反方证据）**：厂商 `Demo` 位流用的就是 `DIFF_POD12_DCI`，而该位流的
DDR4 通路（⇒ MIG 的 `sys_clk`）在本板是**跑通过的** ⇒ 这个组合**实测能用**，
只是没有任何手册裕量背书。因此：

* 若追求**裕量**：改 `DIFF_SSTL12`（0.600 V = typ，上下各留 0.15 V；DRC 0 条；
  已实测 place/route 全过）。
* 若追求**与厂商位流逐字一致**：保留 `DIFF_POD12_DCI`，但请把注释里的
  "必须用"改成"沿用厂商、超出 ds922 VICM 下限、实测可用"，并知道要多加一个
  `DCIRESET`（或接受 DCIRST-1 警告）。

## 4. MMCM 参数合法性

### 4.1 合法区间（两处独立工具证据，互相印证）

**(a) ds922 Table 38 "MMCM Specification"**（`-1` 速度等级列）：
`MMCM_FVCOMIN = 800 MHz`、`MMCM_FVCOMAX = 1600 MHz`、
`MMCM_FPFDMAX = 550 MHz`、`MMCM_FPFDMIN = 10 MHz`、
`MMCM_FINMAX = 800 MHz`、`MMCM_FOUTMAX = 891 MHz`。

**(b) 本机时钟向导**（clk_wiz v6.0）为 **`xcku5p-ffvb676-1-e`** 生成的 `.xci`
（`prj_clkwiz/cw.srcs/sources_1/ip/cw_oracle/cw_oracle.xci`，全部
`resolve_type: generated`——即工具按该 part 的 speed file 现算出来的）：

```
C_VCO_MIN = 800.000   C_VCO_MAX = 1600.000
C_M_MIN   = 2.000     C_M_MAX   = 128.000     (CLKFBOUT_MULT_F)
C_D_MIN   = 1.000     C_D_MAX   = 80.000      (DIVCLK_DIVIDE)
C_O_MIN   = 1.000     C_O_MAX   = 128.000     (CLKOUT_DIVIDE)
```

### 4.2 主选 `M=12.500, D=1, O=8.000` ⇒ **VCO = 1250 MHz**

| 量 | 值 | 合法区间 | 判 |
|---|---|---|---|
| VCO | **1250.0 MHz** | 800 – 1600 | ✅ 79% 处 |
| PFD | 100.0 MHz | 10 – 550 | ✅ |
| CLKIN1 | 100 MHz | 10 – 800 | ✅ |
| CLKOUT0 | 156.25 MHz | 6.25 – 891 | ✅ |
| M / D / O | 12.500 / 1 / 8.000 | 2–128 / 1–80 / 1–128 | ✅ |

**工具侧收口**（`probe_sstl12_*`，synth→opt→place→route 全流程）：

```
report_clocks:  sys_clk        10.000 ns  {0.000 5.000}  P      {clk_p}
                g_hw.clk_out0   6.400 ns  {0.000 3.200}  P,G,A  {u_clkgen/g_hw.u_mmcm/CLKOUT0}
report_drc   :  Checks found: 0
report_timing:  WNS +5.422 / 0 failing ; WHS +0.050 / 0 failing ; WPWS +2.000 / 0 failing
MMCM site    :  MMCM_X0Y1   (与 T25/U25 同 CLOCK_REGION)
```

> `report_clocks` 里 `g_hw.clk_out0` 的 `G,A` 属性 = Vivado 自己的时序引擎
> **从 MMCM 参数推导**出 6.400 ns —— 这是"输出确实是 156.25 MHz"最硬的工具证据。
> `Edge Shifts {0.000 -1.800 -3.600}` 只是描述该生成时钟的边沿相对 master `sys_clk`
> 的相位偏移（6.4 ns 与 10 ns 不同源整数倍），**不影响周期**；时序报告里写的是
> `period=6.400ns`，所有 setup/hold 都按 6.400 ns 算。

**⚠️ 但 Vivado 的 implementation DRC 不检查 VCO/PFD 区间**（实测）：
`probe_vcolow`（M=1.000 ⇒ VCO=100 MHz）与 `probe_vcohigh`（M=64.000, O=2.000 ⇒ VCO=6400 MHz）
**都能一路 place 通过**。所以"DRC 过了"**不能**当合法性证据 —— 必须查上面 (a)/(b)。

### 4.3 次选参数组（已实测 place 通过，`report_clocks` 同样给 6.400 ns）

| 组 | CLKIN | M | D | O | VCO | PFD | 用途 |
|---|---|---|---|---|---|---|---|
| **主选** | 100 MHz | 12.500 | 1 | 8.000 | 1250.0 | 100 | 默认 |
| **次选 A** | 100 MHz | 25.000 | 2 | 8.000 | 1250.0 | 50 | PFD 减半，回路带宽更低 |
| **次选 B** | 100 MHz | 9.375 | 1 | 6.000 | **937.5** | 100 | 换一个 VCO 工作点 |
| **i_rxc 退路** | 125 MHz | 10.000 | 1 | 8.000 | 1250.0 | 125 | 输入换 PHY 回送的 125 MHz |

（`probe_alt1_*` / `probe_alt2_*` / `probe_alt125_*`；三者的 `g_hw.clk_out0` 都是 6.400 ns。）

## 5. 直接可用的约束片段

```tcl
# P6b 数据面时钟源: 核心板 Y1 = SG7050VAN-100.000000M (LVDS) -> T25/U25
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]
set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sys_clk_p sys_clk_n}]
# 156.25 MHz 输出**不要**手写 create_generated_clock —— MMCME4 的输出由 Vivado
# 依 CLKFBOUT_MULT_F / DIVCLK_DIVIDE / CLKOUT0_DIVIDE_F 自动推导 (结果 6.400 ns)。
```

**集成注意**：`sys_clk`(100 MHz) 与 MMCM 输出 `clk_dp`(156.25 MHz) 是
**同一个源经 MMCM 派生 ⇒ 同步关系**，Vivado 会按时序分析它们之间的路径（不是异步）。
真正的异步边界在 **`i_rxc`(PHY 回送的 125 MHz) ↔ `sys_clk`** 之间。

## 6. 本目录文件

| 文件 | 作用 |
|---|---|
| `pin_probe.tcl/.log` | 引脚属性 / bank / MMCM site 普查（只读器件模型） |
| `mmcm_probe.tcl/.log` | MMCM/PLL/BUFG site 与 CLOCK_REGION |
| `probe.tcl` | 参数化探针（env: `PROBE_TAG/IOSTD/INPER/MULT/OUTDIV/DIVD/PIN_P/PIN_N/FLOW`）；XDC 与顶层由它**生成** |
| `probe_design.v` | 手写等价顶层（默认参数版，供阅读；实际跑的是 `probe_top_<tag>.v`） |
| `probe_pod12dci/ pod12/ sstl12/ lvds/ lvcmos33/ notgc/ vcolow/ vcohigh` 的 `_drc/_clocks/_timing/_util/_clknet.rpt` | 8 个变体的原始报告 |
| `probe_alt1_* / probe_alt2_* / probe_alt125_*` | 次选参数组报告 |
| `clkwiz_oracle.tcl/.log` + `prj_clkwiz/` | 时钟向导独立求解（拿 `C_VCO_MIN/MAX` 的那条路） |
| `pg5_osc_zoom/wide.png`、`pg5_gclk2.png`、`ds922_p13_hp_diff*.png`、`ds922_t15_full.png` | 原理图/数据手册**出图**证据（PDF 文本层错位，不能 grep 判读） |
| `probe_alts_stdout.txt` / `probe_all_stdout.txt` | 批量运行的 stdout |

## 7. 没核到的（诚实列出）

* **MMCM 在真实硅片上是否 lock / 锁定时间**：只能上板看（VIO/LED）。本目录只有
  xsim 的 UNISIM 模型（`tb/tb_clk_gen_p6b.v` 的 G2/G4/G6d 组：UNISIM 在
  1.54 ms 仿真时间锁定；停参考钟后 LOCKED 掉、`rst_dp` 立刻重新置起）。
* **`DIFF_SSTL12` 在真实 0.600 V 共模下的输入灵敏度/抖动**：需要板上示波器或
  误码统计，本目录只有数据手册区间论证。
* **bank 65 里 `VREF_65`(V18) 在板上的接法**：本次没查。`DIFF_SSTL12` 是差分接收，
  探针里 0 DRC 未要求 VREF；但若最终 `write_bitstream` 的 DRC 提出 VREF 相关要求，
  需要回查原理图。
* **`Edge Shifts` 的确切定义**：只确认了"不影响 `report_clocks` 报出的 6.400 ns 周期"
  与"时序报告按 6.400 ns 分析"，未去查 UG 里该字段的正式定义。
