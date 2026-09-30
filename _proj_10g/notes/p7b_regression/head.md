# P7b 全仓门回归（逐门重跑）—— 2026-09-30

> 对应交接件 `P7B_HANDOFF.md` §4 未结项 **#5「其余 76 门未逐门重跑」**。
> 本轮改动（`effef26` 的 `rtl/rx_classify.v` v2 + `board/wrapper_p4.v` + `_proj_10g/p7b_mac/rtl/{mac_rx,mac_tx}_10g.v`）
> 之前只跑过 P4 矩阵 16 门 + 少数受影响的门。**本文件把全仓门重跑了一遍。**
>
> 施工纪律：**不烧板 / 不写 QSPI / 不改 license / 不动 perfv / 不 add/commit / 不改任何 RTL·TB·脚本（只跑与判定）**。
> 未起任何 Vivado 综合/实现（构建类门一律排除，见 §2）。
> 原始日志：`_proj_10g/notes/p7b_regression/logs/<门名>.log`（每门一份，互不覆盖）。
> 机器可读结果 + 复跑入口：`p7b_regression/results.json` + `p7b_regression/run_all_gates.py`。

---

## 0. 总判定（一句话）

**本轮 RTL 改动引入了 1 处真回归（波及 2 条门：`p4_rxclass` / `p4_rxclass_xk`，红/绿可分辨），
其余 22 条失败全在基线 revision 上逐字/逐因复现 ⇒ 既存失败；另有 1 条首跑非零属偶发（复跑 3/3 通过）。**

判据：A/B 双跑。基线 = `02d51ed`（本轮改动前，`P7b 文档收口`），
用 `git worktree add --detach` 建独立工作树（`D:\repo\XCKU5PMini\_ab_p7b_02d51ed`，已删），
把未跟踪的 HLS 网表与 `run.tcl` 补齐后**跑同一批门**。

---

## 1. 门数统计（本轮结果）

| 项 | 数 |
|---|---|
| **逐门跑过** | **136** |
| 通过（含 4 条"负对照按期望非零"） | **112**（108 PASS + 4 期望非零） |
| 失败 | **24** |
| ├─ ★**本轮引入的真回归** | **2** |
| ├─ 既存失败（基线 A/B 同红） | **21** |
| └─ 偶发（复跑 3/3 通过） | **1** |
| 静默/哑门（判据不置退出码，**不计入通过**） | **8**（见 §4） |
| 跳过（明确排除，见 §2） | 见 §2 分类计数 |

⚠️ **"跳过"没有混进"通过"**：§2 列出的类目一条都没跑；§4 的哑门单独列。

---

## 2. 门清单怎么来的：完整枚举 + 排除了什么

**枚举入口**（`p7b_regression/enum_gates.py` / `counts.py`，纯只读）：

```
run*.bat / run*.sh，剔 .git / vivado_prj / .runs / xsim.dir / _mut_logs
  ⇒ 645 个入口脚本
```

645 个里能解析出"它编译哪个 TB"的 337 个，按 TB **去重 → 98 组**（同 TB 的历史私有副本 = 同一门，跑它 = 重复同一条判据）；
再加多 case 展开（`p5_adv`×11、`p5e_udp`×6、`p5d_multi`×5、`p5_app close`）与若干 lint/自检门 ⇒ **实跑 136 门**。

**排除的类目与理由**（都不是"门"，或本任务禁止跑）：

| 类目 | 数 | 为什么排除 |
|---|---|---|
| `run_program_*`（硬件烧录） | 19 | **任务铁律：不烧板**；且另一个 agent 正在做闸 4 验收 |
| `run_build_*` / `run_syn*` / `run_hls*` | 23 | 会起 Vivado 综合/实现（任务禁止）；`board/run_build_p7b_ku5p.bat` 被点名不跑 |
| `route_check` / `run_ooc` / `run_timing` / `readback` / `lic_deny` / `xdc_probe` … | 14 | 同上（Vivado 流程） |
| `*_scratch*`（`audit_scratch` `int_scratch` `review_scratch` `board_scratch` `ctrl_scratch` `soak_scratch` `_f2_scratch_*`） | 23 | **脚手架**，非门 |
| 变异 / 负对照（`*_mut*` `*neg*` `*_old` `p4prv` `p4iso` `p4spot` `bad5` `p5dpriv`） | 134 | **期望失败**（跑它只会得到"预期的红"）；不是回归门 |
| `sim/p4gates/evidence/**` | 48 | **归档副本**——那是**另一个 checkout** 的文件，跑它 = 真空门 |
| `probe` / `diag` 一次性探针 | 62 | 探查脚本，无 PASS/FAIL 判据 |
| `runme.bat`（Vivado 工程自动生成） | 48 | Vivado 流文件，非门 |
| `notes/p7b_gate4*`（另一 agent 正在写） | 3 | **文件所有权互斥**，明令别碰 |
| 同 TB 的历史重复副本 | 239 | 同一门，跑它 = 把同一条判据跑 N 遍（去重后保留 canonical 实例） |

---

## 3. ★ 本轮引入的真回归（红/绿可分辨）

### 3.1 `p4_rxclass` / `p4_rxclass_xk` —— `rx_classify` v2 新增 `fifo_sync` 例化，门的编译清单没跟上

| | 基线 `02d51ed` | 本轮（HEAD + 工作区） |
|---|---|---|
| 命令 | `sim\p4sim\run_tb_rxclass.bat` | 同 |
| EXIT | **0** | **1** |
| 判据行 | `tb_rx_classify: PASS`（nostall / stall / hard 三模式各 `PASS (161 lines)`） | `ERROR: [VRFC 10-2063] Module <fifo_sync> not found while processing module instance <u_wf> [rtl/rx_classify.v:88]` → `[XSIM 43-3322] Static elaboration ... failed` |

**机理（已用 git 核实，不是推断）**：
- `rtl/rx_classify.v` 在基线里 `grep -c fifo_sync` = **0**；本轮 = **1**（`rtl/rx_classify.v:88` `fifo_sync #(.W(FW)…) u_wf (…)`）。
- 门 `sim/p4sim/run_tb_rxclass.bat:29` 的编译清单只有 `..\..\rtl\rx_classify.v ..\..\tb\tb_rx_classify.v` ⇒ **v2 的新依赖没补进去**。
- ⇒ **不是设计缺陷**（设计本身编译得过：P4 矩阵 16/16 全过、`p7b_rxcls_v2` 门 3.9 s PASS），
  而是**两条门被本轮改动弄红**（同一条清单的 xk 变体同因，`p4_rxclass_xk` 日志逐字同）。

**收口方向（一句话）**：给这两条门各补一个 `..\..\rtl\fifo_sync.v`（**本任务不改脚本**，只报告）。

**A/B 原始输出**：`p7b_regression/ab/AB_OLD_p4_rxclass.log`（绿）+ `logs/p4_rxclass.log`（红）。

---

## 4. 既存失败（21 门）—— 全部在基线 A/B 上同红

| 门 | 症状（本轮） | A/B 基线 | 疑似根因（只写有证据的） |
|---|---|---|---|
| `p5_app_close` | 2 条 MISMATCH | **同红、同两条** | **判据解析缺陷**（非设计）：`tools/gen_stim_p5_app.py:1005` 的正则取**第一个** `parameter integer RTO_LIM` ⇒ 命中 `ifdef DP_156MHZ` 分支的 `61035`，而默认构建实际用 `48828`；`FIN_TO_LIM` 同病（244141 vs 195313）。**P6b (`e1153e4`) 引入**（`rtl/*.v` 加了 ifdef，判据没跟） |
| `p5_wrapper` | `wrapper GMII: 0 帧` | **同红** | wrapper APP_MODE 全链在**基线上就已 0 帧**（自 P6b 起）。`st0=1 / ready=0001` 说明预置与事件注入是好的 |
| `p5e_t2_wrapper` | `errs=117` | **同红、errs 数逐字相同** | 同上族（真 wrapper 全链）；`stat_frames = 1` 等 117 项 |
| `p5e_udp_wrapper` | `errs=1489` | **同红、errs 数逐字相同** | 同上族 |
| `p5b_flowwnd` | FAIL | 同红 | — |
| `p5b_ind` | FAIL | 同红 | — |
| `p3_tcp_chain` | `TCBF ... 3000 vs c000` | 同红 | **陈旧期望**：P3 时代 TB 硬编码通告窗 `0x3000`(12KB)，P4c 已改 `0xC000`(48KB) |
| `p3_tcp_echo` | 同 TCBF | 同红 | 同上 |
| `p3_tcp_rx` | `hard` 段 MAC 统计 MISMATCH | 同红 | — |
| `p3_tcp_tx` | `frame count 0 != 17` | 同红 | — |
| `f4_regress` | 缺文件 + `stats 不一致` | 同红 | 门依赖的文件不在树里 |
| `run_tb_tx` | xsim 打印**用法** | 同红 | 门自身调用参数错（坏门） |
| `snapcdc_skew` | `Module <snap_cdc> not found` | 同红 | 门编译清单缺 DUT（坏门） |
| `snapcdc24_p6e` | 1 项失败 | 同红 | — |
| `p6e_pcie_cnt` | 1 项失败 | 同红 | — |
| `p4_chain_active` | `PCACTIVE FAIL (9 errs)` | 同红、同 9 errs | — |
| `p4_chain_active_slow` | 同族 | 同红 | — |
| `p4_probe` | `XVLOG_FAIL` | 同红 | 路径不存在（坏门） |
| `p4_hlsprobe` | `udp payload mismatch` + `udp echo fcs bad` | 同红、同两条 | HLS 慢路径探针 |
| `p5d_mech` | `失配字节=8` | 同红 | 与 `p5d_multi known_idle_fifo`（TB 竞争）同族 |

**独立交叉复现**：`d2_suite`（复合套件）**第二次独立复现**了 `GATE wrapper EXIT=1`（它的 18 个子门里唯一非零）。

### 4.1 偶发（1 门）

`p5e_udp_portout`：首跑 EXIT=1，日志尾却是 `P5E UDP APP GATE: OK (neg mode)`（判据其实成立），
同日志有 `Memory Collision Error on RAMB36E1 … tb_app_udp.u_slow_rx.u_ff` ⇒ **xsim 因 TB 竞争的存储碰撞返回非零**（工程坑 17）。
**复跑 3/3 EXIT=0（且 no-memcol）** ⇒ 判**偶发，不是确定失败，也不是本轮回归**。

---

## 5. 哑门 / 静默门（**不计入通过**）

| 门 | 哑的证据 | 读日志尾得到的**真实**判定 |
|---|---|---|
| `unit_retx`（P4 矩阵内） | 尾行是 `type xsim.log` ⇒ **无条件 exit 0** | `ALL 7 GROUPS PASS` ⇒ **实为 PASS** |
| `unit_fifo`（P4 矩阵内） | 同上 | `PASS_ALL frame_fifo unit: writes A=568139 …` ⇒ **实为 PASS** |
| `unit_uart`（已修，作对照） | 尾有 `FAIL:` 判据 + 非零退出 | `ALL_OK` / `UART-GATE-OK` ⇒ PASS |
| `d2_suite` | 尾行是 `echo ==== D2 SUITE END` ⇒ **恒 exit 0**；18 个子门真结果在 `sim/d2run/suite_d2.log` | 自报 **`GATE wrapper EXIT=1`**（其余 17 门 0） |
| `p5c_rev_elab` | 尾行是 `echo DONE (logs: …)` ⇒ **恒 exit 0** | 日志里有 **elab 硬失败**：`Module <udp_tx_cfg> / <udp_tx_frame> not found [board/wrapper_p4.v:2524/2569]` ❗**这个失败长期被吞**（基线 wrapper 同样例化这两个模块、门的 RTLF 清单里没有它们 ⇒ 既存） |
| `f4_sttrace` | `xsim … > NUL 2>&1` 后直接 `exit /b 0` | 无判据 |
| `p4_replay` | bat 里 **`CACK` 笔误**，什么都没跑，exit 0 | **空门** |
| `p4indm_4gates` | `run_4gates.sh` 用 **cmd 语法 `%REPO_ROOT%`** ⇒ 结果永远写不出去；且 `cmd //c *.sh` 跑不动 | **空/坏脚本**（它的 4 门已由 P4 矩阵覆盖：全 EXIT=0） |
| `p7b_impl_one` | 日志 `XVLOG_RC=1` 但 `exit 0` | 最小复现脚本，判据靠人读 |
| `p7b_impl_xvlog_all` | `xvlog` 未用全路径 ⇒ `命令语法不正确`、exit 255 | **坏脚本**（不是门） |

（`p7b_chain` / `p7b_mac` 的结构看似"末行 exit /b 0"，但它们**之前**有 `findstr "VERDICT = PASS" … || exit /b 1` ⇒ **不是哑门**，判据成立。）

---

## 6. 关键读数（本轮重点关注的门）

| 门 | EXIT | 判据行 |
|---|---|---|
| `p4_matrix16`（16 门） | 0 | `gates run : 16 / 16` · `gates failed: 0` · `VERDICT: FROZEN -- all 237 hashed files byte-identical` |
| `p7b_mac` | 0 | `VERDICT = PASS`（337 checks） |
| `p7b_chain` | 0 | `VERDICT = PASS` |
| `p7b_rxcls_v2` | 0 | PASS |
| `p7b_appsplit` | 0 | PASS |
| `p7b_lane4` / `p7b_lanefix_dbg` | 0 | PASS |
| `p5d_multi main / known_idle_fifo` | 0 / 0 | PASS |
| `p5d_multi neg_wq / neg_mgn / neg_mgn0` | 1 / 1 / 1 | **期望非零**（判别力成立） |
| `p5e_udp neglearn` | 1 | **期望非零**（判别力成立） |

---

## 7. 门清单表（136 门逐门）

> 判据行取自 `p7b_regression/logs/<门名>.log` 的尾部；门的 stdout 混有 GBK 编码（本表按 UTF-8 容错读，个别中文显示为 `??`，原文见日志）。
> `判定` 列里 `PASS(期望非零)` 表示"负对照按期望失败"；`PASS(哑门)` 表示该门自身不置退出码、但**人工读了它的判据行**。

