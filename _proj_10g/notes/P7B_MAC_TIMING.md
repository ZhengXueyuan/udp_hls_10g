# P7B_MAC_TIMING.md —— 64 位 XGMII MAC 的时序与资源**实测**（−1 速度等级）

- 日期：2026-09-29
- 性质：**测量报告 + 归因**。回答一个问题：**`mac_rx_10g` / `mac_tx_10g` 在 `xcku5p-ffvb676-1-e`
  （−1，最慢速度等级）上、时钟 156.25 MHz（6.400 ns）、接在官方 `xxv_ethernet` PCS 之后时，收不收敛。**
- **本轮没有改任何 RTL**：`_proj_10g/p7b_mac/rtl/*` 与 `_proj_10g/xxv_loop/` 的既有文件**一字未动**
  （抄本 sha256 见 §8）。全部产物在**新目录** `_proj_10g/p7b_mac_synth/`。
- **没有烧板**（未 `program_hw_devices`）、**未写 QSPI**、**未动 license**、**未执行任何 git 写操作**、
  **未碰 `D:\repo\perfv`**。
- 证据强度标记沿用本工程惯例：【实测】= 本轮工具读数（文件+行号）；【推论】= 由读数推出；
  【未核实】= 不得当判据用。

---

## 0. 一页结论

| 问题 | 答案 |
|---|---|
| **收敛吗** | ✅ **收敛**。PCS+MAC 合并后 **WNS +0.401 / WHS +0.008 / WPWS +0.514，三类失败端点全 0**（`route_design Complete!`） |
| MAC 单独（OOC） | TX **WNS +0.285 / 0 failing**；RX **WNS +0.051 / 0 failing**。hold 数字（TX −2.146 / RX −1.345）**全是 OOC 端口模型的伪影，不是缺陷** |
| **MAC 真正的 hold 余量** | 🔴 **寄存器→寄存器 hold：TX `+0.024 ns` / RX `+0.011 ns`** —— 与 P6a `+0.012`、P7a `+0.018`、官方 PCS `+0.019`/`+0.011` **同量级，极薄但为正**。这是本轮最值得记住的一条 |
| **CRC 链** | **6~7 级逻辑**，reg→reg slack 合并后 **TX +2.588 / RX +2.658** —— **CRC 不是瓶颈**（LUT6 能把 40 输入的 XOR 折成 ~2 级） |
| **真正的关键路径** | 合并后 = **PCS RX 解扰/时钟补偿寄存器 → MAC RX 的 CRC 残差比较器 → `stat_crc_err` 计数使能**，12 级 / 5.800 ns，slack **+0.401**。这是**全设计最坏的一条** |
| **与 PCS 基线的代价** | setup **−1.469 ns**（1.870 → 0.401），0 失败端点；hold **+0.002 ns**（0.006 → 0.008，噪声内）；LUT **+3837**（+42.4%），FF **+1531**（+8.3%），CARRY8 +105，BRAM/URAM/DSP **0 增** |
| **时钟域** | ✅ **核实无缺陷**：MAC TX 与 PCS 的 TX XGMII 捕获寄存器**同域**（`txoutclk_out[0]_1`）；MAC RX 与 PCS 的 RX XGMII 输出寄存器**同域**（`rxoutclk_out[0]_1`）；Inter Clock Table **无任何新增跨域对** |
| **硬门** | 隐式网门（`implicit_gate.bat`，九项自检先跑）= **0 命中**（MAC 相关）；扩展 14 键表 = **0 命中**（MAC 相关）。**10 条 `Synth 8-11241` 全在厂商 AMD 明文例程 `pcs64_pkt_gen_mon_ds.v` 里，且原 PCS 工程同样 10 条** ⇒ 预先存在、与本轮无关 |
| **CRC 资源** | 结构估计 ~2k LUT **偏保守 1.9×**：实测 **TX 1058 / RX 1091 LUT**（OOC 独立综合），合并后 1119 / 1238。CRC 占 MAC LUT 的 **~70%** |
| **工具拆流水了吗** | ❌ **没有**。`u_crc` 里恰好 **32 个 FF**（就是 crc 寄存器本身），合并后同样 32 ⇒ 没有 retiming、没有插流水 |

---

## 1. 方法与产物

### 1.1 三组构建

| 组 | 顶层 | 时钟 | 流程 | 目的 |
|---|---|---|---|---|
| **① mac_tx_ooc** | `mac_tx_min_top`（新写，只把端口接出来） | `clk` **6.400 ns** | `synth_design -mode out_of_context` + `opt/place/route` | 单独测 TX MAC |
| **① mac_rx_ooc** | `mac_rx_min_top`（同上） | `clk` **6.400 ns** | 同上 | 单独测 RX MAC |
| **② A_Base** | `xxv_loop_top`（**逐字节副本**） | 同原工程 | 官方工程全流程 | 同流程**重测基线** |
| **② B_WithMac** | `xxv_mac_top`（副本 + MAC） | 同原工程 | 同上 | PCS+MAC |

- 器件一律 `xcku5p-ffvb676-1-e`；impl 策略一律 `Performance_ExtraTimingOpt`（与 P6a/P7a/xxv 基线同款）。
- **没有用宽松假周期**：① 的 6.400 ns 就是真实 156.25 MHz（官方核自己的 OOC XDC 也写 `create_clock -period 6.40 [get_ports rx_core_clk_0]`）。
- ① 用 **OOC** 的理由：去掉 IBUF/OBUF，让"端口→寄存器"和"寄存器→端口"按**片内同拍 0 外部延迟**分析 ——
  这正是真实系统（MAC 的上游 FIFO 与 PCS 的 `tx_mii_d` 捕获寄存器都**在同片同钟**）的样子。

### 1.2 ② 的集成方式（改了什么，逐条）

`_proj_10g/p7b_mac_synth/tcl/make_xxv_mac_top.py` 从 `xxv_loop_top.v` 的**逐字节副本**生成 `xxv_mac_top.v`，
每一处替换都 `assert` **恰好发生一次**（防"静默没改"）。全部改动 **6 处**（`diff` 只有 `<` **9** 行 / `>` 184 行）：

1. `module xxv_loop_top` → `module xxv_mac_top`
2. 删掉 X0Y5 的常量 idle 流 `assign tx_mii_d_1 = 64'h0707…; assign tx_mii_c_1 = 8'hFF;`（**只删这两条常量**）
3. 插入 MAC 集成块：`mac_tx_10g`（时钟 `tx_mii_clk_1`，**驱动 X0Y5 发射器** `.xgmii_txd(tx_mii_d_1)`）+
   `mac_rx_10g`（时钟 `rx_core_clk_1` = 恢复钟，输入 = **真实** `rx_mii_d_1/rx_mii_c_1`，`m_axis_tready=1`）+
   一个交替发 60B/1514B 的 LFSR 帧源 + 两枚签名寄存器（`^` 折叠全部输出，保证**不被综合裁掉**）
4. 5. 两个空探针槽 `oi34/oi35` 改接两枚签名（**探针数/位宽未变**，VIO IP 未重建）
6. `led[3]` 或进 MAC 的错误旗标

> **X0Y4（厂商判据方向）一行未动**；X0Y5 的**接收**也一行未动。MAC 输出**全部被消费**，所以报出的面积是真实面积。

### 1.3 本轮**我自己**被门抓住的两个缺陷（登记）

| # | 缺陷 | 怎么被抓住 | 结果 |
|---|---|---|---|
| H1 | `set_property top` 被"自动层次更新"**静默覆盖**：OOC 工程实际指向的是 `mac_rx_10g` 而不是 `mac_tx_min_top`（连带后果：XDC 里那些**不存在的端口**会让每条 `set_input_delay`/`set_output_delay` 打 `[Vivado 12-4739] … No valid object(s) found` ⇒ **约束被静默丢弃**，而构建照样往下走） | 我在 tcl 里加的 `_TOP_MISMATCH` 硬守卫（`tcl/run_mac_only.tcl:107-113`）——它直接拒绝构建并打印 `_VERDICT = TOP_NOT_SET` | 已修：`update_compile_order` **先于** `set_property top`，并回读比对。修后每轮 `_SYNTH_GATE_12_4739_N = 0`（`logs/mac_only_stdout.txt:546,1837`） |
| H2 | `mtx_sig_hold` / `mrx_sig_hold` **用在声明之前** ⇒ 隐式 1 位网 ⇒ **32 位端口只连了 1 位**（trap-24 的正身） | `sim/p4gates/implicit_gate.bat`（第一次合并构建报 2 条） | 已修（把 MAC 块插到 `obs_reg` 之前）并**重跑**，干净 |

⇒ 这两条**恰恰证明这两道门是活的**。取证件：`logs/mac_only_stdout_attempt2_TOPFAIL.txt`、
`logs/xxv_mac_stdout_run1_WITH_MY_IMPLICIT_NET.txt`。

---

## 2. ① 独立小顶层（OOC）：MAC 本身

### 2.1 时序总表【实测】

来源：`logs/mac_only_stdout.txt` 第 1479 行（TX）/ 第 2965 行（RX）—— 工具自己的 Intra Clock Table。

| 指标 | `mac_tx_min_top` | `mac_rx_min_top` |
|---|---|---|
| 时钟 | `clk` **6.400 ns** | `clk` **6.400 ns** |
| **WNS / TNS / setup 失败端点** | **+0.285** / 0.000 / **0**（1632 端点） | **+0.051** / 0.000 / **0**（2786 端点） |
| **WHS / THS / hold 失败端点** | **−2.146** / −320.945 / **239** | **−1.345** / −41.184 / **33** |
| **WPWS / TPWS / 脉宽失败端点** | **+2.627** / 0.000 / **0**（576） | **+2.627** / 0.000 / **0**（999） |
| impl 状态 | `route_design Complete, Failed Timing!` | 同左 |

> ⚠️ `_WHS` 与 `_WPWS` 打印成同一个值是我查询写法的产物（`-delay_type min_max` 取的是最坏 min）——
> **脉宽的真值以 Intra Clock Table 的 WPWS = +2.627 / 0 失败 为准**。

### 2.2 半失败端点的归因：**239 / 33 条全是 OOC 端口伪影，寄存器→寄存器一条都没有**【实测】

分类器：`tcl/analyze_ooc.tcl`，结果 `logs/analyze_ooc_stdout.txt` 第 132-140 / 186-194 行。

| | mac_tx | mac_rx |
|---|---|---|
| hold 失败端点 | **239**（与工具总表 THS 完全对账） | **33**（同） |
| 其中起点是**端口** | **239** | **33** |
| 其中起点是**寄存器** | **0** | **0** |
| 最坏端口路径 | `s_axis_tkeep[1]`(端口) → `u_fifo/mem_reg_…/RAMB/I`，**−2.146**，**levels=0, logic=0.000, net=0.000** | `xgmii_rxd[39]`(端口) → `b_data_reg[31]/D`，**−1.345**，levels=1 |
| **最坏寄存器→寄存器 hold** | 🟢 **+0.024**（`m_clen_reg[7]/C → dbg_tx_last_clen_reg[7]/D`） | 🟢 **+0.011**（`push_data_reg[4]/C → u_fifo/mem_reg`） |

**机理（路径原文，`reports/mac_tx_ooc_hold_paths.rpt` 第一条）**：

```
Source:      s_axis_tkeep[1]   (INPUT PORT clocked by clk)
Destination: u_dut/u_fifo/mem_reg_0_15_0_13/RAMB/I
Path Type:   Hold (Min at Slow Process Corner)
Data Path Delay: 0.000ns     Logic Levels: 0     Input Delay: 0.000ns
Clock Path Skew: 2.064ns  (DCD 2.064ns, SCD 0.000ns)
```

**输入端口没有时钟网络（SCD ≡ 0），而目标寄存器的时钟走了 BUFG+布线（DCD = 2.064 ns）** ——
于是每条"端口→寄存器"的 hold 检查都必然差 `DCD + t_hold` 那么多。
真实设计里源寄存器在**同一个时钟网络**上（SCD ≈ DCD，两者对消），这条检查就变成正常的 `t_cq ≥ t_hold`。
⇒ **−2.146 / −1.345 不是 MAC 的缺陷，是 OOC 边界模型的常量偏置**；MAC 的**真** hold 余量就是上表最后一行。

### 2.3 关键路径【实测】

来源：`logs/mac_only_stdout.txt` 的 `_max_P*` / `_min_P*` 行；原件 `reports/*_setup_paths.rpt`、`*_hold_paths.rpt`。

**mac_tx 最坏 setup（`reports/mac_tx_ooc_setup_paths.rpt` 第 1 条）**

```
Slack +0.285   cw_keep_reg[7]/C  →  xgmii_txd[19]   (输出端口)
Data Path Delay 4.077ns (logic 1.000 / route 3.077 = 75% 布线)
Logic Levels 9 (LUT3=3 LUT5=1 LUT6=4 MUXF7=1)
Output Delay 0.000ns ;  Clock Path Skew **−2.003ns** (DCD 0.000 − SCD 2.003)
```
前 **7** 条最坏路径**全部**是 `cw_keep_reg / cw_len_reg / cw_data_reg → xgmii_txd[*]`，
即 **`merge_d` / `bswap64` / `tail_d` 那个尾字拼装 mux**（`mac_tx_10g.v:159-202, 236-253`），**不是 CRC**。
CRC 第一次出现是第 **8** 条：`u_dut/u_crc/crc_reg[14]/C → xgmii_txd[50]`，10 级，slack **+0.402**
（`logs/mac_only_stdout.txt:1488`）。

> ⚠️ **这条 +0.285 对真实系统是偏悲观的**：终点是**输出端口**（DCD = 0），
> 起点寄存器却背着 **2.003 ns 的时钟插入延迟**（SCD）⇒ 预算被白扣 2.003 ns。
> 真实情况下它由 PCS 里**同钟同网络**的寄存器捕获（见 §4），skew 项 ≈ 0 ⇒ 等效 slack ≈ **+2.29**。

**mac_rx 最坏 setup（`reports/mac_rx_ooc_setup_paths.rpt` 第 1 条）**

```
Slack +0.051   xgmii_rxd[54] (输入端口)  →  u_dut/stat_crc_err_reg[24]/CE
Data Path Delay 7.328ns (logic 1.183 / route 6.145 = 84% 布线)
Logic Levels 12 (LUT2=1 LUT5=2 LUT6=9)
Clock Path Skew **+1.057ns** (DCD 1.057, SCD 0)
```
**这条路径确实穿过 CRC**：单元格序列为
`f_tlane[3]_i_11 → f_tlane[3]_i_3 → f_tlane[2]_i_1 → a_keep[1] → crc[30]_i_32 → crc[21]_i_26 →
crc[26]_i_36 → crc[10]_i_5 → crc[10]_i_2 → crc[10]_i_1 → stat_crc_err[31]_i_12 → _i_5 → _i_1 → CE`
—— 即 **`xgmii_rxd` → 逐 lane 解码 → 窗口/左对齐 → `CRC 全网络` → 残差比较器（`crc_nxt == 0xDEBB20E3`）
→ `stat_crc_err` 计数使能**。**这正是任务书点名要看的"CRC 那条链"**，而且它**就是 RX 的最坏路径**。

> ⚠️ 这条 +0.051 对真实系统**偏乐观**：起点是输入端口（SCD = 0），目标寄存器 DCD = 1.057 ⇒
> 白送 1.057 ns。真实情况下起点换成同钟寄存器后 skew ≈ 0 ⇒ 等效 slack ≈ **−1.0**。
> **合并构建（§3）实测答案是 +0.401** —— 因为真实布局把这条路径的布线从 6.145 ns 压到 4.124 ns。

**CRC 自己的 reg→reg（OOC，`reports/*_crc_reg2reg.rpt`）**

| | 最坏 | 级数 | data path |
|---|---|---|---|
| mac_tx | **+2.716**（`crc_reg[14] → crc_reg[6]`） | **7**（LUT4=1 LUT5=1 LUT6=4 MUXF7=1） | 3.577 ns（logic 0.754 / route 2.823） |
| mac_rx | **+1.095**（`crc_reg[7] → crc_reg[27]`） | **7**（LUT6=7） | 5.276 ns（logic 1.053 / route 4.223） |

⇒ **CRC 只有 6~7 级**：`LUT6` 一次能吃 6 输入 XOR，40 输入的 `pad_r` 折成 ~2 级、`nv*` 折成 ~2 级、
9 选 1 修正 mux ~2 级。**"CRC 是长组合链高危点"这个担心在本实现上不成立**——
真正的长链是**逐 lane 解码 + 尾字拼装 + 残差比较器**这些**周边**逻辑（12 级）。

### 2.4 资源【实测】

来源：`reports/mac_tx_ooc_util_hier_routed.rpt` / `mac_rx_ooc_util_hier_routed.rpt`（routed，层级归因）。

| | mac_tx | mac_rx | 合计 |
|---|---|---|---|
| CLB LUT | **1597**（logic 1553 + LUTRAM 44） | **1436**（1392 + 44） | 3033 |
| CLB FF | 488 | 911 | 1399 |
| CARRY8 | 27 | 78 | 105 |
| Block RAM / URAM / DSP | **0 / 0 / 0** | **0 / 0 / 0** | 0 |
| Bonded IOB | 0（OOC 无 IO） | 0 | 0 |
| ├ `crc32_64`（`u_crc`） | **1058 LUT / 32 FF** | **1091 LUT / 32 FF** | 2149（**占 MAC LUT 的 70.9%**） |
| ├ glue（`mac_*_10g` 本体） | 400 / 373 | 201 / 793 | 601 / 1166 |
| └ `fifo_sync`（`u_fifo`） | 141（97+44）/ 83 | 149（105+44）/ 86 | 290 / 169 |

⇒ **结构估计 ~2k LUT / 个 CRC 被实测证伪（偏保守 1.9×）**：真值 **1058 / 1091**。
`u_crc` 里 **FF = 32 = crc 寄存器本身** ⇒ **工具没有 retiming、没有插流水**（合并后仍为 32，见 §3.4）。

---

## 3. ② 与官方 `xxv_ethernet` PCS 合并

### 3.1 逐项对比（同一工程、同一 tcl、同一策略、背靠背两次构建）【实测】

来源：`reports/A_Base_timing_summary_routed.rpt` 与 `reports/B_WithMac_timing_summary_routed.rpt`（各自 `| Design Timing Summary` 块）；
日志 **A_Base** = `logs/xxv_mac_stdout_run1_WITH_MY_IMPLICIT_NET.txt:1757-1806`（该轮同时跑了 A 与 B），
**B_WithMac** = `logs/xxv_mac_stdout.txt:1881-1935`（干净重跑那一轮只跑 B）。

| 指标 | **A_Base（只有 PCS）** | **B_WithMac（PCS+MAC）** | 差 |
|---|---|---|---|
| **WNS** | **+1.870** | **+0.401** | **−1.469** |
| TNS / setup 失败端点 | 0.000 / **0** | 0.000 / **0** | 0 |
| **WHS** | **+0.006** | **+0.008** | **+0.002** |
| THS / hold 失败端点 | 0.000 / **0** | 0.000 / **0** | 0 |
| WPWS / 脉宽失败端点 | +0.514 / **0** | +0.514 / **0** | 0 |
| 端点总数（setup/hold/pw） | 29061 / 29045 / 18613 | 34128 / 34112 / 20320 | +5067 / +5067 / +1707 |
| impl 状态 | `route_design Complete!` | `route_design Complete!` | 同 |

- **A 与 B 是同一次会话里背靠背的两次 `launch_runs`**（A 先 B 后）。
- **A_Base 与仓库里留存的基线逐位一致**（WNS 1.870 / WHS 0.006 / 0 失败 / 三个端点总数全同 / 利用率全同）
  ⇒ ① 流程可复现，② 下面的对比是**同流程**对比（不是跨流程比绝对值）。
- 因为 §1.3 的 H2 是在 A 之后才被门抓到的，**B 用修好的顶层单独重跑了一遍**，
  结果 **WNS/WHS 与第一次逐位相同（0.401 / 0.008）** ⇒ 该修复没有改变时序结论。

> 📌 任务书里引的 "`WNS +1.404 / WHS +0.011`" 是更早的 `s2b` 那一轮；本工程当前留存的
> `impl_1` 基线是 `s2d` 的 **+1.870 / +0.006**，本轮 A_Base 复现的是后者。

**逐时钟域（Intra Clock Table）**

| 时钟 | A_Base WNS / WHS | B_WithMac WNS / WHS | 说明 |
|---|---|---|---|
| `rxoutclk_out[0]` | 1.870 / 0.013 | **2.136** / 0.024 | ch0 接收（未接 MAC） |
| `rxoutclk_out[0]_1` | 1.960 / 0.010 | **0.401** / 0.023 | ⬅ **MAC RX 所在域，新的全局最坏** |
| `txoutclk_out[0]` | 3.396 / 0.039 | 2.854 / 0.031 | ch0 发射（厂商发生器） |
| `txoutclk_out[0]_1` | 4.634 / 0.040 | **0.698** / **0.008** | ⬅ MAC TX 所在域 |
| `dclk` / `USE_DIVIDER.dclk_mmcm` | 6.709/0.033 / 4.910/0.006 | 6.393/0.015 / 5.458/0.020 | 观测域 |
| `txoutclkpcs_out[0]` / `_1` | 4.695/0.127 / 4.666/0.157 | 4.073/0.208 / 4.329/0.044 | GT 内部 |

**每个时钟域、三类检查、失败端点全部为 0。**

### 3.2 合并后全设计最坏路径 = **MAC 的 CRC 比较器链**（12 级）【实测】

`logs/xxv_mac_stdout.txt` **第 1902 行起**（`B_WithMac_max_P1..P10`；最坏 hold 在第 1912 行 `B_WithMac_min_P1`）：

```
slack=0.401  levels=12  logic=1.676  net=4.124
sp = DUT/inst/i_pcs64_top_1/i_pcs64_CORE/i_RX_TOP/i_RX_DESTRIPER/i_CLK_COMP/dataout_reg[10]/C
ep = u_mac_rx/stat_crc_err_reg[28]/CE
```
- 起点是 **PCS 内部的寄存器**（不是端口）⇒ **这条 slack 是"真"的，没有 OOC 偏置**。
- 它就是 §2.3 里 RX 那条"解码 → CRC → 残差比较器"的链，只是起点换成了 PCS 的 XGMII 输出寄存器、
  布线从 6.145 ns 降到 4.124 ns。

**最坏 hold（+0.008）**：

```
slack=0.008  levels=0  logic=0.070  net=0.087
sp = fd_lfsr_reg[62]/C                    ← 我的帧源（真实设计里这里是 fifo_async 的读侧）
ep = u_mac_tx/u_fifo/mem_reg_0_15_70_72/RAMA_D1/I   ← MAC 输入 FIFO 的 LUTRAM 写口
```
第 2 条 hold 是 PCS 自己的 TX 加扰器（`poly_reg[53] → dataout_reg[59]`，+0.013）。
⇒ **MAC 加进来以后，全设计 hold 最紧的点落在"MAC 发送 FIFO 的 LUTRAM 写口"上，+0.008 ns** —— 与
本器件一贯的薄 hold 特征一致（P6a +0.012 / P7a +0.018 / 官方 PCS +0.011）。

### 3.3 资源 delta 与层级归因【实测】

来源：`reports/A_Base_utilization_placed.rpt`、`reports/B_WithMac_utilization_placed.rpt`、
`reports/B_WithMac_util_hier_routed.rpt`。

| 资源 | A_Base | B_WithMac | Δ |
|---|---|---|---|
| CLB LUT | 9040 | **12877** | **+3837（+42.4%）** |
| CLB FF | 18362 | **19893** | **+1531（+8.3%）** |
| CARRY8 | 244 | 349 | +105 |
| BUFGCE | 3 | 4 | +1 |
| Block RAM / URAM / DSP | 0 / 0 / 0 | **0 / 0 / 0** | **0** |
| Bonded IOB | 10 | 10 | **0**（MAC 不占引脚） |
| GTYE4_CHANNEL / MMCM | 2 / 1 | 2 / 1 | 0 |

MAC 的层级归因（routed）：

| 实例 | LUT | FF | 其中 CRC |
|---|---|---|---|
| `u_mac_tx`（mac_tx_10g） | 1692 | 457 | `u_crc` **1119 LUT / 32 FF** |
| `u_mac_rx`（mac_rx_10g） | 1775 | 913 | `u_crc` **1238 LUT / 32 FF** |
| 顶层新增（帧源 + 签名 + snap） | 含在 250 里 | — | — |

（层级之和大于顶层是跨层 LUT 合并所致，Vivado 报告本身有这条注记。）
**CRC reg→reg 在合并设计里仍然宽裕**：TX **+2.588**（6 级）/ RX **+2.658**（7 级）；
`u_mac_tx/u_crc` 与 `u_mac_rx/u_crc` 的 **FF 都恰为 32** ⇒ **工具没有 retiming 拆分 CRC**。

### 3.4 DRC 对比【实测】

两个 deck 都看（`report_drc` 与 `report_methodology`）：

| Deck / 规则 | A_Base | B_WithMac |
|---|---|---|
| `report_drc`：PDCN-1569 / RTSTAT-10 | 3 / 1 | 3 / 1 |
| `report_methodology`：LUTAR-1 | 13 | 13 |
| ─ TIMING-9 / TIMING-10 | 1 / 1 | 1 / 1 |
| ─ TIMING-18（缺 input/output delay） | 8 | 8 |
| ─ XDCC-7 / CLKC-56 | 1 / 1 | 1 / 1 |
| **NSTD-1 / UCIO-1 / AVAL-326 / LUTLP（两个 deck 都查，均 0）** | **0** | **0** |

⇒ **MAC 没有引入任何新的 DRC 条目**（两个 deck 的规则计数逐项相同）。
- A_Base 侧用的是**仓库留存的基线报告**（`baseline/xxv_loop_top_drc_routed.rpt` /
  `…_methodology_drc_routed.rpt`），因为 A 那一轮的项目目录在 B 重跑时被刷新了；两份报告的 DRC 计数
  与 A_Base 自己那轮完全一致。
- ⚠️ **复制脚本的一个小瑕疵（登记）**：`reports/` 里名为 `A_Base_drc_routed.rpt` /
  `B_WithMac_drc_routed.rpt` 的两份文件其实是 **methodology** 报告 —— 因为 glob `*_drc_routed.rpt`
  **同时匹配**了 `*_methodology_drc_routed.rpt`，后写覆盖了先写（两组文件名大小两两相同可自证）。
  上表的 `report_drc` 数字是在**原始 run 目录**里读的。

---

## 4. ③ 时钟域核实（**不做假定，从 routed 网表回读**）【实测】

方法：打开 `xxv_mac_top_routed.dcp`，对**具体寄存器**求 `get_clocks`。
脚本 `tcl/verify_domains.tcl` / `vd2.tcl` / `vd3.tcl` / `vd4.tcl`，日志 `logs/verify_domains_stdout.txt`、`logs/vd4_stdout.txt`。

| 问题 | 读数 | 判定 |
|---|---|---|
| MAC TX 跑在哪个域 | `u_mac_tx/FSM_sequential_state_reg[0]` → **`txoutclk_out[0]_1`** | = PCS 的 `tx_mii_clk_1` |
| MAC RX 跑在哪个域 | `u_mac_rx/b_data_reg[0]` → **`rxoutclk_out[0]_1`** | = PCS 的 `rx_clk_out_1`（CDR 恢复钟） |
| **PCS 用哪个钟捕获 MAC 的 XGMII 输出** | 端点 `DUT/inst/i_pcs64_top_1/i_pcs64_CORE/i_TX_TOP/i_TX_STRIPER/i_TX_ENCODER/is_valid_ctrl_reg[0]` → **`txoutclk_out[0]_1`**；路径 slack **+0.698**，14 级 | ✅ **与 MAC TX 同域** |
| **PCS 用哪个钟驱动 MAC 的 XGMII 输入** | 源 `…/i_RX_DESTRIPER/i_CLK_COMP/dataout_reg[10]` → **`rxoutclk_out[0]_1`**；目标 `u_mac_rx/stat_crc_err_reg[28]` → **`rxoutclk_out[0]_1`**，slack **+0.401** | ✅ **与 MAC RX 同域** |
| **是否新增跨域路径** | Inter Clock Table **只有 2 行**，且与 A_Base 逐字相同（都是 `USE_DIVIDER.dclk_mmcm ↔ dbg_hub …INTERNAL_TCK`，即调试中枢） | ✅ **MAC 引入 0 条新跨域** |
| 复位用对了吗 | MAC 的 `rst_n = ~user_tx_reset_1` / `~user_rx_reset_1`。`user_tx_reset_1` 是核的**输出**且由 `tx_reset_done_async` 驱动（核自己在 `tx_mii_clk` 域用它）；`user_rx_reset_1` 由 `rx_reset_done` 驱动（RX 恢复域） | ✅ 与设计文档 `P7B_MAC_DESIGN.md` §3.1/§3.2 的假定**一致** |

**结论：`mac_*_10g` 的时钟域假定与实际的 PCS 布线一致，没有"假定了某个域而实际不是"的缺陷。**
XGMII 两侧都是**同钟同拍**的片内路径（不是跨域接口）——这正是把 MAC 放在 PCS 之后、而不是隔着
`fifo_async` 的原因（按 `P7B_SPEC §2`，跨域 FIFO 在 MAC **之外**）。

---

## 5. ④ 硬门 grep（逐条报数）

### 5.1 规范检测器先自检

`cmd //c 'sim\p4gates\implicit_gate_selftest.bat'` ⇒
**`SELFTEST_RESULT = PASS_ALL`（9 项对照：4 病理件 FAIL、4 干净件 PASS、1 缺日志 FAIL），exit 0**
⇒ 门在本环境**不是哑的**（病理件 a1 的 `10-3091 actual bit length 1`、a3 的 `Synth 8-11241` 都真的打响了）。

### 5.2 命中数

| 日志 | 隐式网门 `implicit_gate.bat` | 说明 |
|---|---|---|
| `mac_tx_ooc` synth / impl | **OK（exit 0）** | 复制件 `logs/gate/mac_tx_ooc.runs_{synth,impl}_1.log` |
| `mac_rx_ooc` synth / impl | **OK（exit 0）** | 同 |
| 合并 `CMB2_impl` | **OK（exit 0）** | `logs/gate/CMB2_impl.log` |
| 合并 `CMB2_synth` | **IMPLICIT-NET-FAIL（exit 1），10 条** | **10 条全部指向厂商件 `pcs64_pkt_gen_mon_ds.v`** |

**扩展 14 键表**（`logs/gate/*.log`，逐文件计数）：

| 键 | mac_tx synth/impl | mac_rx synth/impl | 合并 synth | 合并 impl |
|---|---|---|---|---|
| `Synth 8-11241` / `undeclared symbol` | 0 / 0 | 0 / 0 | **10** | 0 |
| `VRFC 10-3091] actual bit length 1 differs…` | 0 | 0 | 0 | 0 |
| `VRFC 10-2989` | 0 | 0 | 0 | 0 |
| `implicitly declared`（旧工具键，2025.2 恒 0） | 0 | 0 | 0 | 0 |
| `NSTD-1` / `UCIO-1` / `AVAL-326` | 0 | 0 | 0 | 0 |
| `Opt 31-155` / `Opt 31-67` / `Route 35-7` | 0 | 0 | 0 | 0 |
| `12-4739`（约束被静默丢弃） | **0** | **0** | **0** | **0** |
| `multiple driver` / `does not have driver` | 0 | 0 | 0 | 0 |

> 上表对 `runme.log` 计数。MAC-only 两轮另有 tcl 自己的硬门 `_SYNTH_GATE_12_4739_N = 0` /
> `_SYNTH_GATE_ERROR_N = 0`（`logs/mac_only_stdout.txt:546,547,1837,1838`）。
> ⚠️ `logs/mac_only_stdout.txt` 里能看到 3 处 `12-4739` 字样，**那是我的 tcl 源码被回显**（第 68/109/114 行），
> **不是命中** —— 这也是一类"grep 到自己的探针"的假阳性。

### 5.3 那 10 条命中的定性：**是真命中，但预先存在、与本轮无关**【实测】

10 条逐条（`logs/gate/CMB2_synth.log`）：
`stat_rx_status:185`、`clear_count:189`、`rx_protocol_error:426`、`rx_mii_clk:581`、`ctl_tx_enable:992`、
`ctl_local_loopback:1000`、`ctl_FEC_Enable_Error_to_PCS:1001`、`ctl_FEC_TX_Enable:1002`、
`ctl_FEC_RX_Enable:1334`、`ctl_rx_test_pattern_select:1339` —— **全部在 `pcs64_pkt_gen_mon_ds.v`**，
而那是 **AMD 生成的明文例程**（本工程只做了一处 `pay_sel` 参数化改动，见 `xxv_loop/tcl/s2_build.tcl:40-56`）。

**对照**：**原 `xxv_loop`（只有 PCS）的 synth runme.log 同样有这 10 条**，符号与行号**逐条相同**
（`_proj_10g/xxv_loop/pcs64_2ch/…/synth_1/runme.log`）⇒ 它们是**先于本轮就存在**的，
**不是 MAC、也不是我的集成引入的**。本轮**未修**（超出"只测量与归因"的范围），登记在 §6。

**MAC 相关命中 = 0**（修掉 §1.3 的 H2 之后重跑确认）。

---

## 6. ⑤ 收敛判定

> ### ✅ **在 −1 上收敛。**

1. **单 MAC（OOC）**：TX WNS **+0.285 / 0 failing**；RX WNS **+0.051 / 0 failing**。
   寄存器→寄存器 hold **TX +0.024 / RX +0.011**（正）。三类检查**无一条真失败**。
2. **PCS + MAC 合并**：**WNS +0.401 / WHS +0.008 / WPWS +0.514，三类失败端点全 0**，
   `route_design Complete!`。全设计最坏路径（12 级）仍留 **+0.401 ns**。
3. **没有需要修的路径**。若将来要**加余量**，按本工程偏好（**等价化简 > 拆流水**）排序：

   | 优先级 | 建议 | 依据 |
   |---|---|---|
   | **P1** | **等价化简 `mac_rx_10g` 的"逐 lane 解码 + 窗口 + 残差比较器"**。12 级最坏链的构成是 **解码 ~4 级（`f_tlane*`）→ CRC 网络 ~6 级（`crc[30/21/26/10]_i_*`）→ 残差比较器 ~3 级（`stat_crc_err[31]_i_*`）** —— CRC 之外的周边逻辑占 7 级。把 `lane_is_*` 的 8 路比较（`lane_is_s`/`_t`/`_e`/`_q`/`_bad` 各自 8 位比）改成"先算 2~3 个 (lo,hi) 候选再选"这类**共享比较**结构，可以砍掉并联级数。 | §3.2 最坏路径 12 级；§2.3 的 TX 侧同类链 9~10 级 |
   | **P2** | **`mac_tx_10g` 的 `merge_d`/`tail_d` 尾字 mux 化简**。它是 TX 侧最坏（9~10 级）；`tl(f, idx)` 是个 case 展开成 8 路 5 选择器，可以改成"FCS 4 字节 + 常量向量"的**桶形移位**（等价、更浅）。 | §2.3 TX **前 7 条**全是它 |
   | **P3** | 若要更大余量，**只对 `res_ok` 比较器加 1 级流水**（`crc_nxt` 本已组合可用，加一级寄存器只改时序不改协议语义）。**不建议**动 CRC 本体——它已有 +2.6 ns 余量，且插流水会破掉"末字当拍结清 FCS"的零气泡特性。 | §2.3/§3.3 CRC reg→reg +2.588/+2.658 |
   | — | ⚠️ **真正需要盯的不是 setup 而是 hold**：合并后全设计 hold 最紧点是 **MAC 发送 FIFO 的 LUTRAM 写口（+0.008）**；任何往 MAC 上游加逻辑/改布线的人都必须先看这条。 | §3.2 |

4. ⚠️ **不要引用 OOC 的 −2.146 / −1.345 当"不收敛"的证据** —— 它们是端口模型常量，见 §2.2。

---

## 7. ⑥ 未核实 / 边界（**不得当判据用**）

| # | 项 | 状态 |
|---|---|---|
| U1 | **功能正确性** | 本轮**只测时序与资源**。B_WithMac **没有跑仿真、没有上板**；帧源是合成 LFSR，MAC RX 下游 `tready=1`。**不对功能做任何声明**。 |
| U2 | **② 里厂商判据已失效** | 把 X0Y5 的 idle 常量换成 MAC TX 之后，`pcs64_pkt_gen_mon` 的"判据方向"不再是厂商测试；`completion_status` 在**本轮**无意义。**未测**（没上板）。 |
| U3 | 那 10 条厂商隐式网 | **未修**（AMD 明文例程，超出范围）。它们**不影响本轮时序结论**（是 INFO，且合并前后计数相同）。 |
| U4 | OOC 端口模型的偏置量 | §2.3 的两个偏置（TX 偏悲观 2.003 ns / RX 偏乐观 1.057 ns）是**从路径报告读出的时钟插入延迟**，不是独立测量。合并构建（§3）已给出真值，**但真正的偏置量只在这一次布局里成立**。 |
| U5 | 位流级 DRC | 合并构建**只到 `route_design`**（未 `write_bitstream`）⇒ **bitgen-only DRC（如 LUTLP-1 那一族）没跑**。routed DRC / methodology DRC 已跑，见 §3.4。 |
| U6 | 真实系统布局 | B_WithMac 是我合成的集成方式（MAC 放在 X0Y5，帧源是 LFSR）。**换成真的 `fifo_async` 上游、真的 datapath 之后，绝对值会变**：本轮的 +0.401/+0.008 只能当**该配置**的读数，不能外推。 |
| U7 | 12 GBaud / 板上 | 与本报告无关：本轮**没有**任何板级环节（未烧板）。 |
| U8 | `u_crc` 的 FF=32 是否等于"没有 retiming" | 【推论】。依据：OOC 与合并两次构建里 `u_crc` 都恰 32 FF，且 `crc_reg → crc_reg` 路径的 `LOGIC_LEVELS` 与结构推导（~7）一致。**未**直接比对综合前后网表。 |

---

## 8. 证据索引

### 脚本（全部在 `_proj_10g/p7b_mac_synth/tcl/`）
`run_mac_only.tcl`（①，含 `_TOP_MISMATCH` 硬守卫）· `run_xxv_mac.tcl`（②，含 top 守卫 + 14 键 grep）·
`analyze_ooc.tcl`（hold 端点分类器）· `verify_domains.tcl` / `vd2/vd3/vd4.tcl`（时钟域回读）·
`make_xxv_mac_top.py`（②的顶层生成器，逐处 `assert` 恰好 1 次）

### 日志（`_proj_10g/p7b_mac_synth/logs/`）
`mac_only_stdout.txt`（①，1479 / 2965 行 = Intra Clock Table；1469-1471 / 2955-2957 = WNS/WHS；
1488/1489 = TX 的 CRC 路径与最坏 hold；2967 = RX 最坏 setup）·
`xxv_mac_stdout_run1_WITH_MY_IMPLICIT_NET.txt:1757-1806`（A_Base）·
`xxv_mac_stdout.txt:1881-1935`（B_WithMac，第 1955 行起是 tcl 内置的 14 键 grep 计数）·
`analyze_ooc_stdout.txt:132-140 / 186-194`（hold 端点分类）· `verify_domains_stdout.txt`、`vd4_stdout.txt`（时钟域回读）·
`gate/`（6 份 runme.log 副本）· **两次"被门抓住"的取证**：`mac_only_stdout_attempt2_TOPFAIL.txt`、
`xxv_mac_stdout_run1_WITH_MY_IMPLICIT_NET.txt`

### 报告（`_proj_10g/p7b_mac_synth/reports/`）
`mac_{tx,rx}_ooc_{util_routed,util_hier_routed,setup_paths,hold_paths,crc_reg2reg,drc}.rpt` ·
`A_Base_*` / `B_WithMac_*`{`timing_summary_routed`,`utilization_placed`,`util_hier_routed`,`setup_paths`,`hold_paths`,`drc_routed`,`methodology_drc_routed`,`u_mac_{tx,rx}_crc_reg2reg`}.rpt

### 基线留存（`_proj_10g/p7b_mac_synth/baseline/`）
`xxv_loop_top_timing_summary_routed.rpt`（sha256 `a2a67c45…`）· `xxv_loop_top_utilization_placed.rpt`
（sha256 `acb8d393…`）· `impl_1_runme.log` · `xxv_loop_top.bit`（仅留档，**本轮未烧**）

### 源文件 sha256（★ 证明"没改 RTL"）
```
crc32_64.v   9db328c7fe1a31404e3d4ff21ba6049eda542a99d4c9ddea828d58efb2fccd1f
mac_rx_10g.v e50ca4deed65c5646ffccd636d7b85d30ba0ff6ca9c13c03bc3d2899a35e0154
mac_tx_10g.v b1f4aaff7c852612d5e3c3c03218e017d89df2afee093052cd28d79ac7d232d0
fifo_sync.v  c46c52f6aa9a20adda39a6881f25df63054a05ae2783c8556dae1307786478b1
xxv_loop_top.v db6df683fe137d7ccc73966379bd03ccb2fffdd407c7248be32762dbe42ab2cf  (39 663 B, 681 CRLF)
  → xxv_mac_top.v b2b59f1a44a6d1f3f4cc7f86cddfaae29237748cf4f5f60c4ea638d9c0d86ff8  (48 065 B, 856 CRLF)
```
