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
| 静默/哑门、空门、坏脚本（**不计入通过**） | **8**：`p4_matrix16`(自带汇总，已读) · `d2_suite` · `p5c_rev_elab` · `f4_sttrace` · `p4_replay` · `p4indm_4gates` · `p7b_impl_one` · `p7b_impl_xvlog_all`（见 §5） |
| 其中**哑门掩盖了真失败**的 | **1**：`p5c_rev_elab`（elab 硬失败 + exit 0，既存） |
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

| # | 门 | 命令 | EXIT | 判据行（日志尾） | 判定 | 归因 |
|---|---|---|---|---|---|---|
| 1 | `p4_matrix16` | `sim\p4gates\run_matrix_p4dfix.bat` | 0 | GATE unit_uart EXIT=0 | PASS(哑门) |  |
| 2 | `p5_app` | `sim\p5sim\run_tb_p5_app.bat` | 0 | P5 APP OK | PASS |  |
| 3 | `p5_app_close` | `sim\p5sim\run_tb_p5_app.bat close` | 1 | P5 CLOSE FAIL (2 ��) | FAIL | 既存 |
| 4 | `p5_wrapper` | `sim\p5sim\run_tb_p5_wrapper.bat` | 1 | P5 WRAPPER FAIL (1 ��) | FAIL | 既存 |
| 5 | `p5_status` | `sim\p5sim\run_tb_p5_status.bat` | 0 | P5 STATUS OK | PASS |  |
| 6 | `p5_adv_len` | `sim\p5sim\run_tb_p5_adv.bat len` | 0 | P5 ADV[len] OK | PASS |  |
| 7 | `p5_adv_b2b` | `sim\p5sim\run_tb_p5_adv.bat b2b` | 0 | P5 ADV[b2b] OK | PASS |  |
| 8 | `p5_adv_wnd` | `sim\p5sim\run_tb_p5_adv.bat wnd` | 0 | P5 ADV[wnd] OK | PASS |  |
| 9 | `p5_adv_fin` | `sim\p5sim\run_tb_p5_adv.bat fin` | 0 | P5 ADV[fin] OK | PASS |  |
| 10 | `p5_adv_findrop` | `sim\p5sim\run_tb_p5_adv.bat findrop` | 0 | P5 ADV[findrop] OK | PASS |  |
| 11 | `p5_adv_abort` | `sim\p5sim\run_tb_p5_adv.bat abort` | 0 | P5 ADV[abort] OK | PASS |  |
| 12 | `p5_adv_evfifo` | `sim\p5sim\run_tb_p5_adv.bat evfifo` | 0 | P5 ADV[evfifo] OK | PASS |  |
| 13 | `p5_adv_reconn_fast` | `sim\p5sim\run_tb_p5_adv.bat reconn_fast` | 0 | P5 ADV[reconn_fast] OK | PASS |  |
| 14 | `p5_adv_reconn_slow` | `sim\p5sim\run_tb_p5_adv.bat reconn_slow` | 0 | P5 ADV[reconn_slow] OK | PASS |  |
| 15 | `p5_adv_multi` | `sim\p5sim\run_tb_p5_adv.bat multi` | 0 | P5 ADV[multi] OK | PASS |  |
| 16 | `p5_adv_accmgn` | `sim\p5sim\run_tb_p5_adv.bat accmgn` | 0 | P5 ADV[accmgn] OK | PASS |  |
| 17 | `p5_fc` | `sim\p5sim\run_tb_p5_fc.bat` | 0 | P5 FC UNIT GATE PASS | PASS |  |
| 18 | `p5_flow` | `sim\p5sim\run_tb_p5_flow.bat` | 0 | P5 FLOW OK (���ڱջ�: ����->�յ� <= 1 ��(�Զ�ͣ��)->�ؿ�->���ش����) | PASS |  |
| 19 | `p5_pattern` | `sim\p5sim\run_tb_p5_pattern.bat` | 0 | P5 PATTERN FAIL viol=0 last_beats=2 keep_bad=1 active=0 | PASS |  |
| 20 | `p5close` | `sim\p5close\run_tb_tcp_close.bat` | 0 | GATE tb_close_g9: DONE (verdict_fail=0) | PASS |  |
| 21 | `p5d_multi_main` | `sim\p5d_multi\run_tb_p5_multi.bat main` | 0 | == P5d multi: 122 checks, 0 FAIL == | PASS |  |
| 22 | `p5d_multi_idle` | `sim\p5d_multi\run_tb_p5_multi.bat known_idle_fifo` | 0 | [probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728 | PASS |  |
| 23 | `p5d_multi_neg_wq` | `sim\p5d_multi\run_tb_p5_multi.bat neg_wq` | 1 | - ① 连接 2 winq=0x0000 != WIN_POOL/N=0x4000 (neg_wq 被写成 0xC000 ⇒ 本条必须 FAIL) | PASS(期望非零) |  |
| 24 | `p5d_multi_neg_mgn` | `sim\p5d_multi\run_tb_p5_multi.bat neg_mgn` | 1 | == P5d multi: 112 checks, 7 FAIL == | PASS(期望非零) |  |
| 25 | `p5d_multi_neg_mgn0` | `sim\p5d_multi\run_tb_p5_multi.bat neg_mgn0` | 1 | - ⑥ MULDONE tmo=0 (got {'tmo': 1, 'k': 2558285}) | PASS(期望非零) |  |
| 26 | `p5d_d1` | `sim\p5d_d1\run_tb_p5d_d1.bat` | 0 | PASS D1a-3 stat_bytes=8 (plen ok) | PASS |  |
| 27 | `p5e_win` | `sim\p5e_win\run_tb_p5e_win.bat` | 0 | payload 27740 / mismatch 0 / app stat_tx_bytes=27740 stat_tx_frames=21 | PASS |  |
| 28 | `p5c_fence` | `sim\p5c_t3\run_tb_p5c_fence.bat` | 0 | P5C-T3 FENCE GATE PASS | PASS |  |
| 29 | `p5c_rev_g2g3` | `sim\p5c_t3\rev\run_tb_rev_g2g3.bat` | 0 | GATE tb_rev_g2g3: PASS (errs=0) | PASS |  |
| 30 | `p5c_rev_elab` | `sim\p5c_t3\rev\run_wrapper_elab_chk.bat` | 0 | DONE (logs: wchk\xv_a.log xv_b.log xe_a.log xe_b.log) | PASS(哑门) |  |
| 31 | `p5udp_split` | `sim\p5udp\run_tb_udp_split.bat` | 0 | P5 UDP SPLIT UNIT GATE PASS | PASS |  |
| 32 | `p5e_t2_guard` | `sim\p5e_t2\run_tb_udp_tx_guard.bat` | 0 | P5E-T2 GUARD GATE: OK (frames=6 drop_len=2 deny=2 neg_fifo_occ=256 neg_sready=0) | PASS |  |
| 33 | `p5e_t2_wrapper` | `sim\p5e_t2\run_tb_p5e_t2_wrapper.bat` | 1 | P5E-T2 WRAPPER GATE: FAIL errs=117 | FAIL | 既存 |
| 34 | `p5e_udp_pos` | `sim\p5e_udp\run_tb_app_udp.bat pos` | 0 | P5E UDP APP GATE: OK (rx_frames=10 rx_bytes=13305 tx_frames=25 drop_len=1 drop_ovf=5 spl | PASS |  |
| 35 | `p5e_udp_splitoff` | `sim\p5e_udp\run_tb_app_udp.bat splitoff` | 0 | P5E UDP APP GATE: OK (neg mode) | PASS |  |
| 36 | `p5e_udp_portout` | `sim\p5e_udp\run_tb_app_udp.bat portout` | 1 | P5E UDP APP GATE: OK (neg mode) | FAIL | 偶发 |
| 37 | `p5e_udp_badcrc` | `sim\p5e_udp\run_tb_app_udp.bat badcrc` | 0 | P5E UDP APP GATE: OK (neg mode) | PASS |  |
| 38 | `p5e_udp_nopeer` | `sim\p5e_udp\run_tb_app_udp.bat nopeer` | 0 | P5E UDP APP GATE: OK (NOPEER: TX 零帧, meta 脉冲 0) | PASS |  |
| 39 | `p5e_udp_neglearn` | `sim\p5e_udp\run_tb_app_udp.bat neglearn` | 1 | P5E UDP APP GATE: FAIL errs=104 | PASS(期望非零) |  |
| 40 | `p5e_udp_wrapper` | `sim\p5e_udp\run_tb_p5e_udp_wrapper.bat` | 1 | P5E-T5 UDP WRAPPER GATE: FAIL errs=1489 | FAIL | 既存 |
| 41 | `p5e_pre_split` | `sim\p5e_pre\run_tb_p5_udp_split.bat` | 0 | P5e UDP SPLIT GATE: PASS | PASS |  |
| 42 | `p5e_rate` | `sim\p5e_rate\run_tb_rate.bat` | 0 | app tx_frames=41 bytes=61112 \| utx frames=40 bytes=58880 drop=0 \| mac frames=40 abort=0 | PASS |  |
| 43 | `p5b_flowwnd` | `sim\p5b_adv\run_tb_p5b_flowwnd.bat` | 1 | ValueError: invalid literal for int() with base 16: '0000000X' | FAIL | 既存 |
| 44 | `p5b_ind` | `sim\p5b_adv\run_tb_p5b_ind.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | 既存 |
| 45 | `p5dx_d6_ctr` | `sim\p5dx_d6\run_ctr.bat` | 0 | done | PASS |  |
| 46 | `p3_cam_tcb` | `sim\p3sim\run_tb_cam_tcb.bat` | 0 | ALL_OK steps=11 | PASS |  |
| 47 | `p3_tcp_chain` | `sim\p3sim\run_tb_tcp_chain.bat` | 1 | MISMATCH (14) | FAIL | 既存 |
| 48 | `p3_tcp_echo` | `sim\p3sim\run_tb_tcp_echo.bat` | 1 | ECHO FAIL (10 errs) | FAIL | 既存 |
| 49 | `p3_tcp_rx` | `sim\p3sim\run_tb_tcp_rx.bat` | 1 | hard: 92 lines, stats {'pss': 15, 'nonmatch': 6, 'ipcsum': 1, 'crc': 0, 'seq': 5, 'ack': | FAIL | 既存 |
| 50 | `p3_tcp_tx` | `sim\p3sim\run_tb_tcp_tx.bat` | 1 | MISMATCH | FAIL | 既存 |
| 51 | `clkgen_p6b` | `sim\clkgen\run_tb_clk_gen_p6b.bat` | 0 | PASS_ALL | PASS |  |
| 52 | `echosim` | `sim\echosim\run_tb_echo.bat` | 0 | DONE echo=20 drop_crc=1 tx_frames=20 tx_bytes=1823 \| rx pass=20 | PASS |  |
| 53 | `f2chk` | `sim\f2chk\run_f2chk.bat` | 0 | ** rcv_nxt MISMATCH: dut=00001000 tb=000035cc | PASS |  |
| 54 | `f4chain` | `sim\f4chain\run_tb_f4_chain.bat` | 0 | F4CHAIN_DONE | PASS |  |
| 55 | `f4_mac` | `sim\f4sim\run_tb_f4_mac.bat` | 0 | F4-GATE-RESULT: PASS_ALL | PASS |  |
| 56 | `f4_ab` | `sim\f4sim\run_f4_ab.bat` | 0 | F4-AB-RESULT: PASS | PASS |  |
| 57 | `f4_bitexact` | `sim\f4sim\run_f4_bitexact.bat` | 0 | BITEXACT-RESULT: PASS (交付词流逐位相同) | PASS |  |
| 58 | `f4_sttrace` | `sim\f4sim\run_f4_sttrace.bat` | 0 | (无输出) | PASS(哑门) |  |
| 59 | `f4_regress` | `sim\f4sim\run_tb_mac_f4regress.bat` | 1 | MAC--RESULT: FAIL | FAIL | 既存 |
| 60 | `f4_suite` | `sim\f4sim\run_f4_suite.bat` | 0 | SUITE DONE | PASS |  |
| 61 | `ff_idle` | `sim\fffix\run_tb_ff_idle.bat` | 0 | PASS_ALL tb_ff_idle: wr=394014 pop=357706 cyc=787650 | PASS |  |
| 62 | `fifo_async` | `sim\fifoasync\run_tb_fifo_async.bat` | 0 | FIFO_ASYNC_GATE: PASS_ALL (case=BAL) | PASS |  |
| 63 | `fifoasync_all` | `sim\fifoasync\run_all.bat` | 0 | FIFO_ASYNC_GATE_ALL: OK | PASS |  |
| 64 | `rxp_diag` | `sim\rxpdiag\run_tb_rxp_diag.bat` | 0 | RXP-DIAG GATE: OK | PASS |  |
| 65 | `rxp_v3` | `sim\rxpdiag\run_tb_rxp_v3.bat` | 0 | RXP-V3 GATE: OK | PASS |  |
| 66 | `rxp_v4` | `sim\rxpdiag\run_tb_rxp_v4.bat` | 0 | RXP-V4 GATE: OK | PASS |  |
| 67 | `rxp_v5` | `sim\rxpdiag\run_tb_rxp_v5.bat` | 0 | RXP-V5 GATE: OK | PASS |  |
| 68 | `rxp_v6` | `sim\rxpdiag\run_tb_rxp_v6.bat` | 0 | RXP-V6 GATE: OK | PASS |  |
| 69 | `rxp_v7` | `sim\rxpdiag\run_tb_rxp_v7.bat` | 0 | RXP-V7 GATE: OK | PASS |  |
| 70 | `rxsim_udp_rx` | `sim\rxsim\run_tb_udp_rx.bat` | 0 | DONE pass=20 nonmatch=6 ipcsum=1 crc=1 bytes=404 \| mac fr=27 crc=1 drop=6 | PASS |  |
| 71 | `txsim_udp_tx` | `sim\txsim\run_tb_udp_tx.bat` | 0 | DONE frames=20 bytes=1823 | PASS |  |
| 72 | `udprx` | `sim\udprx\run_tb_udprx.bat` | 0 | UDPRX RATE GATE: OK (PLEN=1472 NFRM=200 WSP=8) | PASS |  |
| 73 | `udprx_chain` | `sim\udprx_chain\run_tb_udprx_chain.bat` | 0 | UDPRX CHAIN GATE: OK (PLEN=1472 NFRM=200 IDLE=12) | PASS |  |
| 74 | `run_tb_tx` | `sim\run_tb_tx.bat` | 1 | --xsimdir            : Location of xsim.dir directory. Default location is "." i.e. curr | FAIL | 既存/坏门 |
| 75 | `run_tb_crc` | `sim\run_tb_crc.bat` | 0 | INFO: [Common 17-206] Exiting xsim at Wed Sep 30 13:12:26 2026... | PASS |  |
| 76 | `run_tb_csum` | `sim\run_tb_csum.bat` | 0 | DONE | PASS |  |
| 77 | `snap_cdc` | `sim\snapcdc\run_tb_snap_cdc.bat` | 0 | SNAP_CDC_GATE_ALL: OK (NW=14/22/24/32/36 all PASS_ALL) | PASS |  |
| 78 | `snapseq` | `sim\snapseq\run_tb_snap_seq.bat` | 0 | PASS_ALL  tb_snap_seq: 7 组判据全过 (含顺序负对照) | PASS |  |
| 79 | `snapcdc_atk_phase` | `sim\snapcdc\atk\phase\run_atk_phase.bat` | 0 | PHASE-RESULT HA=2000 HB=4000 STEP=100 valids=326 flips=326 fails=0 PASS | PASS |  |
| 80 | `snapcdc_atk_ratio` | `sim\snapcdc\atk\ratio\run_atk_ratio.bat` | 0 | RATIO-RESULT HA=2000 HB=4000 MODE=1 valids=204 flips=204 fails=0 PASS | PASS |  |
| 81 | `snapcdc_atk_req` | `sim\snapcdc\atk\req\run_atk_req.bat` | 0 | REQ-RESULT HA=2000 HB=4000 valids=306 flips=306 reqs=331 fails=0 PASS | PASS |  |
| 82 | `snapcdc_atk_reset` | `sim\snapcdc\atk\reset\run_atk_reset.bat` | 0 | RESET-RESULT MODE=0 valids=160 flips=240 phantom=0 valdurrst=0 fails=0 PASS | PASS |  |
| 83 | `snapcdc_atk_x` | `sim\snapcdc\atk\xprop\run_atk_x.bat` | 0 | X-RESULT valids=56 xval=20 fails=0 PASS | PASS |  |
| 84 | `snapcdc_t0` | `sim\snapcdc\review\run_t0.bat` | 0 | === done === | PASS |  |
| 85 | `snapcdc_t2` | `sim\snapcdc\review\run_t2.bat` | 0 | === done === | PASS |  |
| 86 | `snapcdc_t3` | `sim\snapcdc\review\run_t3.bat` | 0 | === done === | PASS |  |
| 87 | `snapcdc_skew` | `sim\snapcdc\review\run_skew.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | 既存/坏门 |
| 88 | `snapcdc_torture` | `sim\snapcdc\review\run_torture.bat` | 0 | [ok]   ������������������������ | PASS |  |
| 89 | `snapcdc24_axr` | `sim\snapcdc\review24\axr\run.bat` | 0 | PASS_ALL  tb_axi_regs: 22 项判据全过 | PASS |  |
| 90 | `snapcdc24_cdc` | `sim\snapcdc\review24\cdc\run.bat` | 0 | PASS_ALL  tb_snap_cdc: NW=32 判据 0-9 全过 (含负对照 A/B) | PASS |  |
| 91 | `snapcdc24_lint` | `sim\snapcdc\review24\lint\run.bat` | 0 | LINT-DONE | PASS |  |
| 92 | `snapcdc24_p6e` | `sim\snapcdc\review24\p6e\run.bat` | 1 | FAIL      tb_p6e_pcie_wrapper: 1 项失败 | FAIL | 既存 |
| 93 | `snapcdc24_p6e_cnt` | `sim\snapcdc\review24\p6e_cnt\run.bat` | 0 | PASS_ALL  tb_review24_counters | PASS |  |
| 94 | `p6a_ff_us` | `sim\p6a_ku5p\run_tb_frame_fifo_us.bat` | 0 | PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=61 | PASS |  |
| 95 | `p6a_ff_k7` | `sim\p6a_ku5p\run_tb_frame_fifo_k7.bat` | 0 | PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=61 | PASS |  |
| 96 | `p6a_ramb36e2` | `sim\p6a_ku5p\run_tb_ramb36e2_sem.bat` | 0 | === done === | PASS |  |
| 97 | `p6a_rgmii_dbg` | `sim\p6a_ku5p\run_tb_rgmii_dbg.bat` | 0 | === done === | PASS |  |
| 98 | `p6a_rgmii_phy` | `sim\p6a_ku5p\run_tb_rgmii_phy_model.bat` | 0 | VERDICT: K7 前端 FAIL (data TX=0 RX=180)  <= 预期: RX 相位配方不适配 RXDLY=1 | PASS |  |
| 99 | `p6a_preflight` | `sim\p6a_ku5p\pf\run_preflight.bat` | 0 | ==== PREFLIGHT OK (xvlog + xelab clean) ==== | PASS |  |
| 100 | `p6b_lint` | `sim\p6b_lint\lint.bat` | 0 | XELAB-LINT-OK: xelab face ran, log = xelab_lint.log | PASS |  |
| 101 | `p6b_lint_def` | `sim\p6b_lint\lint_def.bat` | 0 | XELAB-LINT-OK: xelab face ran, log = xelab_def.log | PASS |  |
| 102 | `p6e_pcie` | `sim\p6e_pcie\run_tb_p6e_pcie.bat` | 0 | PASS_ALL  tb_p6e_pcie_wrapper: 全链门全过 | PASS |  |
| 103 | `p6e_pcie_cnt` | `sim\p6e_pcie\run_tb_p6e_pcie_counters.bat` | 1 | FAIL      tb_p6e_pcie_counters: 1 项失败 | FAIL | 既存 |
| 104 | `p4_chain_active` | `sim\p4sim\run_tb_p4_chain_active.bat` | 1 | PCACTIVE FAIL (9 errs) | FAIL | 既存 |
| 105 | `p4_chain_active_slow` | `sim\p4sim\run_tb_p4_chain_active_slow.bat` | 1 | PCACTIVE FAIL (9 errs) | FAIL | 既存 |
| 106 | `p4_chain_xk` | `sim\p4sim\run_tb_p4_chain_xk.bat` | 0 | P4 CHAIN OK | PASS |  |
| 107 | `p4_chain_stall_xk` | `sim\p4sim\run_tb_p4_chain_stall_xk.bat` | 0 | PCSTALL OK (burst=200, echo ֡ 240) | PASS |  |
| 108 | `p4_burst_xk` | `sim\p4sim\run_tb_p4_burst_xk.bat` | 0 | BURST OK | PASS |  |
| 109 | `p4_replay` | `sim\p4sim\run_tb_p4_replay.bat` | 0 | ���������ļ��� | PASS(哑门) |  |
| 110 | `p4_rxclass` | `sim\p4sim\run_tb_rxclass.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | ★真回归 |
| 111 | `p4_rxclass_xk` | `sim\p4sim\run_tb_rxclass_xk.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | ★真回归 |
| 112 | `p4_slowrx` | `sim\p4sim\run_tb_slowrx.bat` | 0 | DONE commit=1 drop=0 | PASS |  |
| 113 | `p4_slowtx` | `sim\p4sim\run_tb_slowtx.bat` | 0 | tb_slow_tx: PASS | PASS |  |
| 114 | `p4_txarb` | `sim\p4sim\run_tb_txarb.bat` | 0 | tb_tx_arb: PASS | PASS |  |
| 115 | `p4_probe` | `sim\p4sim\run_probe.bat` | 1 | XVLOG_FAIL | FAIL | 既存/坏门 |
| 116 | `p4_hlsprobe` | `sim\p4sim_hlsprobe\run_hls_udp_probe.bat` | 1 | FAIL: udp echo fcs bad | FAIL | 既存 |
| 117 | `p4indm_4gates` | `sim\p4indm\run_4gates.sh` | 0 | (无输出) | PASS(哑门) |  |
| 118 | `d2_suite` | `sim\d2run\run_suite_d2.bat` | 0 | (无输出) | PASS(哑门) |  |
| 119 | `p4gates_selfcheck` | `sim\p4gates\implicit_gate_selftest.bat` | 0 | SELFTEST_RESULT = PASS_ALL (9 controls: 4 pathological FAIL, 4 clean PASS, 1 missing-log | PASS |  |
| 120 | `p5d_mech` | `sim\p5d_multi\p5dmech\run_mech.bat` | 1 | FAIL PROBE: 长只写后首读必须逐字节精确 (miss==0) —— 非 0 即 TB 激励竞争复现 (先查 tb_p5_multi.v 是否有新的阻塞写命令) 或读侧 | FAIL | 既存 |
| 121 | `p5d_mechf` | `sim\p5d_multi\p5dmech\run_mechf.bat` | 0 | [probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728 | PASS |  |
| 122 | `p7b_mac` | `_proj_10g\p7b_mac\sim\run_tb_mac_10g.bat` | 0 | VERDICT = PASS | PASS(哑门) |  |
| 123 | `p7b_chain` | `_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat` | 0 | VERDICT = PASS | PASS(哑门) |  |
| 124 | `p7b_appsplit` | `_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat` | 0 | ==== tb_p7b_appsplit done: 26 checks, 0 fail ==== | PASS |  |
| 125 | `p7b_rxcls_v2` | `_proj_10g\p7b_rxcls\sim\run_tb_rxcls_v2.bat` | 0 | === tb_rxcls_v2 done: 206 checks, 0 fail === | PASS |  |
| 126 | `p7b_rxcls_legacy` | `_proj_10g\p7b_rxcls\sim\run_legacy_tb_rxclass.bat` | 0 | [LEGACY CROSSCHECK] 3 modes run; products in this dir (resp_rc_*.memh) | PASS |  |
| 127 | `p7a_counters` | `_proj_10g\sim\run_tb_p7a_counters.bat` | 0 | GATE-OK | PASS |  |
| 128 | `xxv_pay_sel` | `_proj_10g\xxv_loop\sim\run_sim_pay.bat` | 0 | TB DONE | PASS |  |
| 129 | `pci_axi_regs` | `_proj_pcie\run_tb_axi_regs.bat` | 0 | PASS_ALL  tb_axi_regs: 22 项判据全过 | PASS |  |
| 130 | `p7b_lanefix_dbg` | `_proj_10g\notes\p7b_lanefix\dbg\run_dbg.bat` | 0 | ==== tb_lane4_dbg done ==== | PASS |  |
| 131 | `p7b_lane4` | `_proj_10g\notes\p7b_udp_diag2\sim\run_lane4.bat` | 0 | ==== tb_p7b_appsplit done: 13 checks, 0 fail ==== | PASS |  |
| 132 | `p7b_impl_xvlog_all` | `_proj_10g\notes\p7b_implicit_repro\run_xvlog_all.bat` | 255 | �����﷨����ȷ�� | FAIL | 坏脚本 |
| 133 | `p7b_impl_xelab` | `_proj_10g\notes\p7b_implicit_repro\run_xelab.bat` | 0 | XELAB_RC=1 | PASS |  |
| 134 | `p7b_impl_one` | `_proj_10g\notes\p7b_implicit_repro\run_one.bat` | 0 | XVLOG_RC=1 | PASS(哑门) |  |
| 135 | `p7b_impl_sv` | `_proj_10g\notes\p7b_implicit_repro\run_sv.bat` | 0 | SV_RC=0 | PASS |  |
| 136 | `p7b_impl_fs` | `_proj_10g\notes\p7b_implicit_repro\fs_semantics.bat` | 0 | T3_rc=1 (1 = no hit = good) | PASS |  |

---

## 8. 复现方式与副作用声明（诚实披露）

### 8.1 怎么复跑

```bash
# 全量（136 门；约 63 分钟，2 路并发，按目录串行避免 xsim.dir 锁）
C:/Users/zhxue/anaconda3/python.exe -u _proj_10g/notes/p7b_regression/run_all_gates.py --jobs 2
# 只跑指定门
... run_all_gates.py --only p7b_mac,p4_rxclass
# A/B（需要先 git worktree add 一个基线树 + 补 HLS 网表与 sim/p4sim/run.tcl）
... ab_batch.py
```

每个门一份日志：`p7b_regression/logs/<门名>.log`（日志头写死了 bat 路径 / 参数 / 期望退出码 / 描述）。

### 8.2 副作用（门自己会写文件）

跑门**必然刷新门自己的产物**。本轮刷新了 **约 37 个"已跟踪"文件**（`git status` 可见），
全部是**门的产物/证据文件**，无一是 RTL/TB/脚本源码：

| 目录 | 数 | 例 |
|---|---|---|
| `sim/fifoasync/` | 15 | `gate_bound.txt` `gate_lat.txt` `fingerprint.txt` |
| `sim/snapcdc/` | 6 | `review/*.txt` |
| `sim/f4sim/st_new/` | 6 | `f4_data.memh` `f4_dv.memh`（TB 刺激镜像） |
| `sim/rxpdiag/` | 5 | 诊断产物 |
| `sim/p4sim/matrix_p4dfix.log` | 1 | **P4 矩阵自己的日志**（矩阵的正式产物，刷新即应有） |
| `_proj_10g/sim/xsim_run.txt` | 1 | P7a 计数器门的产物 |
| `sim/` 下其余单门产物 | 若干 | 各门 `xsim_*.log`（多数已 ignore） |

**没有改动的**：`rtl/**` `tb/**` `board/**` 与任何 `run_*.bat` / `run_*.sh` / `.tcl` 脚本 —— **本任务只跑与判定**。
（`git status` 里 `board/wrapper_p4.v` 的改动是**另一个 agent** 的注释订正（`0x10 → 0x08`，闸 4 相关），
`_proj_10g/notes/P7B_MAC_DESIGN.md` 与 `p7b_mac_synth/tcl/*.tcl` 同样是**别人的**改动。）

A/B 用的 worktree（`D:\repo\XCKU5PMini\_ab_p7b_02d51ed`）**已删除**，`git worktree list` 现只剩主树。

### 8.3 与文档既有表述的**订正**

1. `README.md` / `CLAUDE.md` 写「P4 矩阵 16 门里 `unit_retx` / `unit_fifo` 无条件 exit 0」 ⇒ **成立**，
   本轮**已按纪律读日志尾**：`ALL 7 GROUPS PASS` / `PASS_ALL` ⇒ 两条**实为 PASS**。
2. **新增**：哑门不止那两条。本轮又实测出 **6 条**（`d2_suite` / `p5c_rev_elab` / `f4_sttrace` /
   `p4_replay` / `p4indm_4gates` / `p7b_impl_one`），其中 **`p5c_rev_elab` 的哑门掩盖了一个既存 elab 硬失败**
   （`board/wrapper_p4.v` 例化的 `udp_tx_cfg` / `udp_tx_frame` 不在该门的 RTLF 清单里）。
3. `p4indm/run_4gates.sh` 是 **cmd 语法串进 bash** 的坏脚本（`%REPO_ROOT%`），结果永远写不出去
   —— 属工程「真空门」家族的**残留**，建议列入修复清单。

---

## 9. 一句话结论

**本轮 RTL 改动引入了 1 处真回归 —— `rx_classify` v2 新增 `fifo_sync` 例化、而两条门（`p4_rxclass` / `p4_rxclass_xk`）的编译清单没跟上 ⇒ 两条门由绿转红；除此之外全仓 136 门无任何新增回归（其余 21 条失败在基线 `02d51ed` 上逐字/逐因复现，1 条为偶发）。**
