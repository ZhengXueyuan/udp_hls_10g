# P7B-BIZ 轮 仿真回归（相关子集）—— 2026-09-30

> 派单：`P7B-BIZ` 轮的**仿真回归 agent**。本轮四组 RTL 改动刚做过一次全实现构建
> （位流 sha256 `d20c08c9…5ed5`，时序三类失败端点 `0/0/0`，WNS +0.077），
> **但 `sim/**` 一条门都没跑** ⇒ 组①/② 的"功能性"证据为零。本文件补这一块。
>
> 施工纪律：**不烧板 / 不写 QSPI / 不改 license / 不动 perfv / 不 add·commit /
> 不改任何 RTL·TB·门脚本 / 不启动 Vivado 全实现构建（`vivado_prj/` 未碰）**。
> 只跑 xvlog/xelab/xsim 面。**跑门一律用自定位 runner**（拒绝真空门）。
> 原始日志：`_proj_10g/notes/p7b_biz_reg/logs/`（每门一份，互不覆盖）。
> 基线：`_proj_10g/notes/P7B_REGRESSION.md`（136 门全仓回归，§4 既存失败 / §5 哑门 / §7 门清单）。

---

## 0. 总判定（一句话）

**本轮（P7B-BIZ 四组改动）引入的真回归 = 0 条。** 派单要求的 11 个入口（含 P4 全矩阵 16 门）
**全部 EXIT=0**，判据行与基线**逐字相同**；**唯一一处数字差异（`p5e_rate` 默认档
`app stat_tx_bytes` 61112 → 61120，+8 B）已用 A/B 三方对照钉死为"门自己的抽样点位移"**
（组④ TB 新增的 `repeat(2) @(posedge clk)`），**与任何 RTL 改动无关**，也不是回归。
组①/② 的**功能性证据**本轮补齐：组① 用**饱和档 + 变异双跑**证明判据有判别力
（缺陷版 `C1 = 41 拍违约 / 线上 1517 B`，修复版 `C1 = 0 / 线上 1525 B`）；
组② 用**专用潜伏门 + 变异双跑**在**饱和态下**证明（缺陷版丢 1 字节/1 个字，修复版逐字节精确）。

---

## 1. 跑了什么、怎么跑的

| # | 入口 | 覆盖门数 | 说明 |
|---|---|---|---|
| 1 | `sim\p4gates\run_matrix_p4dfix.bat` | **16** | **权威 runner**（自定位 + `checkpaths`/`manifestcheck`/`scanlog` + 修订指纹 + 每门独立工作目录） |
| 2 | `sim\p4indm\run_4gates.bat` | 4（复用同一 runner 的 `-only` 委托入口） | 幂等复跑：`pcackoob+vlanchain+vlanburst+stallgate` |
| 3 | `sim\p5e_rate\run_tb_rate.bat p7b1472` ⭐ | 1 | **饱和档**（非默认档，不显式跑就盖不到）+ 重跑 1 次验确定性 |
| 4 | `sim\p5e_rate\run_tb_rate.bat`（默认 `g0p1472`） | 1 | |
| 5 | `sim\p5e_udp\run_tb_app_udp.bat pos` | 1 | |
| 6 | `sim\p4sim\run_tb_slowrx.bat` | 1 | 组②直接相关 |
| 7 | `sim\p4sim\run_tb_slowtx.bat` | 1 | 组②直接相关 |
| 8 | `sim\p4sim\run_tb_rxclass.bat` | 1 | 基线 ★真回归门（复核是否已收口） |
| 9 | `sim\p4sim\run_tb_rxclass_xk.bat` | 1 | 同上 |
| 10 | `sim\p4sim\run_tb_p4_replay.bat` | 1 | 基线哑门（复核是否已修） |
| 11 | `sim\p5c_t3\rev\run_wrapper_elab_chk.bat` | 1 | 基线哑门（复核是否已修）；**本子集里唯一编译全 wrapper 的门** |

⇒ **distinct 门 25 条 / gate-execution 30 次**（矩阵 16 + 委托 4 + 单门 10；
另有一整轮 16 门是**为归档而重跑**的，不计入）。
⚠️ 第 6/7/8/9/10 条共用 `sim/p4sim/xsim.dir` ⇒ **已按目录串行**（与矩阵无冲突：矩阵每门跑在私有
`sim\p4gates\work_<stamp>\<门>\`，且其 `scanlog --logdir` 只扫自己的私有目录）。
⚠️ **hazard（本轮踩到的，值得入账）**：`sim\p4indm\run_4gates.bat` 委托的是**同一个矩阵 runner**，
而该 runner 的 `MATRIX_LOG` 是**固定路径** `sim/p4sim/matrix_p4dfix.log` ⇒ **跑委托入口会把上一轮
全矩阵的 `MATRIX_LOG`（含汇总 / 修订指纹 / 逐门 scanlog）整个覆盖掉**（本轮实测：第 1 次 16 门
的 `MATRIX_LOG` 被 4 门委托运行覆盖）。
**损失边界（已核实）**：逐门判据本身**没丢** —— ① 矩阵把每门输出另存进它自己的私有目录
`sim\p4gates\work_<stamp>\<门>\_gate_console.log`（已逐门归档，见 §9.2）；② 运行 1 的 **stdout**
里也照样打出了全部 16 行 `GATE <名> EXIT=0`（已归档为 `logs/p4_matrix16.log`，**与基线
`logs/p4_matrix16.log` 的 16 行排序后 `diff` 零差异**）。**丢的只是汇总/指纹那一段**。
本文件仍**重跑了整轮 16 门**以取得完整 `MATRIX_LOG`（见 §1.1）。

### 1.1 关于 P4 矩阵：两次独立运行

| 运行 | 时刻 | 结果 |
|---|---|---|
| 第 1 次（权威读数） | 19:59:47 → 20:24:52 | **`gates run : 16 / 16` · `gates failed: 0` · `VERDICT: FROZEN -- all 237 hashed files byte-identical across the run`**，EXIT=0；前后指纹 `DIGEST_ALL` 逐字相同（`eeda6b6a…299d`，`FILES_ALL=237`，`GIT_HEAD=d417589`） |
| 第 2 次（**为归档而重跑**，见 hazard） | 20:35:49 → 21:00:22 | **`gates run : 16 / 16` · `gates failed: 0` · `VERDICT: FROZEN`**，EXIT=0；指纹同第 1 次。**16 门的 `GATE <名> EXIT=0` 列表与第 1 次、与基线 §7 三方逐字相同**（`diff` 实测） |

第 1 次的**逐门原始控制台**已逐门归档：`logs/m16_<门名>_console.log`（含 `unit_retx` /
`unit_fifo` 这两条"哑门"的真判据行，见 §5）。
第 2 次的 `unit_fifo` 判据 `PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302
pops A=567224 B=591216 C=611802 cycles=750700` 与第 1 次、与基线 §5 引用值**三方逐字相同**；
`unit_retx` = `ALL 7 GROUPS PASS`。
（归档件 `logs/p4_matrix16_rerun_matrix_log.txt`，15 035 B / 全量汇总。）

---

## 2. 逐门结果表（门 / 档 / EXIT / 判据行 / vs 基线）

> "vs 基线"一列的判据 = **基线 §7 表那一行是否一字不差**（不是"看着差不多"）。

| # | 门 | 档 | EXIT | 判据行 | vs 基线 |
|---|---|---|---|---|---|
| 1 | `p4_matrix16` | 默认构建 16 门 | **0**（跑 2 次，读数逐字同） | `gates run : 16 / 16` · `gates failed: 0` · `VERDICT: FROZEN -- all 237 hashed files byte-identical` | **逐字相同**（16 门 `GATE <名> EXIT=0` 列表与基线 `diff` 实测零差异） |
| 2 | `p4indm_4gates` | `pcackoob+vlanchain+vlanburst+stallgate` | **0** | `GATE pcackoob EXIT=0` / `vlanchain EXIT=0` / `vlanburst EXIT=0` / `stallgate EXIT=0` · `[P4INDM 4GATES] … exit=0` | **不同（哑门→真门）**：基线 `(无输出)`·`PASS(哑门)`。**非本轮引入**（见 §5） |
| 3 | `p5e_rate` ⭐**p7b1472** | `-d P7B_10G` + `TXGAP=0`（饱和档） | **0**（重跑 2/2 逐字同） | `C1 contract: txf_wr && txf_full on 0 cycles (first @cyc 0); checked pushes=7800` · `C2 framer frames=40 len min/max = 1514/1514 (exp 1514)` · `C3 wire samples=35 len min/max = 1525/1525 (exp 1525)` · `coverage: full_cyc=55670 (satreq=1 floor 20000)` · `RATE GATE: OK (C1 ovf=0 over 7800 pushes; framer 1514 x40; wire 1525 x35; full_cyc=55670)` | **基线无此档**（本轮新增）⇒ 无可比行 |
| 4 | `p5e_rate` | 默认 `g0p1472` | **0** | `app tx_frames=41 bytes=61120 \| utx frames=40 bytes=58880 drop=0 \| mac frames=40 abort=0` · `C1 … 0 cycles; checked pushes=7640` · `C2 1514/1514` · `C3 1525/1525` · `full_cyc=3640` · `RATE GATE: OK` | **一处数字不同**：`61112 → 61120`（+8 B）；另加 6 行新判据（组④）。**已归因 = 门自己的抽样点位移，非回归**（§7） |
| 5 | `p5e_udp_pos` | `pos` | **0** | `P5E UDP APP GATE: OK (rx_frames=10 rx_bytes=13305 tx_frames=25 drop_len=1 drop_ovf=5 split=15 pat_bad=0)` | **逐字相同**（基线原始日志同字） |
| 6 | `p4_slowrx` | 4 模式 `nostall/stall/hard/wd` | **0** | `nostall: PASS (2928 lines)` / `stall: PASS (2928 lines)` / `hard: PASS (2928 lines)` / `wd: PASS (3 lines)` / `tb_slow_rx: PASS` | **判据逐字相同**；唯二差异是两条 `VRFC 10-3645` 警告的**行号**（`slow_rx_adp.v:89/103 → :94/115`，因组②给该文件加了行） |
| 7 | `p4_slowtx` | 3 模式 `nostall/stall/hard` | **0** | `nostall: PASS (98 lines)` / `stall: PASS (98 lines)` / `hard: PASS (98 lines)` / `tb_slow_tx: PASS` | **逐字相同** |
| 8 | `p4_rxclass` | 3 模式 | **0** | `nostall/stall/hard: PASS (161 lines)` · `tb_rx_classify: PASS` | **不同（红→绿）**：基线 **EXIT=1** + `Module <fifo_sync> not found [rtl/rx_classify.v:88]`。**非本轮引入**（见 §5） |
| 9 | `p4_rxclass_xk` | 3 模式 | **0** | 同 #8（逐字同） | 同 #8 |
| 10 | `p4_replay` | 默认（`+PCACK`） | **0** | `DONE rx(pass=407 nm=0 ack=203) tx(fr=406 ack=203) eco(echo=203) slow(cmt=5 drp=0 tx=5 pg=0)` | **不同（哑门→真门）**：基线 `'CACK' 不是内部或外部命令`（**什么都没跑**）·`PASS(哑门)`。**非本轮引入** |
| 11 | `p5c_rev_elab` | 默认 + `APP_MODE` 两配置 | **0** | `[ELAB-CHK PASS] both configs elaborated with 0 ERROR lines` · `DONE (logs: …)` | **不同（哑门→真门 + 吞掉的硬失败消失）**：基线尾部 `DONE (…)` 但日志里有 **elab 硬失败** `Module <udp_tx_frame> not found [board/wrapper_p4.v:2569]`。**非本轮引入** |

**判据行取自各门日志尾**（原始件见 `logs/`）。#1 另有 `unit_retx` / `unit_fifo` 两条哑门的
真判据行（§5）。

---

## 3. ★ 本轮真回归清单

**空。本轮四组改动没有引入任何一条新的失败门。**

判定依据（不是"看着像"）：
1. 派单列的 11 个入口 **29 次执行全部 EXIT=0**，且**判据行或逐字相同、或差异已逐条归因**（§2/§7）。
2. `p4_matrix16` 的指纹是 **before == after**（`DIGEST_ALL` 逐字相同）⇒ 本轮运行期间源码零漂移，
   读数与修订绑定。
3. 唯一一处**数值**差异（`p5e_rate` 默认档 `+8 B`）用 **A/B 三方对照**钉死为门自身的抽样点位移
   （§7），且 `utx frames/bytes`、`mac frames`、`wire len`、帧周期、`[pre]` 12 个采样点
   **全部逐字相同**。
4. 三处"判据行变了"的门（#2/#8-#10/#11）**全部是把**原来**哑的/红的**门变成真门或绿门
   —— 方向与"回归"相反，且三处都在本轮之前就已收口（见 §5 的"已修"标注）。

---

## 4. 既存失败门清单（21 条，**照抄基线 §4**，标明"非本轮引入"）

> ⚠️ **诚实说明：这 21 条一条都不在本 agent 的派单门集里，本轮一条都没跑。**
> 下表**逐字转录**基线 §4 的结论，**只作为"未被本轮触及"的登记**，
> **不能读作"本轮重新验证过"**。要复核请按基线 §8.1 的 `run_all_gates.py` 重跑。

| 门 | 症状（基线读数） | 基线判定 | 本轮是否触及 |
|---|---|---|---|
| `p5_app_close` | 2 条 MISMATCH | 既存（判据解析缺陷，P6b 引入） | ✗ 未跑 |
| `p5_wrapper` | `wrapper GMII: 0 帧` | 既存 | ✗ 未跑 |
| `p5e_t2_wrapper` | `errs=117` | 既存 | ✗ 未跑 |
| `p5e_udp_wrapper` | `errs=1489` | 既存 | ✗ 未跑 |
| `p5b_flowwnd` | FAIL | 既存 | ✗ 未跑 |
| `p5b_ind` | FAIL | 既存 | ✗ 未跑 |
| `p3_tcp_chain` | `TCBF … 3000 vs c000` | 既存（陈旧期望） | ✗ 未跑 |
| `p3_tcp_echo` | 同 TCBF | 既存 | ✗ 未跑 |
| `p3_tcp_rx` | `hard` 段 MAC 统计 MISMATCH | 既存 | ✗ 未跑 |
| `p3_tcp_tx` | `frame count 0 != 17` | 既存 | ✗ 未跑 |
| `f4_regress` | 缺文件 + `stats 不一致` | 既存 | ✗ 未跑 |
| `run_tb_tx` | xsim 打印**用法** | 既存（坏门） | ✗ 未跑 |
| `snapcdc_skew` | `Module <snap_cdc> not found` | 既存（坏门） | ✗ 未跑 |
| `snapcdc24_p6e` | 1 项失败 | 既存 | ✗ 未跑 |
| `p6e_pcie_cnt` | 1 项失败 | 既存 | ✗ 未跑 |
| `p4_chain_active` | `PCACTIVE FAIL (9 errs)` | 既存 | ✗ 未跑 |
| `p4_chain_active_slow` | 同族 | 既存 | ✗ 未跑 |
| `p4_probe` | `XVLOG_FAIL` | 既存（坏门） | ✗ 未跑 |
| `p4_hlsprobe` | `udp payload mismatch` + `udp echo fcs bad` | 既存 | ✗ 未跑 |
| `p5d_mech` | `失配字节=8` | 既存 | ✗ 未跑 |
| （基线 §4.1 偶发）`p5e_udp_portout` | 首跑非零但判据成立（xsim RAMB 碰撞） | 偶发，复跑 3/3 通过 | ✗ 未跑 |

**结论：这 21 条全部"非本轮引入"，且本轮未被触及**（派单门集与它们不相交）。

---

## 5. 哑门 / 静默门清单（**不计入通过**）

> 基线 §5 列 8 条。其中有 3 条**在本轮之前已被 `P7B_GATE_HARNESS_FIX.md` 修好**
> （`p4_replay` / `p5c_rev_elab` / `p4indm_4gates`）—— 本轮回跑**实测确认它们现在是真的**。

| 门 | 基线状态 | 本轮实测 | 归因 |
|---|---|---|---|
| `unit_retx`（矩阵内） | 哑门，尾行 `type xsim.log` ⇒ 无条件 exit 0 | **已读其真判据**：`ALL 7 GROUPS PASS` ⇒ 实为 **PASS** | 既存；**本轮已按纪律读日志尾**（原始件 `logs/m16_unit_retx_console.log`，判据行在其 `xsim.log`） |
| `unit_fifo`（矩阵内） | 哑门，同上 | **已读其真判据**：`PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700` ⇒ 实为 **PASS**。**该值与基线 §5 引用的读数逐字相同**，且内含 `PASS_ph_c fill-to-full (512/4096)` / `PASS_ph_f1 D=8192 fill-to-full: not-full@8191, full@8192, drain byte-exact` 等**边界相位** | 既存；本轮已读（`logs/m16_unit_fifo_console.log`） |
| `p5c_rev_elab` | 哑门，**掩盖了一个既存 elab 硬失败** | ✅ **已修 + 本轮实测真绿**：`[ELAB-CHK PASS] both configs elaborated with 0 ERROR lines`，且基线那条 `Module <udp_tx_frame> not found` 已消失 | `P7B_GATE_HARNESS_FIX.md`（**本轮之前**） |
| `p4_replay` | 空门（`CACK` 笔误，什么都没跑，exit 0） | ✅ **已修 + 本轮实测真绿**：`DONE rx(pass=407 nm=0 ack=203) tx(fr=406 ack=203) eco(echo=203) slow(cmt=5 drp=0 tx=5 pg=0)` | 同上 |
| `p4indm_4gates` | 坏脚本（cmd 语法 `%REPO_ROOT%` 串进 bash ⇒ 结果永远写不出去） | ✅ **已修 + 本轮实测真绿**：4 门 EXIT=0 且 `-only` 过滤正确（其余 12 门打 `SKIPPED -- not selected by /only …`） | 同上 |
| `d2_suite` | 哑门（恒 exit 0；自报 `GATE wrapper EXIT=1`） | **未跑**（不在派单门集） | 既存 |
| `f4_sttrace` | 哑门（无判据） | **未跑** | 既存 |
| `p7b_impl_one` / `p7b_impl_xvlog_all` | 哑门 / 坏脚本 | **未跑** | 既存 |
| `p4_matrix16` | "自带汇总"型哑门 | ✅ **本轮已读其自带汇总**：`gates run : 16 / 16` · `gates failed: 0` · `VERDICT: FROZEN` | 既存用法 |

---

## 6. ⭐ 组①/② 的功能性证据（**重点：不是只报 EXIT=0**）

### 6.1 组① `rtl/app_udp_pattern.v`（TX 字 FIFO 写门 `full`→`full_next`；新增 `stat_tx_ovf`）

**主证据门 = `sim\p5e_rate\run_tb_rate.bat p7b1472`（饱和档），EXIT=0，重跑 2/2 逐字同**：

| 判据 | 读数 | 含义 |
|---|---|---|
| **C1（主判据，逐拍非采样）** | **`txf_wr && txf_full on 0 cycles`**，`checked pushes=7800`（首违约拍 `@cyc 0` = 无违约） | 不变式 `txf_wr(T) ⇒ !txf_full(T)` **全程成立**；且判据**不是空跑**（7800 笔推入被逐笔检过） |
| **C2 帧器几何** | `framer frames=40 len min/max = 1514/1514 (exp 1514)` | 帧器逐帧长度 **恒等于由 PAYLEN 推出的意图值**，且**单元素**（min==max）⇒ 不存在"每帧短 8 B" |
| **C3 线上几何** | `wire samples=35 len min/max = 1525/1525 (exp 1525)` | 线上（mac_tx 的 `gmii_tx_en` 拍数，**与 C2 不同的观测点**）同样恒等 + 单元素 |
| **覆盖见证** | `full_cyc=55670 (satreq=1 floor 20000)` | FIFO **真的被顶满了 55670 拍**（界 20000 取在两模态之间：饱和档 55670 / 默认档 3640）⇒ C2/C3 **不是真空判据** |
| 速率读数 | `PAYLOAD RATE = 929.3 Mbps` · `WIRE RATE = 962.8 Mbps` · 帧周期 1584 拍 | 与修复前逐字相同（改的只是"不丢字"，不是速率） |

**判别力（变异双跑，本 agent 独立复跑）** —— 同一台架、同一激励、只差 `app_udp_pattern.v` 的写门：

| 版本 | C1 | C2 | C3 | 线上帧 | 判定 |
|---|---|---|---|---|---|
| **缺陷版**（`HEAD:rtl/app_udp_pattern.v`，写门用本拍 `full`） | **41 拍违约**（首违约 `@cyc 456`；`checked pushes=7802`；另打 `[CONTRACT FAIL] 41 armed push(es) landed on a FULL TX word FIFO`） | `1506/1514`（**非单元素**；短帧 = 帧器口） | `1517/1517`（**比意图短 8 B**；线上口） | `utx frames=40 bytes=**58576**`（比修复版**少 304 B = 38 个字**，落到 40 条已成帧里） | **`RATE GATE: FAIL errs=4`** |
| **修复版**（工作区，写门用 `full_next`） | **0 拍** | `1514/1514` | `1525/1525` | `utx frames=40 bytes=58880` | **`RATE GATE: OK`** |

⇒ **这条门对组①的缺陷有真判别力**：缺陷版 **41 笔被记账的推入落在满的 FIFO 上**（= 线上少字节、
帧几何非单元素），修复版全绿。
⚠️ **算术核对（不是机理断言）**：C1 报 **41** 笔违约，线上少了 **38** 个字（304 B），
`41 − 38 = 3` 笔落在 `utx` 未计入的尾部（该版本 `app tx_frames=42` 而 `utx frames=40`）。
**这 3 笔的去向未逐拍验证**，仅登记为两数之差。
（读数与组④笔记 `P7B_GATE_COV_FIX.md` 声称的 `C1 = 41 拍违约` / `线上 1517 vs 1525` / `帧器 1506 vs 1514`
**逐数吻合**，本 agent 在自己的 scratch 目录里独立跑出。）
原始件：`logs/ab_old_xsim_ns.log`（缺陷版饱和档）、`logs/p5e_rate_p7b1472.log` + `…_rerun.log`（修复版）。

**默认档（`g0p1472`）的对照**：`C1 = 0`（`checked pushes=7640`）、C2/C3 恒等单元素、`full_cyc=3640`。
⚠️ **诚实标注**：默认档即使是缺陷版 **C1 也是 0**（相位锁定，实测），所以**默认档不能当组①的证据**；
`p7b1472` 的 `-d P7B_10G`（8 B/拍发生器）才是关键前提。
本 agent 独立复跑确认：`HEAD` 版 RTL + 默认档 → `C1 = 0`、`bytes=61120`，与修复版**逐字相同**。

**关于 `stat_tx_ovf` 本身**：这是**板级可见性**用的回读计数器（→ wrapper 快照字 **W56**，
`board/wrapper_p4.v:1291/2510/3577`，本 agent 只读代码确认接线在位）。**仿真里没有任何 TB 读它**
（`grep stat_tx_ovf tb/tb_app_udp_rate.v tb/tb_app_udp.v` = 0 命中）⇒ **它的"恒 0"在仿真面只是
C1 的等价物，不是独立观测点**；真正独立的读数是**板级 W56**（属另一路 agent）。

### 6.2 组② `rtl/frame_fifo.v` + `slow_tx_adp.v` + `slow_rx_adp.v`

**⚠️ 先说结论：派单指定的两条"直接相关门"（`run_tb_slowrx` / `run_tb_slowtx`）
对组②的缺陷本身没有判别力。** 实证：

| 门 | 判据行 | 与 FIFO 占用/拒写有关的判据 | 判别力 |
|---|---|---|---|
| `p4_slowrx` | `nostall/stall/hard: PASS (2928 lines)` + `wd: PASS (3 lines)` + `tb_slow_rx: PASS` | **一条都没有** —— `grep -n "stat_fifo_ovf\|o_full\|occ\|full" tb/tb_slow_rx.v` = **0 命中** | **无**：修复 agent 的 `base_slowrx.log`（修前）与本轮 `post_slowrx.log`/本 agent 复跑**判据行逐字相同** |
| `p4_slowtx` | `nostall/stall/hard: PASS (98 lines)` + `tb_slow_tx: PASS` | **一条都没有**（同上，`tb_slow_tx.v` 0 命中） | **无**：`base_slowtx.log` 与 `post_slowtx.log` 逐字相同 |

⇒ 这两条门能证的只有 **"修复没有伤到既有行为"（零附带损伤）**，**不能**当"缺陷已修"的功能证据。
它们的判据是**字节流等价**（`exp_sr_<模式>.memh` vs `resp_sr_<模式>.memh` 逐行相等，Python `--check`），
**间接**对丢字节敏感，但激励**到不了**出缺陷的相位（唯一闸 = 单帧字节数 > 1783，见
`P7B_LATENT_FIFO_FIX.md` §3.1）。

**组②真正的功能证据 = 专用潜伏门（本 agent 在自己的 scratch 目录里独立复跑，变异双跑）**：

台架 = `_proj_10g/notes/p7b_latent/tb_lat_wf.v`（实例 1：`slow_tx_adp.u_wf`，512 深 73 位 frame_fifo）
与 `tb_lat_of.v`（实例 2：`slow_rx_adp.u_ofifo`，2048 深 9 位 fifo_sync）；**只读引用，未改动**。

| 台架 / 配置 | 变异件（写门改回本拍 `full`） | **当前 RTL（`full_next` 门）** |
|---|---|---|
| `tb_lat_wf`（实例 1） | `sent=8 frames=5 purge=3 words=512 tlasts=4 maxrun=128 dangling=1` · **`fifo_ovf=1`** · **J1/J2/J3 全 FAIL** | `sent=8 frames=4 purge=4 words=385 tlasts=4 maxrun=128 dangling=0` · **`fifo_ovf=0`** · **J1/J2/J3 全 PASS** |
| `tb_lat_of` cfg `2100 7 0`（实例 2，**越阈值**） | `popped=2107 expect=2108 **first_bad=2048**` · `maxocc=2049 full_seen=1 ovf_cyc=1 **stat_fifo_ovf=1`** · **FAIL** | `popped=2108 expect=2108 first_bad=-1` · `maxocc=2048 full_seen=1 ovf_cyc=0 **stat_fifo_ovf=0**` · **PASS（byte-exact）** |

关键点（**这才是"有牙"的读法**）：
- 修复版**照样到达饱和**（`maxocc=2048`、`full_seen=1`）**但不再丢** ⇒ 是**在饱和态下**被验证的，
  不是靠"到不了满"躲过去的。
- 缺陷形态精确可复算：`words=512 = 385 + 127`（丢的正是**带 tlast 的帧末字** ⇒ 帧已 commit、
  线上永不闭合）；`first_bad=2048` 恰好是 FIFO 深度 ⇒ **丢字点 = 满的那一拍**。
- **J1 (`#tlast == stat_frames`) 是协议合同级判据**，不依赖内部信号。
- **反例成因被钉死**：`3008 8 0`（变异件，到满 2048 但写决定相位落在空拍）→ `ovf_cyc=0` **PASS** ⇒
  "到满"是必要非充分，真正的因 = **"到满 + 连续两拍上写"**。变异件**既能丢也能不丢**，
  不是"改坏了什么都报错"。

**对 `frame_fifo` 端口增量的独立覆盖（在派单门集内）**：矩阵的 `unit_fifo` 门用
**位置连接**例化（`tb_frame_fifo.v:88` 只给前 10 个位置）⇒ 新增端口必须**追加在末尾**才不破坏映射。
本轮回跑 `unit_fifo`：**`PASS_ALL`** 且内含 `PASS_ph_c fill-to-full (512/4096)` /
`PASS_ph_f1 D=8192 fill-to-full: not-full@8191, full@8192, drain byte-exact`
⇒ **位置映射未被打乱 + 满/不满边界相位通过**。这是**唯一一条能独立证"加端口无附带损伤"的既有门**。

原始件：`logs/ab_latent_xsim_wf_mut.log` / `…_of_mut.log` / `…_wf_fix.log` / `…_of_fix.log`、
`logs/m16_unit_fifo_console.log`。

### 6.3 ⛔ 覆盖不到的诚实的说明（**不拿 EXIT=0 冒充功能证据**）

1. **派单指定的 `run_tb_slowrx` / `run_tb_slowtx` 覆盖不到组②**（§6.2）：无占用/拒写判据，
   且对缺陷版同样 PASS ⇒ **它们只提供"零附带损伤"证据**。
2. **`stat_tx_ovf` / `stat_fifo_ovf` 在仿真面没有独立读数**（本仓 `tb/**` 里 **0 个 TB 读它们**）⇒
   仿真能证的是**底层合同**（C1 逐拍 / 潜伏门的 `ovf_cyc`、层次探针），**计数器本身的读数只在板级**
   （W56 / W59 / W60）。
   ⚠️ **同名陷阱（订正精化，2026-09-30 晚）**：`grep stat_fifo_ovf tb/` 并非 0 命中 ——
   命中来自 **`mac_rx_64.stat_fifo_ovf`**（`tb/tb_mac_rx_f4.v` 16 处、`tb/tb_f4_chain.v:48`），
   那是 **F4 家族（→ 快照 `W35`）的另一个计数器**，与本轮的 `slow_{tx,rx}_adp` **无关**。
   ⇒ 精确表述应为：**`app_udp_pattern.stat_tx_ovf` / `slow_tx_adp.stat_fifo_ovf` / `slow_rx_adp.stat_fifo_ovf`
   这三个（W56/W59/W60 的源）在 `tb/**` 里 0 个读者**。
3. **`p4_matrix16` / `p4indm` 对组①/② 均无判别力**：矩阵 16 门里没有任何门编译
   `app_udp_pattern.v` 的饱和模态；`unit_fifo` 只覆盖 `frame_fifo` 的端口兼容与边界相位，
   **不覆盖 `slow_tx_adp` 的写门相位**。
4. **`p5e_udp pos` 覆盖不到组①/②**（它走 POS 模式、非饱和；本轮回跑逐字同基线，
   作用是"零回归"而不是"功能证据"）。
5. **`p5c_rev_elab` 只能证"编得过/连线无误"**（两配置 elab 0 ERROR），**无功能判据**。
   它是本轮**唯一编译全 wrapper 的门** ⇒ 对组③（快照窗 51→61 字、`BUILD_ID_V 7→8`、
   `axi_regs` 地址位宽 6→7）只有"结构面无损"这一层证据；**组③的功能读数（快照窗语义）不在本子集内**
   （覆盖它的 `snapcdc24_axr` / `pci_axi_regs` 门不在派单门集，未跑）。
6. **`p7b1472` 没有登记进回归矩阵**：`_proj_10g/notes/p7b_regression/run_all_gates.py:81`
   只登记默认档（见 `P7B_GATE_COV_FIX.md` §6.3，那一节自己就写明"需要另人"）。
   ⇒ **本轮是显式手跑才盖到的**；若没人显式跑，这条判据等于没加。**这是一条**常驻**覆盖率风险。**
7. **组④的 `repeat(2)` 改变了抽样点**（§7）⇒ 默认档的 `app stat_tx_bytes` 与基线不再逐字可比。
   后续若要继续用"逐字对照"做回归判据，要么**把这一行钉进基线**，要么**把 `repeat(2)` 挪到读取之后**。

---

## 7. `p5e_rate` 默认档 `+8 B` 的归因链（**不是回归**）

差异只有一处：`app tx_frames=41 **bytes=61112**` → **`bytes=61120`**（+8 B = **恰好 1 个整字**）。
其余（`utx frames=40 bytes=58880 drop=0`、`mac frames=40 abort=0`、`frames on wire=41`、
`mean frame period=1584`、`mean wire len=1525`、`PAYLOAD/WIRE RATE`、
**12/12 个 `[pre]` 采样行**）**逐字相同**。

**三方 A/B（本 agent 在自己的 scratch 目录里跑，未改任何仓内文件）**：

| 实验 | RTL | TB | `app stat_tx_bytes` | 结论 |
|---|---|---|---|---|
| `ab_base` | `f86b07f:rtl/app_udp_pattern.v`（基线期） | `f86b07f:tb/tb_app_udp_rate.v`（基线期） | **61112** | **基线读数被逐字复现** |
| `ab_tbmix` | 同上（基线期 RTL） | **当前 TB** | **61120** | **只换 TB 就变** |
| `ab_old` | `HEAD:rtl/app_udp_pattern.v`（含 RATE 轮） | 当前 TB | **61120** | 与工作区**逐字相同**（C1=0、C2/C3 恒等、`full_cyc=3640`） |

**根因（`diff` 逐行定死）**：当前 TB 在读取 `stat_tx_bytes` **之前**多了
`tb/tb_app_udp_rate.v:284` 的 `repeat (2) @(posedge clk);  // 让仪器的非阻塞更新落地`，
而该行**只存在于工作区**（`git show HEAD:tb/tb_app_udp_rate.v | grep "repeat (2)"` = 0 命中）
⇒ **是组④本轮新增的**。
多出的 2 拍恰好让 app 在**半发送中的第 42 帧**里多推 **1 个整字**：
`61112 - 41×1472 = 760 B`（95 字，`bcnt=6`）→ `61120 - 41×1472 = 768 B`（96 字，`bcnt=0`），
**逐数自洽**（2 拍 = `bcnt 6→7→0` 并推入末字）。

⇒ **性质**：读的是"应用侧推送计数器"在**晚 2 拍**的取值；**线上输出逐字不变**。
**不是回归、不是设计行为变化、也不是组①/② 的改动**。

---

## 8. 未跑的门与原因 / 遗留风险

| 项 | 原因 |
|---|---|
| 其余 111 条门（基线 136 − 本子集 25） | **不在派单门集**（派单只要"相关子集"）。它们的现役参照仍是基线 §7 表 |
| §4 的 21 条既存失败门 | 同上，与派单门集不相交；**本轮未复验**（已如实标注） |
| `d2_suite` / `f4_sttrace` / `p7b_impl_*` | 同上（哑门/坏脚本，基线已登记） |
| 任何 Vivado 综合/实现/位流生成门（`run_build_*` / `run_syn*` / `verify_*` / `vivado_prj/**`） | **派单明令禁止**（本轮已有一次全实现构建，位流 `d20c08c9…5ed5`） |
| 板级 / JTAG / 烧录（`run_program_*`、对端机 192.168.0.38） | **派单明令禁止**（另一路 agent 正在板级测量） |
| `_proj_10g/notes/p7b_gate4*` 一族 | **文件所有权互斥**（另一 agent 正在写） |

**遗留风险（按严重度）**：
1. ⭐ **`p7b1472` 未登记进矩阵**（§6.3-6）⇒ **饱和覆盖是"手跑才有"的**。建议加一行到
   `run_all_gates.py`（`P7B_GATE_COV_FIX.md` §6.3 已给出行文）。
2. **`sim/p4indm/run_4gates.bat` 会覆盖 `sim/p4sim/matrix_p4dfix.log`**（§1 hazard）
   ⇒ 日后"跑完全矩阵又跑一次委托入口"会**静默丢掉全矩阵的运行记录**（不是判据丢失——
   判据在各自私有工作目录里——但**汇总与 scanlog 记录会没**）。建议给委托运行改一个独立 `MATRIX_LOG`。
3. **`p5e_rate` 默认档的"逐字对照"已被组④的 `repeat(2)` 打断**（§6.3-7 / §7）
   ⇒ 下一轮若按"字面相同"判回归会误报。
4. **组②在既有回归体系里没有留得住的判据**（§6.2）⇒ 潜伏门（`p7b_latent/tb_lat_*.v`）
   **没有进任何常驻 runner**；组②的修复目前靠一次性台架守着。建议把
   `tb_lat_of "2100 7 0"` 那条判据登记成常驻门。
5. **`frame_fifo.full_next` 在 `rtl/tcp_echo.v:93` 等四处仍未连接** —— **是刻意的**
   （那些例化的写口是**组合**的，不需要 `full_next`；§5 of `P7B_LATENT_FIFO_FIX.md` 已逐点判定），
   但 `xelab` 会打 `VRFC 10-3645 port 'full_next' remains unconnected`。**该族本就刻意排除在
   隐式网硬失败键表之外**，不是问题；记录在此以免下一轮误判。

### 8.1 文档订正（本 agent 复核中发现的、**不属于**本次交付的既有表述）

1. `P7B_LATENT_FIFO_FIX.md` §7.3 表里 `p4_slowtx` 的判据行写作
   `nostall/stall/hard: PASS` + `tb_slow_tx: PASS` + **`xref OK`** —— 实测
   **`xref OK: 97 words` 不进门的 stdout**：它是**生成器**`tools/gen_stim_p4_slowtx.py:335` 打印的，
   落在 `sim/p4sim/gen_st.log`（门的 stdout 里没有这一行）。**不影响结论**（那一门确实 PASS）。
2. `sim/p4sim/run_tb_rxclass_xk.bat` **硬编码绝对路径**
   `cd /d D:\repo\XCKU5PMini\udp_hls_10g\sim\p4sim`，且**没有** `p4env`/`p4gate selfcheck` 路径守卫
   （它的兄弟 `run_tb_rxclass.bat` 有 `%REPO_ROOT%` 推导 + selfcheck）。**本 checkout 下它指对了**
   （本轮实测 EXIT=0、判据与本 checkout 一致），但**它属于"真空门"家族的残留形态**：
   一旦这个 checkout 被挪走/复制，它会静默编译**别处的源码**。建议补守卫。

---

## 9. 副作用与文件清单

### 9.1 本 agent 写过的文件（**只在这两处**，与派单边界一致）

```
_proj_10g/notes/P7B_BIZ_REGRESSION.md          ← 本文件
_proj_10g/notes/p7b_biz_reg/
├── logs/                                      ← 每门一份原始日志（见下）
├── P4_MATRIX_FINGERPRINT_20260930_195947_before.txt / _after.txt
├── ab_base/{app_udp_pattern.v, tb_app_udp_rate.v}      ← 基线期副本（scratch）
├── ab_tbmix/{app_udp_pattern.v, tb_app_udp_rate.v}     ← 同上
├── ab_old/{app_udp_pattern.v, ab_old.bat}              ← HEAD 版副本（scratch）
└── ab_latent/{mut_slow_rx_adp.v, mut_slow_tx_adp.v}    ← 变异件**副本**（原件的只读拷贝）
```

**没有改动的**：`rtl/**`、`tb/**`、`board/**`、`sim/**/*.bat|sh|tcl`、`tools/**`、`hls/**`、
`vivado_prj/**` —— 本 agent **只跑与判定**（scratch 里的副本是**新文件**，不是修改）。
`git add` / `git commit` 一次都没有。

### 9.2 原始日志

| 文件 | 内容 |
|---|---|
| `logs/p4_matrix16.log` | 运行 1 的 **stdout**：含全部 16 行 `GATE <名> EXIT=0`（**与基线同名文件排序后 `diff` 零差异**） |
| `logs/m16_<门名>_console.log` × 16 | ⭐ 第 1 次矩阵的**逐门原始控制台**（**权威**；含 `unit_retx`/`unit_fifo` 两条哑门的真判据行） |
| `logs/p4_matrix16_rerun.log` / `…_rerun_matrix_log.txt` | 第 2 次全矩阵（**为归档而跑**：第 1 次的汇总日志被 §1 hazard 覆盖，见下） |
| `logs/p4indm_4gates.log` | 委托入口（4 门） |
| `logs/p5e_rate_p7b1472.log` / `…_p7b1472_rerun.log` | ⭐ 饱和档 ×2 |
| `logs/p5e_rate_default.log` | 默认档 |
| `logs/p5e_udp_pos.log` | |
| `logs/p4_slowrx.log` / `p4_slowtx.log` / `p4_rxclass.log` / `p4_rxclass_xk.log` / `p4_replay.log` | 组②直接相关门 + 三条复核门 |
| `logs/p5c_rev_elab.log` | wrapper 双配置 elab |
| `logs/ab_base_xsim.log` / `ab_tbmix_xsim.log` / `ab_old_xsim.log` / `ab_old_xsim_ns.log` | §7 三方 A/B + 组① 变异双跑 |
| `logs/ab_latent_xsim_{wf,of}_{mut,fix}.log` | 组② 变异双跑（潜伏门） |

### 9.3 一句话

**本轮四组改动：真回归 0 条；组①/② 的功能性证据已用"饱和档 + 变异双跑"补齐
（缺陷版可复现地失败，修复版在饱和态下逐字节精确）；三处"判据行变了"的门都是
把哑门/红门变真/变绿（且都发生在本轮之前）；唯一一处数字差异已归因到门自己的抽样点位移。**
