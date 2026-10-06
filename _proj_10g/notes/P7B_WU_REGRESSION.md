# P7b-WU 修复 —— 独立回归测试报告（2026-10-07）

- 角色：**回归测试 agent**（独立于 RTL 实现 agent 与对抗审查 agent）。目标 = 证明/证伪 `wu` 修复
  **没有引入任何回归**，并把**每一个红色**的归属查清（新红 / 既存红 / 环境性）。
- 被测物：`rtl/app_ctrl.v`（+78/−8，**端口面 0 改动**，新增参数 `WU_LEGACY`）+ 新增 `tb/tb_app_wu.v`、
  `sim/p5wu/run_tb_app_wu.bat`。参照件 = **`ff78247:rtl/app_ctrl.v`**（修复前，md5 `466304fc…`；
  `3257631` 与 `ff78247` 的该文件**逐字相同**）。
- ⚠️ **两件环境事实（先说，都影响读数解释）**：
  1. **HEAD 在我跑的过程中移动了**：起跑时 `ff78247`（改动在工作区未提交）→ 结束时 `09d2189`
     （改动已被提交）。矩阵的 FROZEN 判据是**纯内容 sha256**（`p4gate.py:cmd_compare` 只看内容，
     不看 mtime/HEAD）⇒ **不影响判定**；读数证据见 §2。
  2. **另有 agent 在并发跑仿真与 Vivado 实现**：我起跑前看的 `tasklist` 全程有 1–3 个 `xsim.exe` 与我并存；
     且我事后发现**一台 Vivado 全设计实现**在我整轮矩阵期间运行（`board/p7b_ku5p_stdout.txt` 首行
     `Start of session at: Wed Oct  7 01:50:57 2026`，`p7b_ku5p_timing.rpt` 日期 `02:18:27`）
     ⇒ 这是 §4.1 那次 xsim 引擎崩溃的**唯一合理环境解释**（重跑即绿）。
- 纪律遵守：**未烧板 / 未写任何寄存器 / 未提交 git / 未改任何既存源文件·tb·bat**；
  我的一切新文件都在独占目录 **`sim/p5wu_regress/`**（未碰 `sim/p5wu_review/`）。

---

## 0. 结论（要点先给）

| # | 结论 | 证据强度 |
|---|---|---|
| ① | **新 TB 真绿**：`run_tb_app_wu.bat` EXIT=0，`P7B WU GATE OK`，**38 PASS / 0 FAIL**，lockstep=0 | 实跑 |
| ② | **P4 矩阵 16 门**：**15 门 EXIT=0**；唯一红 `dupstorm` 是 **xsim 引擎崩溃（非可复现）**，重跑 `BURST OK` / EXIT=0 | 实跑 + 重跑 |
| ③ | **P4 矩阵与 `app_ctrl` 结构性无关 —— 证实**（比作者给的证据更全：清单/批处理/守卫/指纹**全 0 命中**） | 结构证明 |
| ④ | **作者含糊的 `p5d_multi main "122/0 FAIL"` = “122 checks, 0 FAIL”（0 个失败）**，EXIT=0 | 实跑 + 原始行 |
| ⑤ | **P5 族共 19 门实跑**：15 门 **EXIT=0**（含 `p5_fc` 110 项、`p5_flow`、`p5close`、`p5d_d1`、`p5e_win`、`p5e_udp pos`）；4 门 **EXIT=1**（`p5_wrapper`/`p5e_t2_wrapper`/`p5e_udp_wrapper`/`p5_app close`）**全部既存红**；另有 `p5_pattern` 门虽 EXIT=0，但其**哑门吞掉了 TB 自报的判据红**（亦既存）⇒ **无一条新红** | 实跑 + 双跑 + 历史对照 |
| ⑥ | **149 份日志过规范坑-24 检测器（`implicit_gate.bat`）→ 0 命中**；宽面 ERROR 扫描只有那次崩溃 | 实跑 |
| ⑦ | ⚠️ **新产物一个真缺陷（非回归、非阻断）**：`sim/p5wu/run_tb_app_wu.bat` 是 **UTF-8 带中文注释**（违反本工程 “bat 只 ASCII+CRLF” 纪律）⇒ 第 26 行被 cmd(GBK) 拆成命令执行，stdout 多出一行 `'TB' 不是内部或外部命令…`。EXIT 码不受影响 | 实测 + 最小复现 |

**一句话**：**没有发现任何由本次 `wu` 修复引入的回归**；5 个红色里 4 个是**既存红（且 3 个与历史基线读数逐数/逐字相同）**、1 个是**并发放大出来的 xsim 引擎崩溃（重跑即绿、且该门编译集不含 `app_ctrl.v`）**。

---

## 1. 新 TB（作者主交付）—— 绿

**命令**：`cmd //c 'sim\p5wu\run_tb_app_wu.bat'`　**EXIT=0**
**原始件**：`sim/p5wu_regress/wu_tb_stdout.log`（+ 工作目录 `sim/p5wu/run/{xsim_wu.log,xelab_wu.log,xvlog_wu.log}`）

- 判据行：`P7B WU GATE OK` → `P7B WU GATE PASS`；**`  PASS ` × 38 / `  FAIL ` × 0**。
- 主判据（可证伪性）：`P1f win never exactly 0` · `P2a reopened => 1 fire` · **`P2b OLD 0 fires (same stim.)`** ·
  `P2c notified val in [wq/2,+step]` · `P6d OLD fire#1 (arm alive)`；
  末行 `NEW notifications = 3 (expect 3) . OLD = 1 (expect 1 = P6 designed condition only)` +
  `lockstep violation cycles (must be 0) = 0` ⇒ “同一激励双跑”成立，旧臂 0 次是**模态**造成、不是实例坏了。
- 编译面：`xelab` 里两臂都真的例化了（`app_ctrl(FIN_TO_LIM=18'b01010)` 与 `app_ctrl(WU_LEGACY=1'b1,FIN_TO_L…)`）。
- 静态面：`xelab_wu.log` 无坑-24 签名（规范检测器 rc=0）；唯一 WARNING 是 `VRFC 10-3645 port 'full_next' remains unconnected`（**工程已实测的良性对偶**，见 CLAUDE.md 坑 24 的排除键表）。

⚠️ **同一门的一个新产物缺陷（见 §5）**：stdout 首行多一句 `'TB' 不是内部或外部命令…`（bat 编码问题）。

---

## 2. P4 矩阵（16 门，`sim\p4gates\run_matrix_p4dfix.bat`）

**命令**：`cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'`（isolated 模式，自定位）
**原始件**：`sim/p5wu_regress/matrix_stdout.log`（整份 stdout）·
`sim/p4sim/matrix_p4dfix.log`（矩阵自己的日志）· 逐门工作目录 `sim/p4gates/work_20261007_014439/<gate>/`

| 门 | EXIT | 主 stdout 关键行 | runme.log 一族关键行（该门工作目录） | 归属 |
|---|---|---|---|---|
| chain | 0 | `GATE chain EXIT=0` | `P4 CHAIN OK`（RX=9 TX=11 fast=6 slow=5 STRIPPED=0） | 绿 |
| burst200 | 0 | 同上 | `BURST OK` | 绿 |
| trunc50 | 0 | 同上 | `BURST OK` | 绿 |
| trunc100 | 0 | 同上 | `BURST OK` | 绿 |
| halfdrop | 0 | 同上 | `BURST OK` | 绿 |
| txdrop50 | 0 | 同上 | `BURST OK` | 绿 |
| gate4096 | 0 | 同上 | `BURST OK` | 绿 |
| **dupstorm** | **1** | `GATE dupstorm EXIT=1` | **`Simulation engine not responding` / `The simulator has terminated in an unexpected manner.`** + 检查器 `IndexError` | **环境性红（非可复现）→ 重跑绿**，见 §4.1 |
| pcackoob | 0 | 同上 | `BURST OK` | 绿 |
| vlanchain | 0 | 同上 | `P4 CHAIN OK`（STRIPPED=2 VLAN ON） | 绿 |
| vlanburst | 0 | 同上 | `BURST OK`（STRIPPED=202） | 绿 |
| stallgate | 0 | 同上 | `PCSTALL OK (burst=200, echo 帧 240)` | 绿 |
| unit_retx | 0 | 同上（⚠️ 该门**无条件 exit 0**，判据在日志尾） | `ALL 7 GROUPS PASS` | 绿 |
| unit_fifo | 0 | 同上（⚠️ 同上） | `PASS_ALL frame_fifo unit: writes A=… B=… C=… pops …` | 绿 |
| unit_vlan | 0 | 同上 | `VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)` | 绿 |
| unit_uart | 0 | 同上（已不是哑门） | `ALL_OK` + `UART-GATE-OK` | 绿 |

**整轮**：`gates run 16/16` · `gates failed: 1` · `MATRIX_EXIT=1`（因 dupstorm）。
**冻结检查**：`VERDICT: FROZEN -- all 237 hashed files byte-identical across the run`；
`BEFORE/ AFTER DIGEST_COMPILE=1dc184324e64374e9d8209588697ea0ab345bf8108c1a1a97b5209f06006d1b9 (201 files)`
· `DIGEST_ALL=eeda6b6a62efb39ac3039da63953e33a937ebda3d9aa9f408d5ceb198429299d`（before/after 逐字相同；
**HEAD 字段从 `ff78247` 变成 `09d2189` —— 但不参与判定，判据是纯内容**）。
⇒ 且**这两个摘要与上一轮已入库的矩阵日志逐字相同**（`git show HEAD:sim/p4sim/matrix_p4dfix.log` 存副本
`sim/p5wu_regress/baseline_matrix_prev_commit.log`）⇒ **本轮 P4 矩阵跑的就是上一轮全绿那套字节**。

**二次列扫描（防“只 grep 主 stdout”）**：工作树里 **124 份** `*.log`（含每门的 `xvlog*.log`/`xelab*.log`/`xsim*.log`/
`xsim.dir/*.log`/`_gate_console.log`）全部过了规范坑-24 检测器 ⇒ **0 命中**；
宽面 `^(ERROR|CRITICAL WARNING)|Simulation engine not responding|Command failed|Unable to remove previous` 扫描
⇒ **唯一命中就是 dupstorm 那次崩溃**（`sim/p5wu_regress/scan_logs_final.out`，全量 149 份日志 0 命中）。

---

## 3. P5 族门（作者自报集 + 我补的覆盖面）

**原始件**：每个门一份 `sim/p5wu_regress/<gate>_stdout.log`；编译/仿真日志在各门自己的工作目录。

| 门 | EXIT | 关键行（原始） | 归属 |
|---|---|---|---|
| `sim\p5d_multi\run_tb_p5_multi.bat main` | **0** | **`== P5d multi: 122 checks, 0 FAIL ==`** | 绿 ← **这就是“122/0 FAIL”的真身：122 项检查 / 0 项失败** |
| `sim\p5sim\run_tb_p5_fc.bat`（app_ctrl 直系单元门） | 0 | `P5 FC UNIT OK`（**110 条 PASS / 0 FAIL**，含 `T7: C6 wu` 全组 + `T1d wu_mark[0]=winq`） | 绿 |
| `sim\p5sim\run_tb_p5_app.bat` | 0 | `P5 APP OK`；`wu_mark0=c000`、`stat_wu=0`（健康态零额外帧） | 绿 |
| `sim\p5sim\run_tb_p5_status.bat` | 0 | `P5 STATUS OK` | 绿 |
| `sim\p5sim\run_tb_p5_flow.bat`（512KB 慢消费者闭环） | 0 | `P5 FLOW OK`；`wu_mark0=60e0`(=24800 ≥ winq/2) ⇒ **新逻辑在真实闭环里确实发过通告** | 绿 |
| `sim\p5sim\run_tb_p5_pattern.bat` | 0 | TB 自己的判据行 = `P5 PATTERN FAIL viol=0 last_beats=2 keep_bad=1 active=0`；⚠️ **该门 bat 只有 findstr、不置退出码（哑门）** | **既存**：基线（`P7B_REGRESSION.md` 行 19）**同一行、同 exit 0、同判 PASS** |
| `sim\p5sim\run_tb_p5_wrapper.bat` | **1** | `wrapper GMII: 0 帧 (conn0 收包 0 / 发帧 0 / 坏 FCS 0)` + `P5 WRAPPER FAIL (1 项)` | **既存红**（双跑 + 两份历史记录，见 §4.2） |
| `run_tb_p5_adv.bat {wnd,multi,accmgn,fin,findrop}` | 0×5 | `P5 ADV[wnd|multi|accmgn|fin|findrop] OK` | 绿 |
| `sim\p5e_udp\run_tb_app_udp.bat pos` | 0 | `P5E UDP APP GATE: OK (rx_frames=10 rx_bytes=13305 tx_frames=25 drop_len=1 drop_ovf=5 split=15 pat_bad=0)` | 绿（与基线件**逐字相同**，含全部数字） |
| `sim\p5e_t2\run_tb_p5e_t2_wrapper.bat` | **1** | `P5E-T2 WRAPPER GATE: FAIL errs=117` | **既存红**：errs **== 基线 117**（逐数相同） |
| `sim\p5e_udp\run_tb_p5e_udp_wrapper.bat` | **1** | `P5E-T5 UDP WRAPPER GATE: FAIL errs=1489` | **既存红**：errs **== 基线 1489**（逐数相同） |
| `sim\p5close\run_tb_tcp_close.bat` | 0 | `p5close gate summary: ALL PASS` | 绿 |
| `sim\p5d_d1\run_tb_p5d_d1.bat` | 0 | `P5D-D1 GATE PASS` | 绿 |
| `sim\p5e_win\run_tb_p5e_win.bat` | 0 | `P5E-WIN GATE PASS` | 绿 |
| `sim\p5sim\run_tb_p5_app.bat close` | **1** | `MISMATCH: rtl/tcp_tx_frame.v RTO_LIM=61035 != 期望值 48828` + `MISMATCH: rtl/app_ctrl.v FIN_TO_LIM=244141 != 期望值 195313` + `P5 CLOSE FAIL (2 项)` | **既存红**：基线（`P7B_REGRESSION.md` 行 173）**同一行同一 2 项**；两个常量是 **P6b ×1.25 遗留的检查器陈旧**，**本次 diff 对 `FIN_TO_LIM` 0 处改动** |

---

## 4. 红色的逐条归属

### 4.1 `dupstorm`（P4 矩阵唯一红）—— **环境性、非可复现、结构性无关**

**它是怎么红的（原始件 `sim/p4gates/work_20261007_014439/dupstorm/`）**：
```
xsim_run.log :  Command failed: Simulator command interrupted.
                Simulation engine not responding
                The simulator has terminated in an unexpected manner.
                run: Time (s): cpu = 00:00:00 ; elapsed = 00:02:27 . Memory (MB): peak = 243.551
_gate_console.log : (检查器崩在) IndexError: list index out of range
                    tools/gen_stim_p4_chain.py:518 parse_gmii
resp_p4_chain.memh : 末行 = `69`（**半行**，应有 "69 1"）⇒ 检查器 p[1] 越界
```
即：**xsim 引擎崩了**（不是 TB 判据 FAIL、不是 DUT 错），TB 写到一半的 `resp_p4_chain.memh` 被截断，
于是检查器 Python 抛 `IndexError`。对照：同轮其它 7 个同款 burst 门 elapsed 1:39–1:46，**只有它 2:27**。

**归属证据（三条，独立）**：
1. **重跑即绿**：同参数、同 bat、私有工作目录 `sim/p5wu_regress/dupstorm_rerun/`：
   `cmd //c 'sim\p5wu_regress\rerun_dupstorm.bat'`（= `run_tb_p4_burst.bat 200 0 0 4000 608 dup`）
   ⇒ **EXIT=0，尾行 `BURST OK`**（`sim/p5wu_regress/dupstorm_rerun_stdout.log`）。⇒ **非确定性**。
2. **结构性无关**：`rtl/app_ctrl.v` **根本不在 P4 矩阵的编译集里**（§6 的机械证明）⇒ 本修复**不可能**
   影响该门；连"H2H 双跑对照"都无意义（两臂的编译输入逐字节相同）。
3. **历史 + 摘要**：上一轮已入库矩阵 `gates failed: 0`，且两个 DIGEST 与本轮**逐字相同** ⇒ 同一套字节上
   该门曾全绿。
⚠️ 我没有“历史崩溃记录”可引（`Simulation engine not responding` 在本仓留存日志/笔记里**只有这一次**）；
所以严格措辞 = **“本轮一次性、不可复现的引擎崩溃；并发环境是唯一合理解释”**，而**不是**“已知老毛病”。

**环境侧的直接物证（时间上完全重叠）**：另一个 agent 在同一台机上跑 **Vivado 全设计实现**——
`board/p7b_ku5p_stdout.txt` 首行 `**** Start of session at: Wed Oct  7 01:50:57 2026`、
`board/p7b_ku5p_timing.rpt` 日期 `Wed Oct  7 02:18:27 2026` ⇒ **构建窗口 01:50:57–02:18:34**，
而我的矩阵是 **01:44:39–02:11:02**、dupstorm 的 xsim 末段是 **~01:58–02:00:39**（由 `elapsed 2:27` 反推）⇒ **崩溃正好发生在
“Vivado 实现 + 我的仿真 + 审查 agent 的仿真”三方抢机器的最拥挤窗口**（我起跑前的 `tasklist`
只有 1–3 个 `xsim.exe`，但无法列举 Vivado 的 slave 进程）。

### 4.2 `p5_wrapper`（EXIT=1）—— **既存红**（我做了 A/B 双跑）

**双跑设计**：把 `sim\p5sim\run_tb_p5_wrapper.bat` **逐字复制**成两份放进我的 scratch 目录，
**只改一个变量** = 编译哪个 `app_ctrl.v`（其余文件同一份工作区），并各自用独立工作目录：
- `sim/p5wu_regress/run_wrap_head.bat` → `sim/p5wu_regress/head_rtl/app_ctrl.v`（= `ff78247` 版，md5 `466304fc…`）
- `sim/p5wu_regress/run_wrap_new.bat`  → 仓内现行 `rtl/app_ctrl.v`（md5 `c8e00067…`，含修复）

**读数（逐字）**：
| 臂 | EXIT | stdout |
|---|---|---|
| head（修复前） | **1** | `wrapper GMII: 0 帧 (conn0 收包 0 / 发帧 0 / 坏 FCS 0)` · `MISMATCH: wrapper 只出了 0 个 conn0 数据帧 (<2) …` · `P5 WRAPPER FAIL (1 项)` |
| new（修复后） | **1** | **同上，逐字节相同** |
| 两份 stdout 的 md5 | `e042afb3ab402e547abfa83380868ff8` / `e042afb3ab402e547abfa83380868ff8` | **相同** |

**“只差 app_ctrl”这条前提我核过**：`git diff --stat ff78247 HEAD -- rtl/ tb/ board/ tools/ sim/` ⇒
**只有 3 个文件**（`rtl/app_ctrl.v` +86/−8、`tb/tb_app_wu.v`（新）、`sim/p5wu/run_tb_app_wu.bat`（新）），
其余改动全在 `_proj_10g/notes/`（笔记/脚本）与 `.gitignore` ⇒ 换 `app_ctrl.v` 即可把**本次改动**单独隔离出来。

**两条独立历史记录**（都在修复前）：
- `_proj_10g/notes/P7B_REGRESSION.md:99` —— `p5_wrapper | wrapper GMII: 0 帧 | **同红** | wrapper APP_MODE 全链在**基线上就已 0 帧**（自 P6b 起）`；
- `_proj_10g/notes/P7B_BIZ_REGRESSION.md:121` —— `p5_wrapper | wrapper GMII: 0 帧 | 既存`。
⇒ **既存红**，与本次修复无关（作者的同名结论**成立**，且我现在有同 harness 的双跑对照）。

### 4.3 其余三个红（我本轮新跑出来的，全部既是存红）
- `p5e_t2_wrapper` / `p5e_udp_wrapper`：**错误计数与历史基线逐数相同**（117 / 1489）——
  计数是最强的“无变化”判据：修复若动了任何一条 wrapper 侧路径，这两个数会变。**既存红**。
- `p5_app close`：两条 `MISMATCH` 都是**检查器对 P6b 常量的陈旧期望**（`RTO_LIM`/`FIN_TO_LIM`），
  与 `wu` 无关（本次 diff 对这些常量 0 改动）；基线表同行同判定。**既存红**。
- `p5_pattern`：TB 自报 `P5 PATTERN FAIL … keep_bad=1`，但门是**哑门**（findstr-only、恒 exit 0）。
  基线同一行 ⇒ **既存**（⚠️ 这条值得单独立账：**TB 判据红被哑门吞掉**）。

---

## 5. 新产物缺陷（非回归）：`run_tb_app_wu.bat` 是 UTF-8 带中文注释

**症状**：该门 stdout 首行多出一句
`'TB' 不是内部或外部命令，也不是可运行的程序 / 或批处理文件。`（EXIT 仍 0，判据行正常）。

**定位（有最小复现）**：`cmd //c 'sim\p5wu\regress\probe_head.bat'`（我复制的该 bat 头部 34 行 + `@echo on`）：

```
>REM           设计工况 (occ>=winq => wscan==0) 下 两臂各发 1 次 (两臂都活着)。   ← L25
>TB 内部逐项 PASS/FAIL + 末行 "P7B WU GATE OK" / "P7B WU GATE FAIL n"           ← L26，`REM ` 被吃掉
'TB' 不是内部或外部命令…                                                          ← cmd 把 L26 当命令执行
```

**根因**：该 bat 是 **UTF-8**（`raw.decode('utf-8')` 成功，8 行含非 ASCII；52 行全 CRLF）。
在 **GBK 控制台**下 cmd 按字节解析，L25 行尾 `。`（UTF-8 `E3 80 82`）与 L26 行首的字节对成了别的字节
⇒ **L26 的 `REM` 前缀被吞**，`TB 内部逐项 …` 被当命令执行。这**正是**用户全局指令里那条
“**bat 只 ASCII+CRLF / 注释禁 UTF-8 中文**”纪律的教科书案例。
**影响面**：仅一行 stderr/console 噪声，**不改退出码、不改任何判据**（后面的 `call`/`findstr` 会重设 ERRORLEVEL）。
**建议**：把 8 行中文 REM 改成 ASCII（或 GBK），与全仓其余门一致。
**注**：该缺陷**不在** `rtl/app_ctrl.v` 修复的责任面内（是新增门 bat 的编码），故**不计入回归**，
但作为“新交付物的缺陷”登记在此。

---

## 6. 作者对 P4 取舍的说法 —— **我自己核过：成立**（证据比作者给的更全）

作者原话：“`tb_p4_chain.v` 与 `sim/p4sim|p4gates` 的编译清单**都不含 `app_ctrl`**（默认构建不例化它）”。
我的机械核对（全部 0 命中）：

1. **5 份清单全 0**：`grep -c app_ctrl sim/p4gates/*_src.f` ⇒ `chain_src.f/fifo_src.f/retx_src.f/uart_src.f/vlan_src.f` 全 `0`
  （`chain_src.f` 逐行列出 20 个文件 = 19 rtl + `tb/tb_p4_chain.v`，无 `app_ctrl.v`）。
2. **18 份 p4sim 批处理全 0**：`grep -c app_ctrl sim/p4sim/*.bat` ⇒ 全 `0`。
3. **运行器与守卫全 0**：`run_matrix_p4dfix.bat` / `p4env.bat` / `p4gate.py` 全 `0`。
4. **编译集里也没有间接引用**：对 `chain_src.f` 的 20 个文件 `grep -i app_ctrl` 只命中 3 处 ——
   `rtl/tcb.v:46,116`、`rtl/tcp_tx_frame.v:42,62,65,68,69,73,366,380,411,654,717,719`、`rtl/slow_cfg_adp.v:42`
   —— **逐条查证全部是注释**（“app_ctrl 轮扫专用”“app_ctrl 用”“app_ctrl 产生”…），**没有任何例化/端口引用**；
   且这 20 个文件里 **`` `include `` 指令数 = 0**。
5. **HLS 网表也不含**：`grep -rli app_ctrl hls/slowstack_prj/solution1/syn/verilog/` ⇒ 0。
6. **连矩阵指纹都不哈希它**：`P4_MATRIX_FINGERPRINT_20261007_014439_before.txt` 里 `app_ctrl` 命中 **0**
   （201 个编译文件 + 36 个生成器/判据 = 237，无 `rtl/app_ctrl.v`）。
⇒ **矩阵对本次改动结构性不可感**；`dupstorm` 的红**不可能**由本修复引起（§4.1-2）。

---

## 7. 我没能测的（如实登记）

1. **板级一切**：零烧板、零位流、零 `J6`/`J15` —— “上行从 4.7 Mbps 回去”仍是**推断**（与作者 §7-1 同）。
2. **全设计构建/时序**：没跑 `run_build_p7b_ku5p.bat`，因而**没有**新的 `WNS/WHS/失败端点`读数
   （`gatecheck.sh` 那套三条硬门 + 各 run 的 `runme.log` 也未扫）⇒ 作者 §7-2 的“下一轮必须重跑构建”**仍欠着**。
3. **未跑的仿真门**（都存在，只是不在我这一轮的门集）：
   `p5c_t3`（rev wrapper elab）· `p5d_multi neg_wq/neg_mgn/neg_mgn0`（**期望非零**的负对照）·
   `p5e_udp {splitoff,portout,badcrc,nopeer,neglearn}` · `p5e_t2_guard` · `p5_adv {len,b2b,abort,evfifo,reconn_fast,reconn_slow}` ·
   `run_probe` / `p4_replay` / `rxclass(_xk)` / `slowrx` / `slowtx` / `txarb`（P4 矩阵之外的门）。
4. **方法学边界**：`dupstorm` 的“环境性”判定基于**一次重跑 + 结构性无关**；我没有在纯静默台架上跑第三遍
   （并发 agent 全程在跑，无法制造纯静默窗口）。若后续有人能制造静默窗口，值得再复一遍。
5. **P5 族的负对照组**没有系统重跑（作者自报集里也不含）。

---

## 8. 逐字命令（我实际跑的）

```bash
# --- 新 TB ---
cmd //c 'sim\p5wu\run_tb_app_wu.bat'                       # > sim/p5wu_regress/wu_tb_stdout.log
# --- P4 矩阵（前台等 25min；起于 01:44:39，终于 02:11:02）---
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                # > sim/p5wu_regress/matrix_stdout.log
# --- 参照件抽取（修复前 app_ctrl）---
git show ff78247:rtl/app_ctrl.v > sim/p5wu_regress/head_rtl/app_ctrl.v   # md5 466304fc…（WU_LEGACY 0 次）
git show HEAD:sim/p4sim/matrix_p4dfix.log > sim/p5wu_regress/baseline_matrix_prev_commit.log
# --- p5_wrapper A/B（自建两份只差 app_ctrl 的 bat；生成器 = sim/p5wu_regress/mk_wrap_ab.py）---
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_regress/mk_wrap_ab.py
cmd //c 'sim\p5wu_regress\run_wrap_head.bat'               # EXIT=1
cmd //c 'sim\p5wu_regress\run_wrap_new.bat'                # EXIT=1（两份 stdout md5 相同）
# --- dupstorm 重跑（复刻矩阵的同参数调用，私有工作目录；生成器 = mk_rerun_dupstorm.py）---
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_regress/mk_rerun_dupstorm.py
cmd //c 'sim\p5wu_regress\rerun_dupstorm.bat'              # EXIT=0 / BURST OK
# --- P5 族 ---
cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat main'           # EXIT=0 / 122 checks, 0 FAIL
cmd //c 'sim\p5sim\run_tb_p5_fc.bat'                       # EXIT=0 / 110 PASS
cmd //c 'sim\p5sim\run_tb_p5_app.bat'                      # EXIT=0
cmd //c 'sim\p5sim\run_tb_p5_status.bat'                   # EXIT=0
cmd //c 'sim\p5sim\run_tb_p5_flow.bat'                     # EXIT=0
cmd //c 'sim\p5sim\run_tb_p5_pattern.bat'                  # EXIT=0（TB 判据行 FAIL，哑门）
cmd //c 'sim\p5sim\run_tb_p5_wrapper.bat'                  # EXIT=1（既存红）
cmd //c 'sim\p5sim\run_tb_p5_adv.bat' {wnd,multi,accmgn,fin,findrop}   # EXIT=0 ×5
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat pos'               # EXIT=0
cmd //c 'sim\p5e_t2\run_tb_p5e_t2_wrapper.bat'             # EXIT=1 / errs=117   （基线 117）
cmd //c 'sim\p5e_udp\run_tb_p5e_udp_wrapper.bat'           # EXIT=1 / errs=1489  （基线 1489）
cmd //c 'sim\p5close\run_tb_tcp_close.bat'                 # EXIT=0
cmd //c 'sim\p5d_d1\run_tb_p5d_d1.bat'                     # EXIT=0
cmd //c 'sim\p5e_win\run_tb_p5e_win.bat'                   # EXIT=0
cmd //c 'sim\p5sim\run_tb_p5_app.bat' close                # EXIT=1（既存红）
# --- 静态面：规范坑-24 检测器铺满（生成器 = sim/p5wu_regress/mk_scan.py）---
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_regress/mk_scan.py
cmd //c 'sim\p5wu_regress\scan_logs.bat'                   # 149 份日志 → 149 OK / 0 FAIL（sim/p5wu_regress/scan_logs_final.out）
# --- 诊断（stray cmd 错误那一行）---
cmd //c 'sim\p5wu_regress\probe_trace.bat'                 # @echo on 复现：L26 的 REM 被吃 ⇒ 'TB' 当命令执行
cmd //c 'sim\p5wu_regress\probe_head.bat'                  # 最小复现（截取新 bat 头部 34 行 + echo）
```

**证据目录**：`sim/p5wu_regress/`（我的独占目录）—— `matrix_stdout.log` · `wu_tb_stdout.log` ·
`p5_*_stdout.log` · `dupstorm_rerun_stdout.log` · `scan_logs_final.out` · `baseline_matrix_prev_commit.log` ·
`wraphead/`·`wrapnew/`（A/B 工作目录）· 三个生成器 `.py` 与它们产出的 `.bat`。
