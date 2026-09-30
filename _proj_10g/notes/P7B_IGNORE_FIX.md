# P7b 收尾：门修复的入库放行 + 回归 harness 指针订正（2026-09-30）

> 对应 `P7B_GATE_HARNESS_FIX.md` §4 的两条"越出该任务文件所有权的账"（①②）。
> 本文件只记录**证据与判据**；改动只有两处：`.gitignore`（放行规则）与
> `_proj_10g/notes/p7b_regression/run_all_gates.py`（一条门表指针）。
> **未改任何 RTL / TB / 门脚本内容；未 `git add` / `commit`。**

## 0. 一句话

`sim/p4indm/` 与 `sim/p5c_t3/rev/` 里**本轮的 3 个修复件**（+ 2 个同族的既有现役门件）已在
`.gitignore` **末尾**放行并 `check-ignore -q` 实测通过（同目录产物 10/10 负对照仍被忽略）；
`run_all_gates.py` 的 `p4indm_4gates` 条目由 `.sh` 改指 `.bat`，**该条目实跑 EXIT=0 / 394.4 s**
（改前实测 0.1 s = 哑门）。

---

## 1. 哪些文件是"本轮的修复产物"（自己核实，未照抄任务描述）

判据 = ① 回归 harness 的**现役门表**（`run_all_gates.py` 的 `G`）；② 文件 mtime 落在
本轮时间窗（2026-09-30 13:00 之后）；③ `git status --ignored` 的排除状态。

| # | 文件 | mtime | 依据 |
|---|---|---|---|
| 1 | `sim/p4indm/run_4gates.bat` | 09-30 14:09 | **本轮新建**。委托入口（`-only pcackoob+vlanchain+vlanburst+stallgate` 交给 `sim/p4gates/run_matrix_p4dfix.bat`，继承其守卫与退出码） |
| 2 | `sim/p4indm/run_4gates.sh` | 09-30 13:58 | **本轮改薄 shim**（原来它自己就是门，且是 cmd 语法串进 bash 的真空门） |
| 3 | `sim/p5c_t3/rev/run_wrapper_elab_chk.bat` | 09-30 13:57 | **本轮修好**（补 `udp_tx_cfg.v`/`udp_tx_frame.v` 两件 + ERROR 硬判据）；harness 条目 `p5c_rev_elab`(:69) 就指向它 |

⚠️ **任务描述里说"该 agent 改了 `p5c_rev_elab` 相关的东西"，核实结果就是上表第 3 行这一个文件**；
`sim/p5c_t3/` **根目录**下的 `run_tb_p5c_fence.bat` / `tb_p5c_fence.v` **不是**本轮的（mtime 09-29/09-20），
且**已入库**（`git ls-files` 可见），未被忽略 —— 无需放行。
`sim/p5c_t3/rev/` 里的 `wchk/`（`xe_a.log`/`xv_a.log`/…）是**产物**，未放行（见 §3 负对照）。

**额外放行的 2 个（超出"本轮修复"字面范围，理由与证据如下，可一行回退）**：

| # | 文件 | 理由 |
|---|---|---|
| 4 | `sim/p5c_t3/rev/run_tb_rev_g2g3.bat` | harness 的**现役**条目 `p5c_rev_g2g3`(:68) 指向它，而它在新 clone 里**取不到** —— 与本工程既有事故"**现役入口从未被 git 看见**"完全同族（`.gitignore` 第 137–144 行 `sim/retxsim*` 那条注释就是为同类事故写的） |
| 5 | `sim/p5c_t3/rev/tb_rev_g2g3.v` | 上一条门的 **TB 源码**（与 `sim/p5c_t3/tb_p5c_fence.v` 同性质，后者已入库） |

**未放行**（刻意）：`sim/p4indm/run_matrix_ind.sh`（无任何引用、非 harness 条目；且见 §5 第 1 条 —— 它的**活行**指向另一个 checkout，不该进库）。

## 2. 放行结果（`git check-ignore -q` 实测，**只用 `-q`**）

```
rc=1 sim/p4indm/run_4gates.bat                       <- 1 = 不再被忽略
rc=1 sim/p4indm/run_4gates.sh
rc=1 sim/p5c_t3/rev/run_wrapper_elab_chk.bat
rc=1 sim/p5c_t3/rev/run_tb_rev_g2g3.bat
rc=1 sim/p5c_t3/rev/tb_rev_g2g3.v
```
（放行**前**同样命令这 5 条全是 `rc=0`。⚠️ `check-ignore -v` 在 `!` 行上的退出码不可信，
本工程踩过 —— 所以只用 `-q`。）

`git ls-files --others --exclude-standard -- sim/p4indm sim/p5c_t3`（= 放行后会被 git 看见的**未跟踪文件全集**）
恰好就是上面这 5 条，**无第六个**；`git status --short -uall` 同样只列这 5 条。

## 3. `.gitignore` 的两处改动 + **位置证据**

规则加在**文件末尾**（gitignore = 最后匹配者胜）：

```
 606  # ⚠️⚠️ 位置敏感: 本节规则**必须留在 .gitignore 的末尾**
 ...
 622  !sim/p4indm/run_4gates.bat
 623  !sim/p4indm/run_4gates.sh
 629  !sim/p5c_t3/rev/
 630  sim/p5c_t3/rev/*
 631  !sim/p5c_t3/rev/run_wrapper_elab_chk.bat
 635  !sim/p5c_t3/rev/run_tb_rev_g2g3.bat
 636  !sim/p5c_t3/rev/tb_rev_g2g3.v
```
文件总行数 **636** ⇒ 最后一条放行规则就是**最后一行**。

另一处（**必须**改，否则任何 `!` 都无效）：第 135 行 `sim/p4indm/` → 第 **137** 行 `sim/p4indm/*`。
理由 = **整目录排除时 git 根本不下降进去**，写在别处的 `!` 一律静默无效（同 `sim/retxsim*` 的先例，
`.gitignore` 第 137–144 行已有逐字记载）；`sim/p4indm/*` 对**产物**的排除效果与原来逐项相同。
`sim/p5c_t3/rev/` 同理：它的父目录被靠上的 `sim/p5c_*/*` 整目录排除 ⇒ 用的是
"先放行目录本身 → 再重新排除其内容 → 再逐类放行"三步（同 `p5diag_verify` 的先例）。

**负对照（10 条，全部仍应被忽略 ⇒ 实测 `rc=0`）**：`matrix_4gates.log` · `matrix_ind.log` ·
`run_matrix_ind.sh` · `gates4_console.txt` · `wchk/xe_a.log` · `wchk/xvlog.log` ·
`rev_run_out.log` · `xelab.pb` · `xsim.dir` · `xvlog_fence.log` ⇒ **10/10 = 0**。

### 3.1 被覆盖掉的一处旧证据（已在此逐字留档）

`run_all_gates.py` 的门日志是**按门名覆盖**的，本轮实跑必然覆盖
`logs/p4indm_4gates.log`。**改前**该文件逐字为（205 B，即"哑门"的原始物证）：

```
# gate   : p4indm_4gates
# bat    : sim\p4indm\run_4gates.sh
# args   : []
# expect : exit 0
# desc   : P4 独立 4 门(sh)
# started: 2026-09-30 13:18:57

# ===== runner: EXIT=0  0.1s   =====
```
（该读数在 `P7B_REGRESSION.md` / `P7B_GATE_HARNESS_FIX.md` §3 反例 D 里另有记载。）
覆盖后同文件记录的是**修后**状态，避免"日志仍显示 `.sh`"这一误导。

## 4. harness 指针订正 + **实跑**

`_proj_10g/notes/p7b_regression/run_all_gates.py`：

```python
# 改前: ('p4indm_4gates', r'sim\p4indm\run_4gates.sh',  [], '0', 'P4 独立 4 门(sh)', 2400),
# 改后: ('p4indm_4gates', r'sim\p4indm\run_4gates.bat', [], '0', 'P4 独立 4 门(bat 委托矩阵 runner)', 2400),
```
（同处加了一行注释说明"runner 用 `cmd /c <bat>` ⇒ 不能是 `.sh`"，防止后人改回去。）

**权威入口的判定**（任务要求先确认）：`sim/p4gates/run_matrix_p4dfix.bat` 是 **Windows 侧真 runner**
（16 门 + `checkpaths`/`manifestcheck`/`scanlog` + 修订指纹都在它里面）；`sim/p4sim/run_matrix_p4dfix.sh`
只是它的 **git-bash 薄 shim**（文件头逐字："the real runner is a .bat…"）。harness 的 `p4_matrix16`
条目(:35) 用的也正是那个 `.bat` ⇒ 改指 `run_4gates.bat`（它再委托给权威 runner）与现役口径一致。

**实跑**（`run_one` 用 `subprocess.run(['cmd','/c',bat_abs], cwd=ROOT)`）：

```
python _proj_10g/notes/p7b_regression/run_all_gates.py --only p4indm_4gates
  -> HARNESS EXIT=0
```
门日志 `logs/p4indm_4gates.log` 关键行：

```
# bat    : sim\p4indm\run_4gates.bat
# started: 2026-09-30 14:13:36
GATE pcackoob   EXIT=0
GATE vlanchain  EXIT=0
GATE vlanburst  EXIT=0
GATE stallgate  EXIT=0
（其余 12 门 SKIPPED -- not selected）
[P4INDM 4GATES] gate=pcackoob+vlanchain+vlanburst+stallgate exit=0
# ===== runner: EXIT=0  394.4s   =====
```
**394.4 s vs 改前 0.1 s** —— 这就是"真跑了"的判别性证据（同样的判据、同样的容器）。
语法核对：`ast.parse` OK；`--list` 打印出的即 `sim\p4indm\run_4gates.bat`。

本轮实跑同时留下修订指纹一对（矩阵 runner 自动写，规则本就放行该族）：
`sim/p4sim/P4_MATRIX_FINGERPRINT_20260930_141338_{before,after}.txt` ——
**除时间戳外零差异 = 无 DRIFT**（`git HEAD f86b07f`，237 文件参与哈希，3 个 vs HEAD 已修改的
tracked 文件即上一轮修的三条门脚本）⇒ 上面那组 EXIT=0 **绑定单一修订**，不是"跑动期间源码被改"。

## 5. 发现但**没动手**的（越出本任务所有权 / 属门脚本内容）

1. ⚠️ **`sim/p4indm/run_matrix_ind.sh:41–44` 四条"活行"指向另一个 checkout**：
   `cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\retxsim\\run_retx_tb.bat"` 等 —— 这正是"**真空门**"
   （跑起来编译别人的树、日志写进别人的仓、还 exit 0）的字面形态。该脚本**已无人引用**
   （被 `sim/p4gates/run_matrix_p4dfix.bat` 取代），本轮**未放行**它（继续留在 git 视野外）。
   **建议**：删除或改路径 —— 由后续所有权决定。
2. `sim/p5c_t3/rev/run_wrapper_elab_chk.bat:26` 的 **REM 行**仍写着
   `Usage: cmd //c "D:\repo\ECO\udp_hls_10g\sim\p5c_t3\rev\run_wrapper_elab_chk.bat"` ——
   **只是注释、不执行**，且该 bat 自身是自定位 + `p4gate.py selfcheck` 守卫（所以不构成真空门），
   但字面残留另一个 checkout 路径，**建议**顺手改成相对路径。本任务禁改门脚本内容 ⇒ 只报告。

---

**结论**：本轮的 3 个修复件（+2 个同族现役门件）现在**确实能被 git 看见**（`-q` 实测 5/5，
产物负对照 10/10）；harness 的过时指针已改并**实跑 EXIT=0**（394.4 s，4 门全过）。
两项均只改了两处允许改的文件，未碰 RTL/TB/门脚本，未 `add`/`commit`。
