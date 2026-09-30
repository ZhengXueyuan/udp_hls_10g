# P7B_TIMING_RERUN.md —— P7b 全设计时序重测（RTL 变更后）

- 日期：2026-09-30
- 触发：盘上那份 `P7B_WNS = 0.203 / P7B_WHS = 0.010` 的**读数早于源码**（见 §1），已作废 ⇒ 重跑。
- 性质：**测量报告**。本 agent **未改任何 RTL / XDC / 构建脚本**，**未烧板**，**未写 QSPI**，
  **未动 license**，**未做任何 git 写操作**。
- 证据强度：【实测】= 本轮工具读数（文件 + 行号）；【强相关】= 由读数 + git 史推出，未做隔离构建证伪。

---

## 0. 一页结论

> ### ❌ **不收敛。**
> **`P7B_WNS = −0.173` / `P7B_WHS = +0.010` / `P7B_WPWS` 无负值**；
> **39 个 setup 失败端点，全部落在同一个时钟组 `txoutclk_out[0]_1`（MAC TX / X0Y5 ch1 @156.25 MHz）**，
> hold / 脉宽**失败端点全 0**；`Timing constraints are not met.`（`board/p7b_ku5p_timing.rpt:159`）。
> 位流**已产出**（sha256 `d1ddb3b4…`），但**带着 39 个 setup 违例**，**不满足"先跑完时序重测再烧板"的既定次序**。

**失败端点长什么样（全部 39 条同源同靶）【实测】**：

| 项 | 值 |
|---|---|
| 起点 | **`u_mac_tx/plen_reg[6]/C`** —— **39 条全部同一个起点** |
| 终点 | **`u_pcs/inst/i_pcs64_top_1/…/i_TX_TOP/i_TX_STRIPER/i_TX_ENCODER/<reg>/D`**（39 条全在 PCS TX 编码器，`is_valid_ctrl_reg` 6 / `data_d1_reg` 5 / `ctrl_3_reg` 5 / `terminate_reg` 4 / `is_valid_ctrl_no_error_reg` 4 / …） |
| slack 区间 | **−0.173（最坏） … −0.003** |
| 逻辑级数 | **15–21 级**（15:1 / 16:2 / 17:3 / 18:2 / 19:8 / 20:8 / **21:15**） |
| 路径穿过 | `u_mac_tx/plen_reg[6]` → `u_crc/plen_*` → `u_crc/m_pad_left*` → `u_crc/cw_len_reg*` → **`u_crc/crc[9]_i_*`（CRC 网络）** → `u_crc/crc_keep[6]` → 跨出 MAC 边界 → `u_crc/u_pcs_i_*`（工具把 PCS 侧逻辑折进 MAC 层级名）→ PCS `pcs64_top_24/<hidden>` |

⇒ 就是 **MAC TX 的"尾字 pad/FCS 拼装 + CRC"那条链，合并进 PCS TX 编码器边界后被拉长**。
这与 `P7B_MAC_TIMING.md` §2.3/§3.2 事前点名的 TX 侧高危点（`merge_d`/`tail_d` 尾字 mux + CRC 周边）**同一处**；
当时（独立合成顶层）它是 9–10 级 / `+0.285`，现在是 **21 级 / `−0.173`**。

---

## 1. 证据新于源码的凭据（mtime）【实测】

| 文件 | mtime | 相对 `01:47:52` 的构建 |
|---|---|---|
| **`_proj_10g/p7b_mac/rtl/mac_tx_10g.v`** | **2026-09-30 02:22:33.899** | ⚠️ **晚 35 分钟**（作废旧读数的直接原因） |
| **`board/wrapper_p4.v`** | **2026-09-30 02:49:15.902** | ⚠️ **晚 61 分钟**（任务书只点名了上一条；这条**同样**晚于旧读数） |
| `rtl/rx_classify.v` | 2026-09-29 23:48:08.267 | 早于旧构建（未变） |
| `board/build_p7b_ku5p.tcl` / `run_build_p7b_ku5p.bat` | 2026-09-30 00:05:44 / 00:05:53 | 早于旧构建（未变） |
| `board/ku5p_p7b_gt.xdc` / `ku5p_p7b_cdc.xdc` | 2026-09-30 00:05:18 / 00:05:24 | 早于旧构建（未变） |
| ~~旧读数~~ `board/p7b_ku5p_{stdout,timing,util,drc,clkinteract}` | 2026-09-30 **01:47:52 / :43 / :44 / :50 / :51** | ❌ **早于上面两条源码 ⇒ 作废** |
| ✅ 新读数 `board/p7b_ku5p_*` | 2026-09-30 **09:56:51 / :45 / :46 / :50 / :50** | 晚于**全部**源码 ⇒ 有效 |

旧读数已**原样归档**（不删原件，原件仍被 git 跟踪）：`_proj_10g/notes/p7b_timing_rerun/before/`
（5 份 sha256：stdout `184ae267…` · timing `4162d9ca…` · util `3e47f729…` · drc `26ce31d4…` · clkinteract `26e5643a…`）。

---

## 2. 判据逐条读数【实测】

| # | 判据 | 读数 | 判定 |
|---|---|---|---|
| 1 | `BITSTREAM-OK` 出现且 `P7B_BIT_EXISTS = 1` | `board/p7b_ku5p_stdout.txt:6614` = **1**；bat 控制台 `BITSTREAM-OK` | ✅ |
| 2 | **无** `DROPPED-CONSTRAINT-FAIL` | 命中 **0** | ✅ |
| 3 | **无** `IMPLICIT-NET-FAIL` | 命中 **0** | ✅ |
| 4 | **无** `DRC-KEY-FAIL` | 命中 **0** | ✅ |
| 5 | `P7B_WNS` | **−0.173**（`stdout:6606`） | ❌ |
| 6 | `P7B_WHS` | **+0.010**（`stdout:6608`） | ✅ |
| 7 | `P7B_WPWS` | 无负值（最小值即 −0.173，来自同一个 max 查询；脉宽失败端点全 0） | ✅ |
| 8 | `P7B_CONVERGED_AT_ROUND` / `IS_LOCKED_POSTGEN` | **2** / **0**（IP 收敛，未锁） | ✅ |
| 9 | 位流 sha256 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit` = **`d1ddb3b44ba1dc94fa016b257b9f1b3ba9c49d16404aa881b7865d2dc47487aa`**（15,431,261 B，mtime 09:55:52） | — |

> ⚠️ **bat 的三条硬门只打 banner、不置退出码**（主线已核实）：命中硬门时它**照样** `echo BITSTREAM-OK` 并
> `exit /b 0`。所以上表 2–4 是**我独立对 `board/p7b_ku5p_stdout.txt` 逐串 grep** 的结果，不是引用 bat 的退出码。
> 另：`BITSTREAM-OK` / `BUILD_EXIT` 只出现在 **bat 的 stdout（控制台）**，不在被重定向的工程 stdout 里 ——
> 直接 grep 工程 stdout 得 0 属正常，**不要**据此判"门没跑"。

### 2.1 硬门五键：**主 stdout** 与 **IP OOC run 日志**分栏【实测】

| 键 | 主 `board/p7b_ku5p_stdout.txt` | OOC `vivado_prj/p7b_ku5p_prj.runs/pcs64_synth_1/runme.log` |
|---|---|---|
| `Synth 8-11241` | **0** | **28**（已知例外，见下） |
| `undeclared symbol` | **0** | **28**（同一批） |
| `VRFC 10-3091] actual bit length 1 differs from formal bit length` | **0** | **0** |
| `VRFC 10-2989` | **0** | **0** |
| `implicitly declared`（2025.2 恒 0，仅为旧工具保留） | **0** | **0** |
| 其余 bat 键 `12-4739` / `NSTD-1` / `UCIO-1` / `AVAL-326` / `Opt 31-155` / `Opt 31-67` / `Route 35-7` | **全 0** | — |

- **OOC 的 28 条已逐条核对来源**：**全部**指向厂商生成件
  `vivado_prj/p7b_ku5p_prj.gen/…/pcs64/xxv_ethernet_v5_0_2/pcs64_wrapper.v`（如 `:288 :289 :295`），
  符号形如 `gtwiz_reset_qpll0reset_out` / `gtwiz_reset_qpll0lock_in` / `gt_rxusrclk2_0` —— **与主线预计的 ~28 条同族一致**。
  `Synth 8-11241` 是 **INFO**，不在 bat 的 grep 面内（bat 只 grep 主 stdout）⇒ **不构成新的失败**，
  且**不得**为了让它变 0 去改任何东西。本表**不合并**两栏计数。

---

## 3. 逐时钟组失败端点数（新构建）【实测】

来源：`board/p7b_ku5p_timing.rpt` — 总表 `:153-158`，分组表 Intra Clock Table `:200` 起、Inter Clock Table `:230` 起、Other Path Groups `:242` 起。

**Design Timing Summary（`:156`）**：`WNS −0.173 / TNS −2.938 / **39** 失败端点 / 236,733 总端点`；
`WHS +0.010 / THS 0.000 / **0** 失败`；`WPWS 0.000 / **0** 失败 / 77,355 总端点`。

| 时钟组 | Setup WNS | Setup 失败端点 | Hold WHS | Hold 失败端点 | PW WPWS | PW 失败端点 |
|---|---|---|---|---|---|---|
| **`txoutclk_out[0]_1`（MAC TX / X0Y5 ch1）** | **−0.173** | **39** / 2376 | +0.018 | 0 | +0.618 | 0 |
| `rxoutclk_out[0]_1`（MAC RX / X0Y5 ch1） | +0.206 | 0 / 9599 | +0.010 | 0 | +0.514 | 0 |
| `rxoutclk_out[0]`（ch0 X0Y4） | +1.866 | 0 / 3429 | +0.015 | 0 | +0.514 | 0 |
| `txoutclk_out[0]`（ch0 X0Y4） | +3.420 | 0 / 817 | +0.019 | 0 | +0.616 | 0 |
| `txoutclkpcs_out[0]` / `_1`（GT 内部） | +3.905 / +4.747 | 0 / 34 各 | +0.136 / +0.068 | 0 | +2.828 | 0 |
| `pcie_axi_aclk` | +0.327 | 0 / 48,638 | +0.010 | 0 | +0.211 | 0 |
| `pcie_ref_clk` | +7.426 | 0 / 3702 | +0.011 | 0 | +3.200 | 0 |
| `pipe_clk` | +1.115 | 0 / 2400 | +0.012 | 0 | **0.000** | **0** |
| `sys_clk_100` | +8.155 | 0 / 716 | +0.019 | 0 | +2.000 | 0 |
| `g_hw.clk_out0`（dbg_hub） | +0.170 | 0 / 131,794 | +0.011 | 0 | +2.627 | 0 |
| 4× `…bufg_gt_txoutclkmon_inst/O` | 6.814–6.900 | 0 / 50 各 | 0.045–0.066 | 0 | +3.725 | 0 |
| `…bufg_gt_intclk/O` | +998.842 | 0 / 20 | +0.061 | 0 | +499.725 | 0 |

**Inter Clock Table（`:232` 起）**：3 对，**失败端点全 0** ——
`txoutclk_out[0]_1 → rxoutclk_out[0]_1` WNS **+4.744** / WHS +0.014（64 端点）；
`pcie_axi_aclk → pipe_clk` +1.062 / +0.766（3）；`pipe_clk → pcie_axi_aclk` +3.132 / +0.032（1）。

**Other Path Groups（`**async_default**`，`:244` 起）**：12 行，WNS 0.362–8.247，**失败端点 0** ——
**新构建的 `P7B_WNS = −0.173` 不再来自 async 组**（旧构建那个 0.203 恰恰来自 `pcie_axi_aclk` 的 async_default）。

**独立复算（read-only 打开 `wrapper_p4_routed.dcp`，脚本 `_proj_10g/notes/p7b_timing_rerun/tcl/attr_fail2.tcl`，
日志 `…/attr_stdout3.txt`）**：按**全部 28×28 个有序时钟对**枚举 slack<0 的路径 ⇒
`txoutclk_out[0]_1 → txoutclk_out[0]_1 = 39`，其余**全部 0** ⇒ **与报告表逐数对账**。

---

## 4. 三基线并列对比 + 回归/改善判定【实测】

| 基线 | 来源 | WNS | WHS | WPWS | setup 失败端点 | 是否收敛 |
|---|---|---|---|---|---|---|
| **① 作废的旧 P7b 读数** | `_proj_10g/notes/p7b_timing_rerun/before/p7b_ku5p_timing.rpt:156` | +0.203 | +0.010 | 0.000 | **0** | ✅（但**早于源码**，作废） |
| **② MAC+PCS 合并（独立合成顶层）** | `_proj_10g/notes/P7B_MAC_TIMING.md` §3.1 | +0.401 | +0.008 | +0.514 | **0** | ✅（**不同流程/不同顶层，绝对值不可外推**——该报告 §7 U6 自己声明） |
| **③ P6b final（本 wrapper，无 10G 前端）** | `P6B_ACCEPT.md` §1.2 / `P6B_SUMMARY.md` | +0.168 | +0.010 | 0.000 | **0** | ✅ |
| **④ 本轮（P7b 全设计，当前 RTL）** | `board/p7b_ku5p_timing.rpt:156` | **−0.173** | +0.010 | 0.000 | **39** | ❌ |

### 判定：**相对 P6b 基线是回归。**

- **vs P6b（③→④）**：WNS **+0.168 → −0.173（−0.341 ns）**，失败端点 **0 → 39**。❌ **回归**。
  （P6b 没有 10G 前端，"从 0 个失败端点到 39 个"是实打实的恶化。）
- **vs 作废的旧 P7b（①→④）**：全局 WNS 0.203 → −0.173（−0.376 ns），失败端点 **0 → 39**；❌ **回归**。
  但注意 ① 的 0.203 **是 async_default 组的量**（MAC 无关）；按**同组同比**看更准：
  | 时钟组 | ① 旧构建 | ④ 本轮 | Δ |
  |---|---|---|---|
  | **MAC TX**（旧 `txoutclk_out[0]_3` / 新 `txoutclk_out[0]_1`） | **+0.625**（0 失败） | **−0.173**（**39 失败**） | **−0.798** ❌ |
  | MAC RX | +0.495（0 失败） | +0.206（0 失败） | −0.289（仍为正，无失败） |
  | ch0 RX | +1.543 | +1.866 | +0.323 |
  | ch0 TX | +3.289 | +3.420 | +0.131 |
  | dbg_hub `g_hw.clk_out0` | +0.218 | **+0.170** | −0.048（仍为正） |
  | `pcie_axi_aclk` | +0.270 | **+0.327** | +0.057 |
  | async_default 最坏 | +0.203 | **+0.362** | +0.159 |
  ⚠️ **时钟对象命名在两轮之间变了**（旧 `rx/txoutclk_out[0]_2/_3` → 新 `_0/_1`）⇒ 识别靠**路径所属实例**
  （起点含 `u_mac_tx` / `u_mac_rx`），**不要**按后缀号对号入座。
- **vs ②（合成顶层）**：不可直接比绝对值；但方向一致 —— ② 已预警 **TX 侧**是全设计最坏链的候选，本轮它成真。
- **hold 与脉宽无回归**：WHS 与 P6b **同为 +0.010**，失败端点 0；脉宽 0 失败。**器件一贯的薄 hold 特征未变**
  （P6a +0.012 / P7a +0.018 / 官方 PCS +0.019）⇒ 后续若加逻辑，**第一个该看的是 hold**，不是 setup。

### 归因（【强相关】，未做隔离构建证伪）

- 两轮构建之间**已提交的** RTL 差量 = 提交 `effef26`（2026-09-30 09:07:05，
  "P7b 闸3 功能入库: rx_classify v2 落地 + MAC 接进 wrapper + pad/FCS 缺陷修复"），其中
  `_proj_10g/p7b_mac/rtl/mac_tx_10g.v` **+58/−12**，全部是 **pad/FCS 覆盖修复**
  （新增 `cmask64` 掩码 + 把 keep 扩到 pad lane + 新增 `S_TAIL0` pad 续字路径）。
- **该修复的落点正是本轮最坏路径的落点**：新增的 `cmask64`（由 `popc(tkeep)` 驱动的 64 位掩码）
  **插在 CRC 输入上**，路径里能看到新的 `crc_keep[6]` 与 `m_pad_left*` 级。
- **最坏路径的起点从 `plen_reg[0]` 挪到 `plen_reg[6]`**（旧 +0.625 → 新 −0.173），说明是**同一条结构性路径被拉长**。
- 资源**没有变多**：CLB LUT 69,886 → **69,613（−273）**、FF 68,816 → **68,689（−127）**、
  CARRY8 1413（同）、BRAM 348（同）、URAM 0（同）、DSP 4（同）、BUFGCE **6 → 4**。⇒ 不是"逻辑变多撑爆了"，
  而是**关键路径形状变了**（且工具把它与 PCS TSX 编码器输入跨边界合并，级数从 ~10 涨到 21）。
- 也**不是布局噪声**：`async_default` 最坏反而改善（0.203→0.362）、多数时钟组改善，
  而 TX 组单独恶化 0.798 ns，且 39 个端点**同一个起点**。

---

## 5. 我做了什么 / 没做什么

**做了**：`cmd //c 'board\run_build_p7b_ku5p.bat'`（Vivado 2025.2 batch，09:20:29 → 09:56:51，约 36 分钟）；
归档旧读数；独立 grep 硬门；解析报告逐组读数；**read-only** 打开 `wrapper_p4_routed.dcp` 复算失败端点
（只 `open_checkpoint` + `get_timing_paths`，脚本与日志写在自己的目录里）。

**没做（按铁律）**：未 `program_hw_devices`、未写 QSPI、未改 license、**未改任何 RTL/XDC/构建脚本**、
未 `git add`/`git commit`。

**⛔ 我**没有**修这条时序** —— 按任务书，"构建不收敛就如实报告，修不修由主线决定"。
（若要修，`P7B_MAC_TIMING.md` §6 的优先级表仍然适用：**P1 = 等价化简 RX 侧逐 lane 解码 + 残差比较器**，
**P2 = `mac_tx_10g` 的 `merge_d`/`tail_d` 尾字 mux 化简**；本轮的新证据把 **P2 连同新的 `cmask64`** 顶到了第一位。）

---

## 6. 证据索引

| 内容 | 路径 |
|---|---|
| 旧读数归档（5 份，原样） | `_proj_10g/notes/p7b_timing_rerun/before/` |
| 端点归因脚本（read-only） | `_proj_10g/notes/p7b_timing_rerun/tcl/attr_fail2.tcl` |
| 归因日志（28×28 时钟对枚举 + 39 条路径明细） | `_proj_10g/notes/p7b_timing_rerun/attr_stdout3.txt` · `…/attr_paths.txt` |
| 新读数（本轮有效） | `board/p7b_ku5p_{stdout,timing,util,drc,clkinteract}.*` |
| 位流 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`（sha256 `d1ddb3b4…`） |
| 路由后检查点（归因用） | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp` |

**新读数 sha256**：stdout `3f0ce7d3…` · timing `24739df8…` · util `bf2525db…` · drc `3840b6a3…` · clkinteract `691cedb5…` · bit `d1ddb3b4…`

**关键行号**：`board/p7b_ku5p_stdout.txt:6606/6608`（WNS/WHS）· `:6614`（BIT_EXISTS）·
`board/p7b_ku5p_timing.rpt:156`（总表）· `:159`（`Timing constraints are not met.`）· `:200`（Intra）· `:230`（Inter）· `:242`（Other）·
`:779-793`（最坏路径头）· `:787`（`Slack (VIOLATED) : -0.173ns`）· `:796`（`Logic Levels: 21`）
