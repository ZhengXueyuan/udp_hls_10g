# P7B 隐式网门 —— 铺开（rollout）+ 语料级假阳性验证

- 日期：2026-09-29 · 器件 `xcku5p-ffvb676-1-e` · 工具 **Vivado 2025.2**（`C:\AMDDesignTools\2025.2`）
- 前置（必读）：`_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` —— 缺陷本体、2025.2 真实报错文本、单元级九项对照
- 本轮的施工/取证目录：`_proj_10g/notes/p7b_rollout/`（脚本、原始日志、逐次读数）
- **纪律声明**：**未改任何 RTL / XDC 设计文件**；未烧板、未碰板载 QSPI；未动 license 文件；未碰 `D:\repo\perfv`；
  **未执行任何 git 写操作**（只用了只读的 `git status` / `git diff` / `git show` / `git check-ignore` / `git ls-files`）。

### 证据强度标记

| 标记 | 含义 |
|---|---|
| 【实测】 | 本机原始输出，本文件给逐字原文 / 退出码 / 日志路径 |
| 【工具读数】 | 报告/日志的机器可读读数字段 |
| 【自算】 | 本文件独立复算 |
| 【推定】 | 逻辑推理 + 强证据，但**没有**直接跑过 |
| 【未核实】 | 不知道。**不得当判据用** |

---

## 0. 一句话结论

**前置轮把"关键字修好了"，但没解决覆盖面、也没做语料级验证；本轮两件都做了，并且语料级验证当场抓出一条假阳性（必须收窄）与一条真阳性（新门首捕）。**

1. **收窄**：前置轮落地的 5 键表里，`VRFC 10-3091` **裸键过宽** —— 语料实测命中 `board/util_gmii_to_rgmii.v` 的 **14 处良性 unsized 字面量**（`.CE(1)` / `.D1(1)` / `.D2(0)` / `.R(0)` / `.S(0)`，报 `actual bit length 32 differs from formal bit length 1`），且该文件在**默认 (K7) 配置下每次 elaborate 都报** ⇒ 当硬失败就是天天误伤。已把该键**逐处收窄**为 `VRFC 10-3091] actual bit length 1 differs from formal bit length`（隐式网**必然是 1 位**，这就是本坑的精确签名），**87 个文件 / 261 处**，**0 个文件仍持有裸键**。
2. **补面**：**6 个门只跑 xvlog** ⇒ 对坑 24 的端口连接形式**换任何关键字都抓不到**。其中 **4 个已补上 xelab 面并用真实运行见证**（含两处现役 lint 入口 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat`）；1 个**补了又回退**（该门自身先坏了，见 §3.5）；1 个**未修**（被 `.gitignore` 排除的一次性目录）。
3. **`.gitignore`**：`sim/retxsim2/run_tb_frame_fifo.bat`（现役 16 门里的 `unit_fifo`）被排除的**根因不是"忘了加否定行"，而是规则形状错了** —— `sim/retxsim*/` 是**目录排除型**，`!` 否定行**永远救不回来**。已改为 `sim/retxsim*/*` + `!sim/retxsim*/run_tb_*.bat`，**实测只放行这 1 个文件**，产物仍全部忽略。
4. **新门有牙（真阳性首捕）**：收窄后的门在真实 TB 上抓到**一条真的坑 24** —— `tb/tb_p5_app.v:511` 用**从未声明**的 `tx_fsm_state_w`（隐式 1 位）驱动 3 位端口 `dbg_state`，同文件 992 行又用它读 `.fsm_state(...)`。这不是假阳性，是**此前不可见的真实截断**。
5. **新发现两条"从未触发过"的门**：① 裸 `findstr /C:"10-3091"` 在 **869 份 xvlog 日志里 0 命中** ⇒ 凡 grep xvlog 日志的"位宽不符"判定**结构性常哑**；② `VRFC 10-2989` 全仓真实命中 = **1**（就是冻结的病理件本身）。

---

## 1. 铺开 1：键表收窄（本轮最核心的一处，也是唯一一处语义修改）

### 1.1 假阳性的发现路径

`_proj_10g/notes/p7b_rollout/corpus_scan2.py` / `final_scan.py`：全仓 `.log` / `.txt` / `.rpt` 语料 **8109 份 / 582,471,670 字节**，
用 5 键逐份扫，把每一处的"被指责源文件"抽出来分类。

命中里有 **172 份文件**含 `VRFC 10-3091`，逐个定性后分成两类：

| 类 | 报文 | 被指责源 | 定性 |
|---|---|---|---|
| **A（良性，假阳性）** | `actual bit length 32 differs from formal bit length 1 for port 'CE'` | `board/util_gmii_to_rgmii.v` ×14 行 | **假阳性** —— 是 `.CE(1)` / `.R(0)` / `.S(0)` 这类 **unsized 字面量喂 1 位端口**，值不丢失 |
| B（真） | `actual bit length 1 differs from formal bit length 64 for port 'q'` | `_proj_10g/notes/p7b_implicit_repro/A1_portconn.v` ×2 | **真阳性** —— 冻结病理件本身 |

### 1.2 A 类的行号**逐字对上我们的文件**（这是"不是陈旧日志的错觉"的关键）

```
188   .CE(1),        189   .D1(1),       190   .D2(0),       192   .S(0));
203   .CE(1),        207   .S(0));       216   .CE(1),       220   .S(0));
232   .CE(1),        234   .R(0),        235   .S(0));       245   .CE(1),
247   .R(0),         248   .S(0));
```
（`board/util_gmii_to_rgmii.v`，本仓文件；与日志报的行号 **1:1 全中** ⇒ 【实测】）

### 1.3 收窄前后的**成对负对照**（同一条日志上 A/B 两次，`_proj_10g/notes/p7b_rollout/ctrl_3091.bat`）

| 输入 | 裸键 `VRFC 10-3091` | 收窄键 `...] actual bit length 1 differs ...` |
|---|---|---|
| 病理件 `log_a_A1_xelab_10-3091.log.txt`（应 FAIL） | HIT | **HIT**（真阳性仍抓住） |
| 真实设计 `sim/p5e_t2/xelab_wh.log`（应 PASS） | **HIT ×14**（假阳性） | **CLEAN** |

### 1.4 真实门自己的日志上再证一次（**本仓、今天、门刚跑出来的**）

| 日志 | 配置 | 快照已建 | 裸键 | 收窄键 |
|---|---|---|---|---|
| `sim/p6b_lint/xelab_lint.log` | PCIE_OBS+DEV_USP+APP_MODE+DP_156MHZ | 是 | 0 | 0 |
| **`sim/p6b_lint/xelab_def.log`** | **默认 (K7)** | 是 | **14** | **0** |

⇒ 收窄后的键在真实生产日志上**零假阳性**，且**仍抓得住病理件**。这就是任务书要的"收窄后仍能抓住真阳性"。

### 1.5 改动方式与量

- **逐处 replace，不整文件重写**：`_proj_10g/notes/p7b_rollout/narrow_3091.py`，**字节级**替换，
  逐文件断言 ① 非 ASCII 字节集合不变 ② `.bat` 行尾风格未被破坏（CRLF 文件 CRLF 数 == LF 数）。
- 台账：`_proj_10g/notes/p7b_rollout/logs/narrow_3091_log.txt`（逐文件 occurrences）。
- **收窄后：87 个文件 / 261 处**；**裸键剩余 0 个文件**（`gather.py` 读数）。
- 一次性脚本自身（`_proj_10g/notes/p7b_rollout/narrow_3091.py`）与前置轮的补丁脚本
  `_proj_10g/notes/p7b_implicit_repro/{fix_gates.py,fs_semantics.bat}` 仍含裸键 —— 它们是**历史补丁记录**，按前置报告 §5.3 的既有理由**有意不改**。

### 1.6 规范检测器同步

`sim/p4gates/implicit_gate.bat` 的 `set KEYS=` 已同步收窄（第 41 行），表头新增 12 行说明（收窄理由 + 新排除键 `VRFC 10-3645`）。
**九项自测重跑仍 `PASS_ALL`（exit 0）** —— 单元级回归见证。

---

## 2. 【清单】只跑 xvlog 的门（**问题不是关键字，是覆盖面**）

口径：扫描全仓 `.bat`（排除 `Demo/`、`xsim.dir`、`.Xil`、施工目录），取"含新键表"且"**只调 `xvlog.bat`、不调 `xelab.bat` / `synth_design`**"者。

| # | 门 | 处置 | 见证 |
|---|---|---|---|
| 1 | **`board/run_lint_p6e.bat`**（现役 lint 入口） | **已修**：+xelab 面（`xdma_0_sim_stub.v` + `glbl.v` + `-L unisims_ver`） | 见 §3.1 |
| 2 | **`_proj_10g/tcl/run_lint_p7a.bat`**（现役 lint 入口） | **已修**：+xelab 面（gt_10gbr 的 synth+hdl 源 + `vio_p7a_stub.v` + `-L unisims_ver -L secureip`） | 见 §3.2 |
| 3 | `sim/p6b_lint/lint.bat` | **已修**：+xelab 面（同上 stub 配方） | 见 §3.3 |
| 4 | `sim/p6b_lint/lint_def.bat` | **已修**：+xelab 面（默认配置，无需 stub） | 见 §3.3 |
| 5 | `sim/p6a_ku5p/pf/run_preflight.bat` | **补了又回退**（该门 xvlog 阶段自身就坏了，见 §3.5） | —— |
| 6 | `sim/snapcdc/review24/lint/run.bat` | **未修**：`.gitignore:302` = `sim/snapcdc/review24/`（**目录排除型**，同 §4 的病）+ 一次性复核目录 | `git check-ignore` 读数 |

**另有 3 个"连日志都不落盘"的门结构性无法承载判据**（前置报告 §4.3 已登记，本轮复核仍在）：
`sim/p4sim/run_tb_rxclass.bat` / `run_tb_rxclass_xk.bat` / `run_tb_slowrx.bat` —— 它们 `call ... xvlog.bat ...` **无重定向**，
**没有任何日志可 grep**。要修得先给它们加日志重定向（改门的 I/O 结构）。**这 3 个门都不在现役 16 门矩阵里**。

---

## 3. 逐门改动与运行见证

### 3.1 `board/run_lint_p6e.bat`（现役）

改动（`_proj_10g/notes/p7b_rollout/fix_p6e_xelab.py`，字节级行插入，**+16/-2**）：

```
 23| + echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                >> files.f
 24| ~ call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_p6e.log 2>&1
     （原为不带 -work；改成 xil_defaultlib 以便与 xelab 的库名一致）
 29| + REM
 30| + REM ---- xelab face (P7B): the PORT-CONNECTION form of trap 24 prints NOTHING in
 31| + REM   xvlog (exit 0, empty log) -- xelab is the only detector for it.  xdma_0 is a
 32| + REM   Block-Design module with no RTL on disk, so the same sim stub the P6e gate
 33| + REM   uses is compiled in.  Measured ~12 s end to end (run_matrix is unaffected).
 34| + call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_p6e.log 2>&1
 35| + call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lint_p6e -log xelab_p6e.log > NUL 2>&1
 36| + if errorlevel 1 (echo XELAB-FAIL & type xelab_p6e.log & exit /b 1)
 37| + REM   positive evidence: an empty/absent xelab log must NOT read as clean
 38| + findstr /C:"Built simulation snapshot" xelab_p6e.log >NUL || (echo XELAB-NO-SNAPSHOT & type xelab_p6e.log & exit /b 1)
 39| + findstr <5 键(收窄)> xelab_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr ... & exit /b 1)
```

第 37-38 行是**正证据**：本案的历史缺陷就是"没跑 / 跑了空"与"跑了且干净"读数相同（潜伏设计债的通用形态），
所以把"快照必须建出来"做成硬失败。

**运行（`_proj_10g/notes/p7b_rollout/logs/run_lint_p6e_after.txt`）**：

```
GATE_EXIT=0        实测 11.5 s（原 xvlog-only 约 2 s）
---- xvlog exit=0 ----
LINT-OK: no implicit nets, no width mismatch, no errors
```
产物：`board/lint_p6e/xvlog_p6e.log` **434 行**；`xelab_p6e.log` **265 行**，含
`Built simulation snapshot lint_p6e`；收窄键命中 **0**；`10-3091` 任何形态命中 **0**。

### 3.2 `_proj_10g/tcl/run_lint_p7a.bat`（现役）

改动（`fix_p7a_xelab.py`，**+31/-4**）：

```
 19| + REM ---- P7B: the IP sources p7a_top.v needs in order to ELABORATE ----
 21| + REM   vio_p7a   = the synthesis STUB (the VIO core is not delivered as RTL)
 22| + set IP=%~dp0..\vivado_prj\p7a_prj.gen\sources_1\ip
 23| + set GTHDL=%IP%\gt_10gbr\hdl
 27| + REM   the xelab face needs the generated IP; refuse (97) rather than pass blind
 28| + if not exist "%IP%\gt_10gbr\hdl\gtwizard_ultrascale_v1_7_gtwiz_reset.v" (... exit /b 97)
 29| + if not exist "%IP%\vio_p7a\vio_p7a_stub.v" (... exit /b 97)
 33| ~ del /q files.f xvlog.txt xelab.txt >nul 2>&1            （原只删前两个）
 37| + dir /b /s "%IP%\gt_10gbr\synth\*.v" >> files.f
 38| + dir /b /s "%GTHDL%\*.v" >> files.f
 39| + echo %IP%\vio_p7a\vio_p7a_stub.v >> files.f
 43| ~ call %XV%\xvlog.bat -work xil_defaultlib -i %RTL% -f files.f > xvlog.txt 2>&1   （原不带 -work）
 48| + REM ---- xelab face (P7B): ... Measured ~23 s.  vio_p7a_stub.v is a black box ...
 53| + call %XV%\xvlog.bat -work xil_defaultlib -i "%GTHDL%" "%XV%\..\data\verilog\src\glbl.v" >> xvlog.txt 2>&1
 54| + call %XV%\xelab.bat -debug typical -L unisims_ver -L secureip xil_defaultlib.p7a_top xil_defaultlib.glbl -s lint_p7a -log xelab.txt > NUL 2>&1
 55| + if errorlevel 1 (echo XELAB-FAIL & type xelab.txt & exit /b 1)
 57| + findstr /C:"Built simulation snapshot" xelab.txt >NUL || (echo XELAB-NO-SNAPSHOT & type xelab.txt & exit /b 1)
 58| + findstr <5 键(收窄)> xelab.txt >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & ... & exit /b 1)
```

**为什么必须用 stub**：VIO 核（`vio_v3_0_27_vio`）不是以 RTL 交付的 —— 探测过程逐条留证：
先报 `Module <vio_v3_0_27_vio> not found`，再报 `gtwizard_ultrascale_v1_7_22_*` 一族 not found（它们在 IP 的 `hdl/` 里）。
最终配方 = IP 的 `synth/` + `hdl/` + `vio_p7a_stub.v`（black box，与 P6e gate 用 `xdma_0_sim_stub.v` 同一手法）。
**代价**：VIO 核内部不被 lint —— 本门要 lint 的是**我们的** `p7a_top.v` 与 example-design 文件，不是 Xilinx 的 VIO 内部。

**运行（`logs/run_lint_p7a_after.txt`）**：

```
GATE_EXIT=0        实测 23.8 s（原 xvlog-only 约 2 s）
LINT-OK: no implicit nets, no width mismatch, no errors
```
产物：`_proj_10g/tcl/lint/xvlog.txt` **86 行**（`analyzing module p7a_top` 在第 1-2 行，0 ERROR）；
`xelab.txt` **52 行**，含 `Built simulation snapshot lint_p7a`；5 键命中 **0**；唯一告警族 `VRFC 10-3645` ×1（见 §8.2）。

### 3.3 `sim/p6b_lint/{lint,lint_def}.bat`

- `lint.bat`（**+11/-1**）：`files.f` 追加 `xdma_0_sim_stub.v`；尾部加 glbl+xelab+正证据判据+键表判据+`echo XELAB-LINT-OK: xelab face ran, log = xelab_lint.log`。
- `lint_def.bat`（**+10/-1**）：同上，但**默认配置无 `PCIE_OBS` ⇒ 无需 stub**；库名沿用该门自己的 `xil_defaultlib2`。

**运行**：

| 门 | 退出码 | 尾行 | xelab 日志 | 收窄键 | 裸键 |
|---|---|---|---|---|---|
| `lint.bat` | **0** | `XELAB-LINT-OK: xelab face ran, log = xelab_lint.log` | 快照已建 | 0 | 0 |
| `lint_def.bat` | **0** | `XELAB-LINT-OK: ...` | 快照已建 | 0 | **14** |

【实测】这两个门原本**没有任何退出码契约**（最后一个命令是 `echo`）。补面后我**显式追加了一条 `echo`** 收尾，
使退出码仍恒 0、**不改变它们的判定语义**；同时给出 `XELAB-LINT-OK` 正证据行。
⇒ **残余**：它们**仍然不能失败**（命中只打印 `=== IMPLICIT-XELAB ===`）。**这是留给门主人的决定**（§9 U3）。

### 3.4 探测阶段的一个工具坑（会咬下一次）

`xvlog.bat` / `xelab.bat` 的**默认 `-log` 名就是 `xvlog.log` / `xelab.log`**。重定向若同名 ⇒
`CRITICAL WARNING: [Common 17-183] Failed to open handle xelab.log ...`，**且不产生任何编译输出、退出码 1**。
本轮第一次探测就是这样"0.7 秒失败"的（前置报告 §5.6 已记过一次，**本轮又踩到**）。规避：重定向名一律加后缀（`xv_p6e.log` / `xe_p6e.log`）。

### 3.5 `sim/p6a_ku5p/pf/run_preflight.bat` —— **补了又回退**（并查清原因）

补面后 xelab 报 `ERROR: [XSIM 43-3322] Static elaboration ... failed`，根因是
`ERROR: [VRFC 10-3180] cannot find port 'ap_clk' ... [board/wrapper_p4.v:1906]`（`udp_echo` 的一族 AXIS 端口全找不到）。

**根因（【实测】，不是我的补丁引起的）**：该门的文件序是 **HLS 先、rtl 后** ——

```
11| call ... xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -f hls_files.f  > pf.log
12| call ... xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -f rtl_files.f  >> pf.log
```
而 `sim/p6a_ku5p/pf/rtl_files.f:24` 列着 **`rtl\udp_echo.v`**（5,989 B，手写 RTL），
它与 HLS 交付的 `hls/slowstack_prj/solution1/syn/verilog/udp_echo.v`（449,177 B）**同名**。
后编译者覆盖前者 ⇒ 库里那个 `udp_echo` 是**手写的、没有 AXIS 端口**
（读证：`pf.log` 里 `analyzing module udp_echo` 出现 **2 次**）。
权威门（`board/run_lint_p6e.bat` / `sim/p6b_lint/lint.bat`）的顺序是 **rtl 先、HLS 后** ⇒ HLS 胜出 ⇒ 正常。

⇒ **本门在 xvlog 阶段一直是"编过了但库里是错的模块"，xelab 一 elaborate 就暴露**。
这是该门的**既存缺陷**，与坑 24 无关；修它要改该门的文件序/文件表（`rtl_files.f` 是 Sep-28 的陈旧快照），
**属门主人的决定，本轮不动**。已**回退**我插入的 7 行（`fix_rest2.py`：按锚点定位 + 逐行内容校验后删除），
保留该文件的键表收窄。

---

## 4. `.gitignore` 那条：调查结论与处理（任务书点名项）

### 4.1 事实

```
$ git check-ignore -v sim/retxsim2/run_tb_frame_fifo.bat
.gitignore:54:sim/retxsim*/   sim/retxsim2/run_tb_frame_fifo.bat      -> 被忽略
$ git ls-files --error-unmatch sim/retxsim2/run_tb_frame_fifo.bat     -> 未跟踪
$ ls sim/retxsim2/  -> 23 个条目，全部被同一条规则忽略（含门 bat 本体）
```
且 `sim/retxsim2/run_tb_frame_fifo.bat` 是**现役 16 门矩阵的 `unit_fifo` 门**
（`sim/p4gates/run_matrix_p4dfix.bat:174`）—— 前置轮给它补的 xelab 判据**只存在于工作区**。

### 4.2 根因（**不是"忘了加否定行"**）

同目录族里其它规则都是"忽略产物、放行门 bat"的形状，例如

```
sim/p4sim/*              <- 忽略内容
!sim/p4sim/run_tb_*.bat  <- 放行门
```
而 `sim/retxsim*/` **带尾斜杠 = 匹配目录本身**。git **不进入被排除的目录**，
所以 `!sim/retxsim*/run_tb_*.bat` 这样的否定行**结构上永远无效**
（本轮实测：先加了否定行，`git check-ignore` 仍报忽略 ⇒ 才改的规则形状）。
⇒ 还有一条同形状的规则：**`sim/tbgate/`**（第 55 行）。

### 4.3 处理（**已做**）

```diff
-sim/retxsim*/
+# P7B: was sim/retxsim*/ -- a DIRECTORY-excluding rule, so no !line could
+#   ever re-include a file inside it (git does not descend into an excluded dir).
+#   sim/retxsim2/run_tb_frame_fifo.bat is the ACTIVE unit_fifo gate of the 16-gate
+#   matrix (run_matrix_p4dfix.bat:174) and was therefore permanently unreachable by
+#   git. Rule reshaped to the contents form used by sim/p4sim/* , plus the same
+#   !.../run_tb_*.bat negation every sibling product dir already has.
+sim/retxsim*/*
+!sim/retxsim*/run_tb_*.bat
```

**放行面实测（只多这一个文件，产物一个没漏）**：

```
$ git status --porcelain --untracked-files=all sim/retxsim2/
?? sim/retxsim2/run_tb_frame_fifo.bat        <- 只此一个
$ git check-ignore -v sim/retxsim2/{xsim_ff.log,frame_fifo_old.v,xsim.dir,xelab_ff.log}
.gitignore:286:sim/**/*.log          xsim_ff.log       <- 仍忽略
.gitignore:60:sim/retxsim*/*         frame_fifo_old.v  <- 仍忽略
.gitignore:333:xsim.dir/             xsim.dir          <- 仍忽略
.gitignore:286:sim/**/*.log          xelab_ff.log      <- 仍忽略
```

### 4.4 附带登记（**未改**）

- **`sim/tbgate/`（第 55 行）同形状**，但它的两个门 bat（`run_tb_uart_dbg.bat` / `run_tb_tcp_cam_tcb.bat`）
  **早已被跟踪** ⇒ 今天**没有损失**；**危险只对"将来新增的文件"**（新文件会像 retxsim2 一样静默进不了库）。
- `sim/snapcdc/review24/`（第 302 行）同为目录排除型，其下 6 个 `run.bat` 落不了库 —— 一次性复核目录，属预期。
- `sim/p4gates/implicit_gate.bat` / `implicit_gate_selftest.bat` / `evidence/implicit_gate_2026-09-29/`
  **不是被忽略，只是尚未 `git add`**（`git status` 显示 `??`）⇒ 正常提交即可入库。**这两件事要分清。**

---

## 5. 假阳性验证表（**本轮核心**）

### 5.1 语料定义

`D:\repo\XCKU5PMini\udp_hls_10g\**` 下扩展名 `.log` / `.txt` / `.rpt`，
排除 `Demo/`、`.git`、`xsim.dir`、`.Xil`、`work_*`、本任务的施工目录。
**8109 份 / 582,471,670 字节**。逐份跑**收窄后的 5 键**，并把每处的"被指责源文件"抽出来定性。
（脚本 `_proj_10g/notes/p7b_rollout/final_scan.py`；原始读数 `logs/final_scan.txt`；`10-3091` 的逐条定性 `logs/classify_3091.txt`）

### 5.2 键 × 语料 × 命中 × 定性

| 键 | 命中文件数 | 命中事件数 | 定性 | 说明 |
|---|---|---|---|---|
| `Synth 8-11241` | 36 | 599 | **真阳性（但落在非本设计代码上）** | 被指责源：`_proj_10g/xxv_probe/pcs64/pcs64.gen/.../xxv_ethernet_v5_0_2/pcs64_wrapper.v` ×221、`.../macpcs64_wrapper.v` ×195、`xxv_loop/rtl/pcs64_pkt_gen_mon_ds.v` ×41、`xxv_probe/rtl/probe_macpcs64_top.v` ×24。全是 **Xilinx 生成的 xxv_ethernet IP wrapper** 与本工程**已废弃的 xxv probe RTL**。**不是干净件假阳性，是"lint 范围含厂商生成代码"**（见 §8.3） |
| `undeclared symbol` | 37 | 607 | 同上 | 是 `8-11241` 的文本部分，同一行两条同时命中，故计数同量级 |
| **`VRFC 10-3091] actual bit length 1 differs ...`**（收窄后） | 43 | 98 | **本仓仅 2 条 = 冻结病理件（真阳性）**；其余 41 份是**另一个 checkout** 的陈旧日志 | 41 份日志的被指责源形如 `D:/repo/ECO/udp_hls_10g/...`（见 §5.3）。**本 checkout 的真实命中 = 2 条，全是 `p7b_implicit_repro/A1_portconn.v` ⇒ 假阳性 0** |
| `VRFC 10-2989` | 1 | 1 | **真阳性** | 唯一命中 = 冻结病理件 `A2_expr.v` ⇒ 在真实设计上**从未触发过** |
| `implicitly declared` | 14 | 38 | **在 2025.2 下 0 条真实命中** | 命中全部是：① 另一个 checkout 的 **pre-2025.2 synth 日志**（`WARNING: [Synth 8-8895] 'tcb_wr' is already implicitly declared`）；② **门自己的回显行**（`S2_GREP runme.log <implicitly declared> = 0` —— 日志里记着被搜的字符串本身，一种自指式计数）；③ 冻结证据目录的文件名 |

**收窄前的同一张表**：`VRFC 10-3091` 命中 **172 份文件 / 642 事件**，其中假阳性族 = §1.1 的 A 类。
收窄后 **172 -> 43**，**本仓假阳性 0**。

### 5.3 一个必须点名的解释：为什么 43 份里 41 份指向 `D:/repo/ECO/...`

`udp_hls_10g` 于 2026-09-28 从 `D:\repo\ECO\udp_hls_10g` **整体拷贝**而来，历史日志里的绝对路径因此仍指向 ECO。
⇒ 这些不是"本 checkout 的问题"，而是**那个 checkout 的日志快照**。
**这与"真空门"史一致**（前置报告与 `CLAUDE.md` 记录的 243 个真空门）。
**判据**：凡日志里出现 `D:/repo/ECO/` 的，**一律不能当本仓读数**。

### 5.4 刻意排除的键（**本轮新增 1 条，并把理由做成读数**）

| 键 | 排除理由（实测） |
|---|---|
| `8-7129` / `unconnected or has no load` | 命中干净件的**合法未用端口**（前置 §2.5） |
| `8-6014` / `8-3917` | 纯优化提示（未用寄存器被删 / 端口被常量驱动） |
| **`VRFC 10-3645` / `remains unconnected`（本轮新增）** | **xelab 侧的 `8-7129` 对偶**：干净的真实 P6e 设计一 elaborate 就报 **20 条**（`board/lint_p6e/xelab_p6e.log`）；`p7a_top` 上再报 1 条。**加进硬失败 = 立刻满屏假阳性** |
| `does not have driver`（`8-3848`） | **【未核实】** —— 前置报告未测，本轮也没测（§9 U4） |

---

## 6. 回归见证

### 6.1 P4 16 门矩阵（现役入口 `sim\p4gates\run_matrix_p4dfix.bat`）

- **第一轮（作废）**：我在矩阵**运行期间**改了 `sim/p4sim/run_tb_p4_burst.bat`（键表收窄）。
  `trunc50` 门在 xsim 结束后**未产生任何输出、退出码 1** —— 位置正好落在我写文件的那一刻。
  **cmd 会在执行中按字节偏移继续读 `.bat`，运行中改它就会错读后续命令**。
  ⇒ 该轮**判为作废**（本仓对此的既定语义就是 `exit 2 = 跑动期间源码被改 => 整轮作废`），我主动终止了它。
  这是**方法上的错误，不是被测对象的问题**，记录在此以免复现。
- **第二轮（干净）**：所有被跟踪文件的改动**冻结之后**重跑。读数见 §6.3。

### 6.2 受影响各门的重跑（全部为**本轮改动之后**的运行）

| 门 | 退出码 | 关键判据行 |
|---|---|---|
| `sim\p4gates\implicit_gate_selftest.bat` | **0** | `SELFTEST_RESULT = PASS_ALL (9 controls: 4 pathological FAIL, 4 clean PASS, 1 missing-log FAIL)` |
| `board\run_lint_p6e.bat` | **0** | `LINT-OK: no implicit nets, no width mismatch, no errors` |
| `_proj_10g\tcl\run_lint_p7a.bat` | **0** | `LINT-OK: no implicit nets, no width mismatch, no errors` |
| `sim\p6b_lint\lint.bat` | **0** | `XELAB-LINT-OK: xelab face ran, log = xelab_lint.log` |
| `sim\p6b_lint\lint_def.bat` | **0** | `XELAB-LINT-OK: xelab face ran, log = xelab_def.log` |
| `_proj_10g\notes\p7b_rollout\ctrl_3091.bat` | **0** | `NARROW: TP-HIT (good)` / `NARROW: FP-CLEAN (good)` / `BROAD : FP-HIT` |
| `sim\p4gates\run_matrix_p4dfix.bat` | **见 §6.3** | 见 §6.3 |

### 6.3 矩阵最终读数（第二轮，**干净轮**）

```
退出码            = 0                （harness 原始记录：`[exited with code 0]`）
跑动的门          = 16 / 16
失败的门          = 0
每门退出码        = 16 个 "GATE <name> EXIT=0"（逐个列于 §11）
权威矩阵日志      = sim/p4sim/matrix_p4dfix.log   行数 = 237
我抓的 stdout     = _proj_10g/notes/p7b_rollout/logs/p4matrix_clean.txt   行数 = 32
冻结核对（关键）  = VERDICT: FROZEN -- all 237 hashed files byte-identical across the run
DIGEST_COMPILE    = f93ef906a0de6964d72d49261150b955901edd02fa6d566e96e090ab829957e6（before == after）
HEAD              = e87375a
起止              = 2026/09/29 21:39:09 -> 22:03:27
```

⇒ **没有 `exit 2`（修订漂移）**：本轮是**冻结轮**，读数有效。

**各门的判定行**（`| ` 前缀行来自 `gatebrief`；**不是看退出码**）：

| 门 | 判定行 |
|---|---|
| chain | `P4 CHAIN OK` · `frames RX=9 TX=11 (fast=6 slow=5)  STRIPPED=0 (期望 0, VLAN OFF)` |
| burst200 / trunc50 / trunc100 / halfdrop / txdrop50 / gate4096 / dupstorm / pcackoob | `BURST OK`（各 1 条） + `STATS_MAC (mac_frames,abort,eend)` 与 `TRUNCS` 对账行 |
| vlanchain | `P4 CHAIN OK` · `STRIPPED=2 (期望 2, VLAN ON)` |
| vlanburst | `BURST OK` · `STRIPPED 202 (期望 202, VLAN 注入 ON)` |
| stallgate | `PCSTALL OK (burst=200, echo 帧 240)` |
| unit_retx | `GRP F (reset consistency): PASS` / `GRP G (streaming back-to-back reads): PASS` / `ALL 7 GROUPS PASS` |
| unit_fifo | `PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700` |
| unit_vlan | `VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)` |
| unit_uart | **Console 只有 1 行** ⇒ 见下 |

#### 6.3.1 【新】`unit_uart` 是**第三个"控制台无声"的门**（既有文档只点名了两个）

`sim/p4gates/work_20260929_213909/unit_uart/_gate_console.log` **只有 1 行**（`[P4GUARD OK] ...`），
门口的退出码是 0 —— 只看这两样会得出"这门啥也没干"的错误结论。
**实际它跑全了**（读它的工作目录，【实测】）：

```
xvlog_uart.log : analyzing module tb_uart_dbg            （0 ERROR）
xelab_uart.log : Built simulation snapshot tb_uart_dbg   （无隐式网命中）
xsim_uart.log  : L6 突发后空线 79243 拍 / ALL_OK / $finish ... tb_uart_dbg.v Line 661
```

⇒ `run_tb_uart_dbg.bat` **不 `type` 任何日志**（末行是 `xsim.bat ... > NUL 2>&1`），所以判定**只存在于工作目录**。
`CLAUDE.md` 的"跑门 ≠ 判门"只点名了 `unit_retx` / `unit_fifo`；**`unit_uart` 是第三个**，
且它的判据名（`ALL_OK`）与前两者（`ALL 7 GROUPS PASS` / `PASS_ALL`）**都不一样**，靠"找 PASS 字样"会漏。
**建议**：给该门补一条 `type xsim_uart.log`（或至少 `findstr ALL_OK`），与本仓其它门的习惯一致。

---

## 7. 文档订正清单

改的是**已被证伪的实现细节**（键串 / 给后人的操作建议）；**历史读数一个数字都没改**。

| 文件 | 行（改后） | 类型 | 内容 |
|---|---|---|---|
| `CLAUDE.md` | 282 | 改写（1 行 -> 1 行，内容大幅扩充） | 坑 24 的订正段：① 2025.2 三条真实文本（按工具分）② 只有 synth/xelab 能抓端口连接形式 ③ 5 键表 + **收窄后的 `10-3091`** ④ **刻意排除的 4 类键**（含新测的 `10-3645`）⑤ 裸 `10-3091` 那族的结构性哑 ⑥ **两条门历史 0 命中** |
| `PORT_NOTES.md` | 3358 / 3473 / 3785 | 同上 ×3 | 同上（三处规则源头） |
| `P7B_SPEC.md` | 627 / 671 | 键串改写 ×2 | F6/A14 判据表里的键 -> 收窄形式（**判定语义不变**） |
| `P6B_SPEC.md` | 1324 | 键串改写 | 交付判据第 4 条：删掉死关键字 `implicit`，补 `VRFC 10-2989` 与"只跑 xvlog 的日志不能证明无隐式网"的边界 |
| `P6B_INTEGRATION_REVIEW.md` | 368 | 操作建议改写（**历史数字 62 / 267-270 / 273 未动**） | "照抄 `findstr implicit`" -> 指向 `implicit_gate.bat`，并说明必须跑在 xelab/synth 日志上 |
| `P7A_COMMIT_PLAN.md` | 249 / 250 | 键串改写 + 订正段 | 并记录本门**已加 xelab 面**及其配方 / 代价 / exit 97 前提 |
| `P6E_OBS.md` | 231 | 操作建议改写（**历史读数 102 / 211 未动**） | `findstr 10-3091` -> 收窄键 + 必须跑 xelab 日志 |
| `README.md` | 369 | 键串改写 | 门的清单里 T2 检查项 -> 收窄键 |

**完整性核对**：8 份 `.md` 的**统一 CRLF 不变量**逐份复核通过：
`CLAUDE.md 294/294 · PORT_NOTES 4528/4528 · P7B_SPEC 1002/1002 · P6B_SPEC 1434/1434 · P6B_INTEGRATION_REVIEW 473/473 · P7A_COMMIT_PLAN 468/468 · P6E_OBS 366/366 · README 472/472`
—— **与前置报告 §5.4 记录的数目逐个相同**。
【实测】中途我把这 8 份写成了 LF-only（读时用了 universal-newline 模式），**已逐份恢复**。
（`.gitattributes` 只对 `*.sh` 指定 `eol=lf`；`core.autocrlf=true` => 仓库里存的是 LF，工作区习惯是 CRLF。）
**记此一笔：改这些 .md 必须显式保持 CRLF。**

---

## 8. 本轮新发现

### 8.1 【新】裸 `findstr /C:"10-3091"` 那一族判定**结构性常哑**

```
扫描 869 份"文件名含 xvlog"的日志 -> 含 10-3091 的 = 0
扫描 452 份"文件名含 xelab"的日志 -> 含 10-3091 的 = 173
```
⇒ **凡 grep `xvlog_*.log` 的裸 `10-3091` 判定永远不会触发**（xvlog 不做位宽检查）。
受影响的是那 52 行 `findstr /C:"10-3091" ... (echo BITWIDTH-MISMATCH-FAIL & exit /b 1)` 中 grep xvlog 日志的部分：
`audit_scratch/run_t{1,2,3,4,9}.bat`、`board/run_lint_p6e.bat:27`、`p6b_final_verify/run_t3_f2.bat`、
`review_scratch/run{cons,fn,mac,term}.bat`、`sim/clkgen/...`、`sim/f4chain/...`、`sim/f4sim/...`、`sim/fifoasync/run_mut_*.bat` 等。
**本轮的处置：语义不动**（它是**另一个**判据，不是隐式网键表的一部分），只登记 + 写进文档；
新增的 xelab 面**一律只用收窄键**，不引入裸 `10-3091`。

### 8.2 【新】`VRFC 10-3645` = xelab 侧的 `8-7129` 对偶（**必须排除**）

干净的真实设计上：`board/lint_p6e/xelab_p6e.log` **20 条**、`_proj_10g/tcl/lint/xelab.txt` **1 条**。
（前置报告只测了 synth 侧的 `8-7129`；本轮把 xelab 侧的同族键也标定为排除项。）

### 8.3 【新】`8-11241` 的一类范围性假阳性：**厂商生成的 IP wrapper**

`xxv_ethernet_v5_0_2/pcs64_wrapper.v` ×221、`macpcs64_wrapper.v` ×195 —— 都是 **Xilinx 生成的 IP 包装代码**，
它们**真的**含未声明符号（`gtwiz_reset_qpll0reset_out` 等）。
⇒ 键本身**没有过宽**（干净件 0 命中，前置 §2.5），问题在**lint 范围不该包含厂商生成代码**。
**处置：不改键**；建议 synth 侧的门把 IP 产物作为 black box / 排除在 `read_verilog` 之外。

### 8.4 【新】新门**首捕一条真阳性**：`tb/tb_p5_app.v` 里的真坑 24

```
tb/tb_p5_app.v:511   .dbg_plen_r(), .dbg_state(tx_fsm_state_w), .dbg_pay_wptr(), .dbg_pay_rptr(),
tb/tb_p5_app.v:992   .fsm_state(tx_fsm_state_w), .winq0(ac_winq0),
rtl/tcp_tx_frame.v:152   output wire [2:0]  dbg_state,   // P6: tx FSM state 寄存器
```
`tx_fsm_state_w` 在 `tb/tb_p5_app.v` 里**只有这两处使用、没有任何声明**
（`grep -n tx_fsm_state_w tb/tb_p5_app.v` 只回这两行）=> **隐式 1 位网** => 喂 3 位端口 `dbg_state` **静默截断**，
`xelab` 报 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 3 for port 'dbg_state'`。
=> **这是 100% 的真阳性（就是坑 24 本身），不是假阳性。** 新门**有牙**。

**连带影响（必须处置，但不在本轮）**：例化 `tb_p5_app.v` 且带 xelab 判据的门
（`sim/p5sim/run_tb_p5_app.bat` 一族 —— 由**前置轮** Rule C 插入）**现在会正确地失败**。
【推定】依据 = ① 我们的 `tb/tb_p5_app.v` 与日志里被指责的 ECO 同名文件 **sha256 完全相同**
（`c19c14bab3681fc0`，94471 B）② 日志给出的行号在我们的文件里**逐字对上**。
**未实测**（没有真跑那一族门）=> 列入 §9 U1。**修法**（属门主人）：给 TB 补 `wire [2:0] tx_fsm_state_w;`。

### 8.5 【新】`unit_uart` 是第三个"控制台无声"的门（详见 §6.3.1）

`CLAUDE.md` 的"跑门 ≠ 判门"只点名 `unit_retx` / `unit_fifo`；本轮实测 **`unit_uart` 也是**：
它的 `_gate_console.log` **只有 1 行**（`[P4GUARD OK]`），门的退出码 0，**但 TB 真跑了**且判定是
`ALL_OK`（只在 `xsim_uart.log` 里；判据名与前两者的 `ALL 7 GROUPS PASS` / `PASS_ALL` **都不一样**）。
⇒ 任何"在矩阵 console 里 findstr `PASS`"的自动化都会**漏掉这一门**。建议补 `type xsim_uart.log`。

---

## 9. 未核实清单（**严禁当结论用**）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| U1 | 例化 `tb_p5_app.v` 的那一族门现在**是否真的 FAIL** | 只做了**强推定**（§8.4：文件 sha256 相同 + 行号逐字对上），**没有真跑** | 跑一次 `sim\p5sim\run_tb_p5_app.bat`（分钟级）；先决定 TB 是否补声明 |
| U2 | 其余 **76 个**被改过的门有没有因键表变化出现新假阳性 | 本轮真实跑通的只有 6 处（4 个 lint 门 + 检测器自测 + 成对负对照）+ 16 门矩阵 | 分次 `-only` 跑其余门 |
| U3 | `sim/p6b_lint/{lint,lint_def}.bat` **仍然不能失败**（命中只打印） | 有意保留其原契约（它们本来就没有退出码契约） | 门主人决定是否升格为硬失败 |
| U4 | `8-3848`（`does not have driver`）作为硬失败是否过宽 | **完全没测**（前置 §4.5 同） | 合成"故意悬空但不用"的设计跑 `synth_design` |
| U5 | `run_preflight.bat` 的**文件序缺陷**（`rtl/udp_echo.v` 覆盖 HLS 版）是否影响别的门 | 只在**这个门**上实测到；`rtl_files.f` 是该目录私有的陈旧快照 | 全仓找其它 `rtl_files.f` 类快照；确认没有第二个门是"HLS 先、rtl 后" |
| U6 | P6e 真设计上 `10-3091` 的**良性出现频率** | 只在 `xelab_p6e.log`（0 条，DEV_USP 配置）与 `xelab_def.log`（14 条，默认配置）上量过 | 跑矩阵时顺带统计（现役 16 门不 elaborate `board/util_gmii_to_rgmii.v`，预期 0） |
| U7 | `IMPLICIT-DECL-FAIL` 0 命中 = **门从未失败过**？ | **不是同一个命题**（前置 §4.4）。本轮只重申"没有留存日志含这些标记" | 找回早期会话日志才能锁死 |
| U8 | 16 门里 `unit_retx` / `unit_fifo` 的**判定读数** | 它们无条件 `exit 0`；矩阵退出码**不覆盖**它们 | 读 `work_*/unit_*/_gate_console.log` 尾部 |
| U9 | `.md` 的 CRLF 不变量在**提交后**是否仍成立 | `core.autocrlf=true` + 只对 `*.sh` 指定 `eol=lf` => 提交时按 LF 存、检出时按 CRLF 放；**我恢复的是工作区形态** | 提交后 `git checkout` 一次复验 |
| U10 | 本报告首版曾被一次 `python -c` 内联命令损坏（bash 双引号里的反引号被当命令替换） | **已重写**，当前文件由 Write 工具写入 + 脚本转 CRLF，逐字节核对 | 无（教训：**不要在内联 `-c` 里写反引号/反斜杠**） |

---

## 10. 证据索引

| 内容 | 位置 |
|---|---|
| 收窄脚本 + 逐文件台账 | `_proj_10g/notes/p7b_rollout/narrow_3091.py` · `logs/narrow_3091_log.txt` |
| 成对负对照（宽 vs 窄） | `_proj_10g/notes/p7b_rollout/ctrl_3091.bat`（生成器 `mk_ctrl.py`） |
| 语料扫描（v1 宽键 / v2 汇总 / 最终窄键） | `…/corpus_scan.py` · `corpus_scan2.py` · `final_scan.py`；读数 `logs/corpus_scan2.txt` · `logs/final_scan.txt` |
| `10-3091` 逐条定性（按被指责源分组） | `…/classify_3091.py`；读数 `logs/classify_3091.txt` |
| U2 测量（xvlog 日志里有几条 10-3091） | `…/u2_xvlog_3091.py` |
| 收窄前后计数 | `…/gather.py` |
| P6e / P7a 的 xelab 可行性探测（含 IP/stub 配方） | `…/probe_xelab_p6e.bat` · `probe2_xelab_p6e.bat` · `probe_p7a.bat` · `probe_cfg.bat`（生成器同名 `.py`） |
| 门改动脚本（字节级行插入） | `…/fix_p6e_xelab.py` · `fix_p7a_xelab.py` · `fix_rest.py` · `fix_rest2.py` |
| 文档订正脚本 + 台账 | `…/fix_docs2.py` · `logs/fix_docs2_log.txt` |
| 各门重跑原始输出 | `logs/run_lint_p6e_after.txt` · `logs/run_lint_p7a_after.txt` · `logs/lint_after.txt` · `logs/lint_def_after.txt` |
| 矩阵日志（作废轮 / 干净轮） | `logs/p4matrix_rollout.txt` · `logs/p4matrix_clean.txt` |
| 冻结病理 / 干净 / 无关告警件（9 项对照） | `sim/p4gates/evidence/implicit_gate_2026-09-29/` |
| 规范检测器 + 自测 | `sim/p4gates/implicit_gate.bat` · `implicit_gate_selftest.bat` |
| 前置报告 | `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` |

---

## 11. 矩阵读数（机器追加，2026-09-29 22:06 回落）

```
MATRIX_EXIT = 0                       （harness: [exited with code 0]）
sim/p4sim/matrix_p4dfix.log           237 lines
_proj_10g/notes/p7b_rollout/logs/p4matrix_clean.txt   32 lines
gates run   : 16 / 16
gates failed: 0
VERDICT: FROZEN -- all 237 hashed files byte-identical across the run
DIGEST_COMPILE(before) = f93ef906a0de6964d72d49261150b955901edd02fa6d566e96e090ab829957e6
DIGEST_COMPILE(after)  = f93ef906a0de6964d72d49261150b955901edd02fa6d566e96e090ab829957e6
MATRIX DONE 2026/09/29 22:03:27
```

逐门退出码（全部 0）：

```
GATE chain      EXIT=0    GATE vlanchain  EXIT=0
GATE burst200   EXIT=0    GATE vlanburst  EXIT=0
GATE trunc50    EXIT=0    GATE stallgate  EXIT=0
GATE trunc100   EXIT=0    GATE unit_retx  EXIT=0
GATE halfdrop   EXIT=0    GATE unit_fifo  EXIT=0
GATE txdrop50   EXIT=0    GATE unit_vlan  EXIT=0
GATE gate4096   EXIT=0    GATE unit_uart  EXIT=0
GATE dupstorm   EXIT=0
GATE pcackoob   EXIT=0
```

**逐门判定行**（**跑门 != 判门**；详见 §6.3 的表与本节的 `unit_uart` 说明）：

```
chain      | P4 CHAIN OK   | frames RX=9 TX=11 (fast=6 slow=5)  STRIPPED=0 (期望 0, VLAN OFF)
burst200   | BURST OK
trunc50    | BURST OK      (注：作废轮里这一门曾被我的"运行中改 bat"打断成 EXIT=1；干净轮 EXIT=0)
trunc100   | BURST OK
halfdrop   | BURST OK
txdrop50   | BURST OK
gate4096   | BURST OK
dupstorm   | BURST OK
pcackoob   | BURST OK
vlanchain  | P4 CHAIN OK   | STRIPPED=2 (期望 2, VLAN ON)
vlanburst  | BURST OK      | STRIPPED 202 (期望 202, VLAN 注入 ON)
stallgate  | PCSTALL OK (burst=200, echo 帧 240)
unit_retx  | ALL 7 GROUPS PASS        （GRP F / GRP G 各 PASS）
unit_fifo  | PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802
unit_vlan  | VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)
unit_uart  | Console 无判定行 --> 读 sim/p4gates/work_20260929_213909/unit_uart/xsim_uart.log: ALL_OK
```

⇒ **16 门全部真跑且全过**（`unit_uart` 的判定按 §6.3.1 从工作目录读出）。
