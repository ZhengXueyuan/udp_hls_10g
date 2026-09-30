# P7B — 隐式网门（"漏声明 = 隐式 1 位线"）跨工程失效修复

- 日期：2026-09-29 · 器件 `xcku5p-ffvb676-1-e` · 工具 **Vivado 2025.2**（`C:\AMDDesignTools\2025.2`）
- 施工目录（本报告全部原始证据）：`udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/`
- 冻结证据（随门入库）：`udp_hls_10g/sim/p4gates/evidence/implicit_gate_2026-09-29/`
- 规范检测器：`udp_hls_10g/sim/p4gates/implicit_gate.bat` + `implicit_gate_selftest.bat`
- **纪律声明**：未改任何 RTL / XDC 设计文件；未烧板、未碰板载 QSPI；未动 license 文件；未碰 `D:\repo\perfv`；
  **未执行任何 git 写操作**（只用了只读的 `git cat-file` / `git status` / `git show` 做完整性核对）。

### 证据强度标记

| 标记 | 含义 |
|---|---|
| 【实测】 | 本机 Vivado 2025.2 原始输出，本文件给逐字原文 |
| 【工具读数】 | 报告/日志的机器可读读数字段 |
| 【自算】 | 本文件独立复算 |
| 【推定】 | 逻辑推理 |
| 【未核实】 | 不知道。**不得当判据用** |

---

## 0. 一句话结论

**用户的判断成立，而且比"关键字过时"更严重一层**：`implicitly declared` 在 Vivado 2025.2 里**已经一个字都不打印**（实测 4 类工具、6 份日志，命中恒 0），
但更关键的是 **2025.2 把"隐式网"拆成了两种形态、落在两个不同的工具上，而本工程 54 个门里有 44 个只 grep `xvlog` 日志 —— 这一类门对"端口连接形式"的隐式网结构性地抓不到**
（`xvlog` 对那个形态 **exit 0 且日志全空**）。已把规范化签名表落进 85 个脚本 + 8 份文档，
并新建一个**带九项对照**的规范检测器；`(a)(b)(c)` 三组病理/干净/无关告警对照全部按期望行为（见 §3）。
⛔ **仍未修的**：`board/run_lint_p6e.bat`（xvlog-only）等 **只跑 xvlog 的门**，见 §4.3 —— 这是本次**最大的遗留缺口**，需要一次**会改变运行时长**的决定。

---

## 1. 普查：全仓到底有多少地方在用这个（已失效的）关键字

### 1.1 口径

扫描范围 `D:\repo\XCKU5PMini\udp_hls_10g\**`，扩展名 `.bat` / `.py` / `.tcl`，
排除：厂商原始资料 `Demo/`、一次性工作产物 `work_*` / `evidence/` / `xsim.dir` / `.Xil` / `.git`、本任务自己的施工目录 `p7b_implicit_repro/`。
匹配模式：`implicit`（大小写不敏感，覆盖 `implicitly` / `implicitly declared`）。

### 1.2 汇总（**修复前**，共 146 行 / 65 个文件）

| 类别 | 行数 | 文件数 | 说明 |
|---|---|---|---|
| **门判据 · 硬失败**（`findstr ... implicit ... && (echo ...-FAIL & ... exit /b 1)`） | **71** | **54** | 本次的修复主目标 |
| **门判据 · 仅提示**（`&& echo NOTE-IMPLICIT-DECL` / `&& echo === IMPLICIT ===` / 裸 `findstr`） | 38 | 21 | 不改变退出码，但读数同样无意义 |
| 注释（`REM ...` / `# ...`） | 28 | —— | 会把后人引向同一个哑门 |
| 其他（python 生成器字符串、tcl 文案等） | 9 | —— | 其中 `p6b_final_verify/_gen_t3bat.py:45` 是**生成器**，改它才能让新生成的 bat 有牙 |

另有 **`_proj_10g/xxv_loop/tcl/s2_build.tcl`** 一处（`set keys {...}` 形式，不是 `findstr`）——
**它已被 `_proj_10g/xxv_loop/patch_r3.py`（2026-09-29 第 2 轮）单独修过**，本次未再改动它。

### 1.3 逐处：**这个环境（Vivado 2025.2）下还能不能匹配到**

⚠️ **一句话回答：不能。全部 146 处的判据在 2025.2 下命中恒 0 ⇒ 全部是哑门。**

依据（§2 的实测）：`implicitly declared` 这个字符串在 2025.2 的 `xvlog` / `xelab` / `synth_design` 输出里
**一次都没出现过**；而 `implicit`（无 `ly`）是 `implicitly` 的子串，也不会命中
（2025.2 里带 "implicit" 字样的消息**在本轮全部实测日志中未出现**）。

判据**分两类**，失效方式不同，必须分开看：

| 门判据 grep 的日志 | 处数（硬失败） | 旧关键字 | 该门能否抓到「端口连接形式」的隐式网？ |
|---|---|---|---|
| **只有 `xvlog_*.log`** | 44 个文件 | `implicitly` / `implicit` | ⛔ **不能，且换成任何关键字都不能** —— 实测 xvlog 对该形态 **exit 0、日志全空**（§2.1 A1） |
| 同时 grep `xelab_*.log` | 10 个文件 | `implicit` | ⚠️ 关键字死了，但**位置是对的**：xelab 会报 `VRFC 10-3091`；换成新键即可复活（本次已做） |

**⇒ 本次修复因此分两步**：① 把关键字换成实测签名（所有处）；② **给只查 xvlog 的门补上 xelab 一侧的判据**（这是"有牙"的关键，不是可选项）。

### 1.4 文档里把它写成"门"的地方（逐处）

| 文件:行 | 原文关键句 | 处置 |
|---|---|---|
| `CLAUDE.md:281` | `⇒ 门里必须把 **findstr implicit 当硬失败** (P5e-T3/T5 的门已加, 4 个日志命中 0)` | ✏️ **改写**（这是全仓的规则源头） |
| `PORT_NOTES.md:3357` | `⇒ 门里应用 findstr implicit 做硬失败 (T3/T5 的门已加, 4 个日志命中 0)` | ✏️ 改写 |
| `PORT_NOTES.md:3468` | `DRC 级静态检查 ... : implicit (T2 建议加 …)` | ✏️ 改写 + 订正注 |
| `PORT_NOTES.md:3782` | `已把 findstr /C:"10-3091" 与 findstr /I /C:"implicitly" 一并列为门里的硬失败` | ✏️ 改写（`10-3091` 是对的，`implicitly` 是死的） |
| `P7B_SPEC.md:627` (F6) | `implicitly declared 命中 0（当硬失败）· 10-3091 计数 0` | ✏️ 改写判据关键字 |
| `P7B_SPEC.md:671` (A14) | `lint：implicitly declared = 0 · 10-3091 = 0` | ✏️ 改写 |
| `P6B_SPEC.md:1324` | `构建日志里 **无** implicit 隐式网、10-3091 位宽不符` | ✏️ 改写 |
| `P6B_INTEGRATION_REVIEW.md:62` | `…10-3091 计数都是 0、implicitly 计数也是 0` | 📝 加订正注（这是**历史读数**，不改数字） |
| `P6B_INTEGRATION_REVIEW.md:273` | `四种组合全部编过…（都没报 undeclared / implicit / 位宽）` | 📝 加订正注：该项**只能证"没有表达式形式的未声明"，不能证"没有隐式网"** |
| `P7A_COMMIT_PLAN.md:249` | `run_lint_p7a.bat: elaboration 级 lint(implicit net / 位宽 / ERROR 三类硬失败)` | ✏️ 改写 |
| `P6E_OBS.md:211` | `…10-3091 与 implicitly 计数都是 0 ⇒ 这类错只有"例化真 DUT + 逐字读回"抓得到` | 📝 加订正注 |
| `README.md`「怎么跑 · 门矩阵」的 P5e-T2 行（README 2026-09-30 重写**前**为 `:369`） | `run_tb_p5e_t2_wrapper.bat（T2 真 wrapper 全链，含 implicit 检查）` | ✏️ 改写为实测签名 |
| `P7B_GATE1.md:285 / :574` | A14 判据表 `implicitly declared 命中 0` | 📝 在 §7 未核实表登记（见下） |
| `ISSUE_RX_BYTE_CORRUPTION.md:1122/1387/…`（6 处） | `构建日志 implicitly declared 0 命中` 一类**历史读数** | 📝 未改（见 §5.3 的"未改清单"与理由） |

---

## 2. 最小复现：2025.2 的真实报错文本到底是什么（**逐字抄回**）

### 2.1 复现件

`_proj_10g/notes/p7b_implicit_repro/` 下四个最小设计，另有一份"已声明但位宽不符"的对照：

| case | 内容 | 是不是病理 |
|---|---|---|
| `A1_portconn.v` | `sub64 u_mid(.q(mid)); sub64 u_out(.d(mid));` —— **`mid` 从未声明**（= 坑 24 的原始形态） | ✅ 病理 |
| `A2_expr.v` | `always @(posedge clk) dout <= pay_sel & din;` —— **`pay_sel` 从未声明**（表达式形式） | ✅ 病理 |
| `B1_clean.v` | 与 A1 逐字同构，只多了 `wire [63:0] mid;` | ✅ 干净 |
| `C1_benign.v` | 无隐式网，但故意造出无关告警（未用寄存器 / 未用端口 / 位宽适配） | ✅ 无关告警 |
| `W1_widthmis.v` | `wire [0:0] narrow;` **已声明**，喂 64 位端口 | 对照探针 |

### 2.2 `xvlog`（Vivado Simulator 前端）—— **端口连接形式：一个字都不打印**

```
===== CASE A1_portconn =====
XVLOG_RC=0
--- xv_case.log (raw) ---
INFO: [VRFC 10-2263] Analyzing Verilog file "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/A1_portconn.v" into library work
INFO: [VRFC 10-311] analyzing module sub64
INFO: [VRFC 10-311] analyzing module A1_portconn
```

⇒ **`rc=0`、日志里关于 `mid` 一个字都没有**。这就是坑 24 说的"静默"，
也是**同一条 xvlog 日志无论 grep 什么关键字都抓不到**的证据。

**表达式形式则相反 —— 是致命 ERROR**：

```
===== CASE A2_expr =====
XVLOG_RC=1
ERROR: [VRFC 10-2989] 'pay_sel' is not declared [.../A2_expr.v:3]
ERROR: [VRFC 10-8530] module 'A2_expr' is ignored due to previous errors [.../A2_expr.v:2]
```

**干净件与无关告警件都是 rc=0 且无关键字命中**（`B1_clean` / `C1_benign`，`C1` 的 xvlog 日志只有 3 行 INFO）。
⚠️ **额外实测（堵死一条可能的出路）**：`xvlog -sv`（SystemVerilog 模式）**也抓不到** ——
`SV_RC=0`，日志与 Verilog 模式逐字相同。**"改用 `-sv`"不是本坑的解**。

### 2.3 `xelab` —— **端口连接形式唯一的、xvlog 侧不存在的检测点**

```
===== XELAB A1 (port-conn implicit) =====
XELAB_RC=0
WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q' [.../A1_portconn.v:7]
WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'd' [.../A1_portconn.v:8]
```

干净件 `B1_clean` 同段**零告警**。
⚠️ **判别力边界（实测）**：`10-3091` 不是"隐式网专属" —— 已声明但位宽不符的 `W1_widthmis` 同样报
（1 条，`... for port 'd'`）。**它是"截断症状"的签名，是隐式网的超集**。本工程 8+ 个门早已把它当硬失败，本次沿用这一既有约定。

### 2.4 `synth_design` —— **端口连接形式 → INFO；表达式形式 → 致命 ERROR**（两者完全不同！）

```
===== SYNTH CASE A1_portconn =====     (rc=0，位流可出)
INFO:  [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire' [A1_portconn.v:7]
WARNING: [Synth 8-689] width (1) of port connection 'q' does not match port width (64) of module 'sub64' [A1_portconn.v:7]
WARNING: [Synth 8-689] width (1) of port connection 'd' does not match port width (64) of module 'sub64' [A1_portconn.v:8]
WARNING: [Synth 8-3936] Found unconnected internal register 'u_mid/q_reg' and it is trimmed from '64' to '1' bits. [A1_portconn.v:3]
...
WARNING: [Synth 8-7129] Port din[63] in module A1_portconn is either unconnected or has no load
（din[62..1] 同类共 63 条）

===== SYNTH CASE A2_expr =====        (rc=1，读文件就失败)
ERROR: [Synth 8-36] 'pay_sel' is not declared [A2_expr.v:3]
INFO:  [Synth 8-10285] module 'A2_expr' is ignored due to previous errors [A2_expr.v:4]
ERROR: [Synth 8-12188] Failed to read verilog 'A2_expr.v'

===== SYNTH CASE C1_benign =====      (rc=0)
WARNING: [Synth 8-6014] Unused sequential element unused_reg_reg was removed.  [C1_benign.v:10]
WARNING: [Synth 8-6014] Unused sequential element narrow_reg was removed.  [C1_benign.v:11]
WARNING: [Synth 8-7129] Port a in module C1_benign is either unconnected or has no load
WARNING: [Synth 8-3917] design C1_benign has port dout[63] driven by constant 0   (×64)
```

⇒ **同一个"隐式网"在 synth 里也分两种**：端口连接形式是 **INFO**（会被 `findstr` 看见，但只有主动去查才看得见），
表达式形式是 **ERROR**（会被任何 `ERROR` 兜底判据拦下）。
**`8-11241` 是唯一精确对应"静默截断"那一形态的签名。**

### 2.5 关键字的匹配能力矩阵（三种工具分别列，因为门跑在不同工具上）

| 匹配串 | `xvlog` 日志 | `xelab` 日志 | `synth_design` / runme.log | 会不会吞无关告警（实测） |
|---|---|---|---|---|
| `implicitly`（旧） | ❌ 0 | ❌ 0 | ❌ 0 | 不吞，但**全死** |
| `implicit`（旧，无 ly） | ❌ 0 | ❌ 0 | ❌ 0 | 同上 |
| **`undeclared`**（裸词） | ❌ 0（xvlog 说 "is **not declared**"） | ❌ 0 | ⚠️ 会命中 `8-11241` 行 | 未见 |
| **`Synth 8-11241`** | ❌ 0 | ❌ 0 | ✅ **精确命中** | 否（C1 零命中） |
| **`undeclared symbol`** | ❌ 0 | ❌ 0 | ✅ 命中（`8-11241` 的文本部分） | 否 |
| **`VRFC 10-3091`** | ❌ 0（**本轮到不了**） | ✅ **命中**（截断症状） | ❌ 0 | 否，但**是超集**（见 §2.3） |
| **`VRFC 10-2989`** | ✅ 命中（表达式形式） | ✅ 同 | ❌（synth 用 `8-36`） | 否 |
| `8-7129` / `unconnected or has no load` | ❌ | ❌ | ⚠️ **命中干净件 C1 的合法未用端口** | ⛔ **吞**（见 §4.5） |
| `8-6014` / `8-3917` | ❌ | ❌ | ⚠️ 命中干净件 | ⛔ **吞** |

### 2.6 ⭐ 推荐的匹配串（**要与真正的隐式网相关，不能宽到吞无关告警，也不能窄到漏掉**）

**推荐使用下面这一组（5 个键，OR 语义）——它就是 `sim/p4gates/implicit_gate.bat` 落地的键表：**

```
/I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"implicitly declared"
```

**逐项理由**

| 键 | 为什么留 |
|---|---|
| `Synth 8-11241` | 唯一精确对应**端口连接形式**（本坑原始形态）的 synth 签名。 |
| `undeclared symbol` | 同一条消息的**文本部分**：万一 AMD 改编号而不改文案，这一条仍能命中。**代价 = 0**（实测 C1 干净件零命中）。 |
| `VRFC 10-3091` | **xvlog 侧唯一可能的替代品**（xelab 日志上）。没有它，44 个 xvlog-only 门**永远**抓不到坑 24。 |
| `VRFC 10-2989` | 表达式形式的 xvlog 报错。比裸 `ERROR` 精确（不吞 `Vivado 12-1790` 这类预期 ERROR 文案）。 |
| `implicitly declared` | **保留仅为兼容 2025.2 之前的工具**。在 2025.2 下它恒 0 —— **保留的成本是 0，删掉的风险是历史工具上少一个判据**。 |

**刻意排除的键（都有实测的假阳性证据）**

| 键 | 排除理由（实测） |
|---|---|
| `8-7129` / `unconnected or has no load` | 干净件 `C1_benign` 的**合法未用输入端口 `a`** 就命中了 ⇒ 加进硬失败会**误伤正常设计**。 |
| `8-6014` / `8-3917` | 干净件 C1 命中（未用寄存器被删、端口被常量驱动）⇒ 纯优化提示。 |
| 裸 `implicit` | 会命中本仓 `.bat` 注释里的中文"隐式"英文拼写等噪声；且对**端口连接形式**依然 0 命中 ⇒ **毫无收益、只有风险**。 |

**⚠️ 键表的一个不可回避的限制（必须写清楚）**：
**没有任何单一键能覆盖全部形态**。因为"端口连接形式"在 xvlog 里没有任何签名，
所以 **`implicit_gate.bat` 必须跑在 `xelab` 或 `synth` 的日志上才有牙**；
拿它去查一份 xvlog 日志，它只会报"干净"（这正是 §3 的 a0 对照）。

---

## 3. 修门 + 病理负对照（**本节给出 (a)(b)(c)(d) 的实际运行输出**）

### 3.1 规范检测器（新文件，两个）

- `sim/p4gates/implicit_gate.bat` —— 键表 + 用法 + 退出码（0 干净 / 1 命中 / 2 日志缺失）的唯一权威处；
  文件头逐条写清了"旧关键字为什么死了、2025.2 打什么、哪些键为什么不能用"。
- `sim/p4gates/implicit_gate_selftest.bat` —— **离线重放 9 项对照**（不需要工具链，约 1 秒）。
- 冻结证据：`sim/p4gates/evidence/implicit_gate_2026-09-29/`（4 个 `.v` 源 + 9 份原始日志，含一份**真实生产日志**）。

### 3.2 ⭐ 九项对照的实际运行输出（逐字）

```
==========================================================================
 implicit_gate.bat self test -- controls a0 / a / a1 / a2 / b / c
==========================================================================

---- a0  PATHOLOGICAL design seen by XVLOG ONLY ---- EXPECT PASS(0)
     (this is the proof the OLD keyword gate was dumb: xvlog prints nothing)
CASE-a0-A1-xvlog: OK  no implicit-net signature in D:\...\log_a_A1_xvlog_clean_SILENT.log.txt
[a0] expected=0 got=0

---- a1  PATHOLOGICAL design seen by XELAB ---- EXPECT FAIL(1)
CASE-a1-A1-xelab: IMPLICIT-NET-FAIL  log=D:\...\log_a_A1_xelab_10-3091.log.txt
WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q' [D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/A1_portconn.v:7]
WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'd' [D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/A1_portconn.v:8]
[a1] expected=1 got=1

---- a2  PATHOLOGICAL design (implicit net in an EXPRESSION) xvlog ---- EXPECT FAIL(1)
CASE-a2-A2-expr: IMPLICIT-NET-FAIL  log=D:\...\log_a2_A2_xvlog_10-2989.log.txt
ERROR: [VRFC 10-2989] 'pay_sel' is not declared [D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/A2_expr.v:3]
[a2] expected=1 got=1

---- a3  PATHOLOGICAL design seen by SYNTH ---- EXPECT FAIL(1)
CASE-a3-A1-synth: IMPLICIT-NET-FAIL  log=D:\...\log_a_A1_synth_8-11241.log.txt
INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire' [D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/A1_portconn.v:7]
[a3] expected=1 got=1

---- b1  CLEAN design, xvlog ---- EXPECT PASS(0)
CASE-b1-clean-xvlog: OK  no implicit-net signature in D:\...\log_b_B1_xvlog.log.txt
[b1] expected=0 got=0

---- b2  CLEAN design, xelab ---- EXPECT PASS(0)
CASE-b2-clean-xelab: OK  no implicit-net signature in D:\...\log_b_B1_xelab.log.txt
[b2] expected=0 got=0

---- b3  CLEAN design, synth ---- EXPECT PASS(0)
CASE-b3-clean-synth: OK  no implicit-net signature in D:\...\log_b_B1_synth.log.txt
[b3] expected=0 got=0

---- c1  BENIGN WARNINGS only (synth 8-6014 / 8-7129 / 8-3917) ---- EXPECT PASS(0)
CASE-c1-benign-synth: OK  no implicit-net signature in D:\...\log_c_C1_synth_benign_warnings.log.txt
[c1] expected=0 got=0

---- c2  REAL production xvlog log (VRFC 10-3609 benign) ---- EXPECT PASS(0)
CASE-c2-real-prod: OK  no implicit-net signature in D:\...\log_c_REAL_production_xvlog_10-3609.log.txt
[c2] expected=0 got=0

---- c3  missing log file ---- EXPECT FAIL(2)
CASE-c3-missing: LOG-MISSING D:\...\no_such_log.txt
[c3] expected=2 got=2

SELFTEST_RESULT = PASS_ALL (9 controls: 4 pathological FAIL, 4 clean PASS, 1 missing-log FAIL)
SELFTEST_RC=0
```

**逐条对应任务书的 (a)(b)(c)(d)**：

| 任务书要求 | 对照编号 | 结果 |
|---|---|---|
| (a) **含真隐式网的病理输入 ⇒ 新门必须报失败** | **a1 / a2 / a3**（同一病理设计的 xvlog-表达式、xelab-端口连接、synth-端口连接三个面） | ✅ **三个面全部 FAIL**，且打印出命中的原文行 |
| (a₀) 额外：**旧门在同一个病理设计上是什么表现** | **a0**（病理设计的 xvlog 日志） | ⚠️ **PASS** —— 这就是"哑门"的直接实证：**只看 xvlog 的旧门在任何关键字下都会放过这个设计** |
| (b) **干净输入 ⇒ 新门必须通过** | **b1 / b2 / b3** | ✅ 三个工具面全 PASS |
| (c) **含无关告警的输入 ⇒ 新门必须通过** | **c1**（合成干净件，带 `8-6014`/`8-7129`/`8-3917` 三类无关告警）· **c2（真实生产日志）** | ✅ 全 PASS（0 命中）—— 证明新键**没有宽到吞无关告警** |
| (d) 边界：**日志缺失**不得误判为通过 | **c3** | ✅ exit 2（不是 0） |

**c2 用的那份"真实生产日志"** = `board/lint_p6e/xvlog_p6e.log`（51,595 B，本工程真跑过的 xvlog lint 日志），
里面唯一的告警族是 `WARNING: [VRFC 10-3609] overwriting previous definition of module 'udp_echo'`（1 条）
⇒ 新键 **0 命中**，旧键也 **0 命中**。

### 3.3 真实设计的"无假阳性"对照（不是合成件，是**跑通的现役门**）

命令（用门自己的约定：`P4_WORKDIR` 私有工作目录 + 清空激励环境变量）：

```
cmd //c "set \"P4_WORKDIR=...\work_manual_implicitfix\unit_vlan\" && set \"TRUNC=\" && ... && call sim\vlansim\run_tb_vlan_strip.bat"
```

实际输出（逐字，尾部）：

```
[P4GUARD OK] root=d:\repo\xcku5pmini\udp_hls_10g self=d:\repo\xcku5pmini\udp_hls_10g manifests=5
VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)
GATE_RC=0
```

该门自己产出的两份日志在新键下的读数：

| 日志 | 新键命中 | 旧键 `implicitly` 命中 |
|---|---|---|
| `sim/vlansim/xvlog_tb.log` | **0** | **0** |
| `sim/vlansim/xelab_run.log` | **0** | **0** |

⇒ ① 改过的 bat **端到端还能跑**；② 新键在**真实 RTL + 真实 TB + 真实 xelab 日志**上**不产生假阳性**；
③ 旧键在真实生产日志上**确认为死**。

### 3.4 门结构完整性的离线守卫（改完之后没破坏矩阵）

```
sim/p4sim/run_tb_p4_chain.bat                  [P4GUARD OK] manifestcheck run_tb_p4_chain.bat: 20 files == manifest sim/p4gates/chain_src.f
sim/p4sim/run_tb_p4_burst.bat                  [P4GUARD OK] manifestcheck run_tb_p4_burst.bat: 20 files == manifest sim/p4gates/chain_src.f
sim/p4sim/run_tb_p4_chain_vlan.bat             [P4GUARD OK] manifestcheck run_tb_p4_chain_vlan.bat: 20 files == manifest sim/p4gates/chain_src.f
sim/p4sim/run_tb_p4_burst_vlan.bat             [P4GUARD OK] manifestcheck run_tb_p4_burst_vlan.bat: 20 files == manifest sim/p4gates/chain_src.f
sim/p4sim/run_tb_p4_chain_stall.bat            [P4GUARD OK] manifestcheck run_tb_p4_chain_stall.bat: 20 files == manifest sim/p4gates/chain_src.f
sim/retxsim/run_retx_tb.bat                    [P4GUARD OK] manifestcheck run_retx_tb.bat: 2 files == manifest sim/p4gates/retx_src.f
sim/retxsim2/run_tb_frame_fifo.bat             [P4GUARD OK] manifestcheck run_tb_frame_fifo.bat: 1 files == manifest sim/p4gates/fifo_src.f
sim/vlansim/run_tb_vlan_strip.bat              [P4GUARD OK] manifestcheck run_tb_vlan_strip.bat: 2 files == manifest sim/p4gates/vlan_src.f
sim/tbgate/run_tb_uart_dbg.bat                 [P4GUARD OK] manifestcheck run_tb_uart_dbg.bat: 2 files == manifest sim/p4gates/uart_src.f
```

**为什么这条重要**：`p4gate.py:290 bat_file_list()` 会把"门 bat 里交给 xvlog 的 `.v` 列表"与 manifest 逐项比对，**不一致就直接判门失败**。
插入的判据行刻意**不含 `xvlog.bat` 字样、不含 `.v` 词元** ⇒ 对抽取器不可见 ⇒ 9 个现役门的 manifest 一字未变（读数如上）。

---

## 4. 覆盖面：还漏了什么

### 4.1 ⭐ 现役的 P4 16 门矩阵**此前完全没有这类检查**（本轮的最大发现之一）

```
$ grep -n -i -E "implicit|undeclared|10-3091" sim/p4sim/*.bat
rc=1 (零命中)
```

`sim/p4gate.py` 里也**没有任何** implicit 相关逻辑（只有路径守卫与指纹）。
⇒ "本工程唯一权威的门入口 `sim/p4gates/run_matrix_p4dfix.bat`（16 门）" 对坑 24 **从来就没有过判据**。
**本次已补**：16 门实际用到的 9 个 bat 全部在 `xelab` 之后加了一条判据（见 §5.2 的 Rule C）。

### 4.2 `ifdef` 分支 —— **每个配置都要各跑一次**（坑 8 的教训）

本轮实测现役门用到的构建宏：

| 宏 | 用它的门数 | 覆盖它的门是否已带新判据 |
|---|---|---|
| `APP_MODE` | 10 | ✅（`sim/p5e_udp/*`、`sim/p5e_t2/*` 两个配置各一份检查） |
| `RTOLIM_FAST` / `RTOLIM_STALL` | 4 / 2 | ✅（同门内两套日志 `xvlog_wh/wd` + `xelab_wh/wd` 各一条） |
| `RXP_DIAG` | 2 | ✅（`run_tb_p5e_udp_wrapper_diag.bat` 的 `uw`/`ud` 两配置 + 两条 xelab 判据） |
| `PCIE_OBS` | 1 | ⚠️ **部分**：`_proj_pcie/run_tb_axi_regs.bat` 已带（含 xelab 侧）；但 `board/run_lint_p6e.bat` **不带 xelab**，见 §4.3 |
| `DEV_USP` | 1 | ⚠️ 同上，只在 `run_lint_p6e.bat` 与 `run_preflight.bat` 里出现 |

**结论**：**"同一设计不同 `ifdef` 配置各跑一次"这件事，本工程在 UDP/T2/DIAG 三处是做对的**（每配置一对日志、一对判据）；
但在 `PCIE_OBS` / `DEV_USP` 上**只有 xvlog 侧的判据**（§4.3）。

### 4.3 ⛔ **未修的最大缺口：只跑 xvlog 的门结构性地抓不到坑 24**

| 门 | 现状 | 为什么没修 |
|---|---|---|
| **`board/run_lint_p6e.bat`** | 只跑 `xvlog`（无 `xelab`）。它的**存在理由就是坑 24**（文件头注释原话），因此这是最讽刺的一处 | 加 `xelab` 会把它从"秒级"变成"分钟级"，且需要 `unisims_ver` + `glib.v` + 一套 elaborated top；**改动运行时长与失败面，属于需要门主人拍板的决定，不是本次该替他做的** |
| `sim/p4sim/run_tb_rxclass.bat` / `run_tb_rxclass_xk.bat` / `run_tb_slowrx.bat` | 这 3 个门**根本不把 xvlog/xelab 输出落盘**（直接打到控制台，`call ... xvlog.bat ...` 无重定向）⇒ **没有任何日志可 grep** | 要修得先给它们加日志重定向（改的是门的 I/O 结构）。**且这 3 个门都不在现役 16 门矩阵里**（16 门用的是 chain/burst/vlan/stall/retx/fifo/uart 那一族），优先级低 |
| `p6b_final_verify/_gen_t3bat.py` | xelab 调用写在 **3 行 Python 隐式字符串拼接**里，单行正则看不到 | **已手工补**（见 §5.2） |

**给门主人的具体建议（未执行）**：在 `board/run_lint_p6e.bat` 的 `xvlog` 之后加一段
`call %XV%\xelab.bat -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lint_p6e -log xelab_p6e.log` +
一条 `findstr` 判据。⚠️ **必须先确认 elaborate 能过**（否则会把"elaborate 失败"误报成"门失败"）——本轮**没有验证这一步**，故列为未核实。

### 4.4 ⭐ **"从来没被真正触发过"的门**

| 判据 | 结论 | 证据 |
|---|---|---|
| `IMPLICIT-DECL-FAIL` 这个失败标记 | **全仓 0 个文件出现过**（`--include=*.log --include=*.txt` 全扫，排除本任务施工目录） | 见 §4.4 的 grep 读数 |
| `BITWIDTH-MISMATCH-FAIL` | 同上，**0** | 同上 |
| `IMPLICIT-NET-FAIL`（本轮新增的标记） | **0**（新加的，不可能有历史） | 同上 |

```
=== has the implicit gate EVER fired? search every log for the fail strings ===
  'IMPLICIT-DECL-FAIL' found in 0 file(s)
  'BITWIDTH-MISMATCH-FAIL' found in 0 file(s)
  'IMPLICIT-NET-FAIL' found in 0 file(s)
```

⚠️ **严格的措辞**（铁律：查不到 ≠ 锁着）：**"没有任何留存的日志含这些失败标记"**。
这**不等于**"这些门从未失败过"（早期会话的日志可能没留存）。
**但有独立佐证指向"确实是哑的"**：`_proj_10g/xxv_loop/patch_r3.py:42-43` 自己写着
> `# The round-1/2 gate only looked for the phrase "implicitly declared" and so reported 0`
> `# while the design DID contain a real implicit net (which is how the ones-payload run silently failed).`

⇒ **有一次真实的"设计里有隐式网、门报 0"的记录**（在 `xxv_loop` 那条线上，已被 patch_r3 单独修过）。
**本轮 §3.2 的 a0 对照把同一个结论在最小复现上又证明了一次**：
病理设计 + xvlog 日志 ⇒ 任何关键字下都是"干净"。

**未触发过的门的处置**：本次没有把它们"删掉"，而是**换掉关键字 + 补上 xelab 判据**；
另外用 `implicit_gate_selftest.bat` 提供了一条**离线可复现的"有牙证明"**，
使得"改好了"与"废掉了"从此可区分（这正是本工程铁律"改宽之后必须用合成的病理行做负对照"的要求）。

### 4.5 ⚠️ 既存的两处"可能过宽"的键（**不是本次引入，本次也没删**）

`_proj_10g/xxv_loop/tcl/s2_build.tcl:134` 的 keys 里有两条**本轮实测证明会误伤**的键：

| 键 | 本轮实测证据 | 风险 |
|---|---|---|
| `"unconnected or has no load"`（= `Synth 8-7129`） | **干净件 `C1_benign` 的合法未用输入端口 `a` 命中** | 该 key 是**硬失败** ⇒ 任何有未用端口的设计都会被判失败。`xxv_loop` 本轮侥幸 0 命中（`P7B_GATE1.md` §4.4），但这是**潜伏的假阳性** |
| `"does not have driver"`（= `Synth 8-3848`） | **本轮未测**（【未核实】） | 该设计自己**故意**声明了两根悬空网（`P7B_GATE1.md` §6.2 A12）⇒ 同类结构一旦真的无驱动就会命中 |

**处置**：**未改**（改它属于 P7B 闸 1 门主人的判断，且它当前 0 命中、不是本次任务书点名的缺陷）。
**在此明确登记为遗留风险**，并建议门主人用"合成一个仅含未用端口的设计"做一次负对照来决定去留。

---

## 5. 改了哪些文件、哪几行

### 5.1 新文件（3 个 + 1 个证据目录）

| 文件 | 说明 |
|---|---|
| `sim/p4gates/implicit_gate.bat` | **规范检测器**（键表唯一权威处；ASCII + CRLF，实测 0 个非 ASCII 字节） |
| `sim/p4gates/implicit_gate_selftest.bat` | 九项对照自测（离线，约 1 秒） |
| `sim/p4gates/evidence/implicit_gate_2026-09-29/` | 4 个 `.v` 源 + 9 份冻结日志（含 1 份真实生产日志 51,595 B） |
| `_proj_10g/notes/p7b_implicit_repro/` | 施工/取证目录：最小复现件、跑工具的 bat、原始日志、机器生成的逐行改动台账 |

### 5.2 改造规则（对每个命中处施加的三种改动；**每处的文件:行号见下表**）

**Rule A — 关键字替换**（115 处；一行内所有出现都替换，含"回显命中行"的那一处）

```
- findstr /I /C:"implicitly"  <LOG>            （或 /C:"implicit"）
+ findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"implicitly declared"  <LOG>
```
样本（四种不同的既有写法各一例）：
```
board/run_lint_p6e.bat:25
  OLD: findstr /I /C:"implicitly" xvlog_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"implicitly" xvlog_p6e.log & exit /b 1)
  NEW: findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" ... & exit /b 1)

sim/p5e_udp/run_tb_app_udp.bat:54-55
  OLD: findstr /I /C:"implicit" xvlog_ua.log > NUL
       if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"implicit" xvlog_ua.log & exit /b 1)
  NEW: findstr /I /C:"Synth 8-11241" ... xvlog_ua.log > NUL
       if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"Synth 8-11241" ... xvlog_ua.log & exit /b 1)

audit_scratch/run_t1.bat:21     （仅提示型）
  OLD: findstr /I /C:"implicitly" xvlog_%CASE%.log >NUL && echo NOTE-IMPLICIT-DECL
  NEW: findstr /I /C:"Synth 8-11241" ... xvlog_%CASE%.log >NUL && echo NOTE-IMPLICIT-DECL

p6b_final_verify/_gen_t3bat.py:45   （生成器里的模板字符串）
  OLD: 'findstr /I /C:"implicitly" xvlog_run.log >NUL && (echo IMPLICIT-DECL-FAIL & exit /b 1)',
  NEW: 'findstr /I /C:"Synth 8-11241" ... xvlog_run.log >NUL && (echo IMPLICIT-DECL-FAIL & exit /b 1)',
```

**Rule B — 注释里的关键字（4 处）**

```
_proj_10g/tcl/run_lint_p7a.bat:7        REM     "implicitly"  -> ...    ⇒  "8-11241/10-3091"
sim/fifoasync/run_tb_fifo_async.bat:8   REM   24 : "implicitly" (...)   ⇒  24 : "8-11241/10-3091" (...)
sim/p5e_udp/run_tb_p5e_udp_wrapper.bat:32      REM   "implicit" -- ...  ⇒  "8-11241/10-3091" -- ...
sim/p5e_udp/run_tb_p5e_udp_wrapper_diag.bat:36 REM   "implicit" -- ...  ⇒  "8-11241/10-3091" -- ...
```

**Rule C — 补 xelab 判据（66 处插入；这是"有牙"的关键）**

在被改文件的 `xelab.bat` 调用行**之后**插入一行（日志名从该行的 `-log <name>` 或 `> <name> 2>&1` 里解析）：

```
+ findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"implicitly declared" <XELAB_LOG> >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr ... <XELAB_LOG> & exit /b 1)
```

- 已自带 xelab 判据、无需插入的：**15 处**（`C-OK`，如 `sim/p5e_t2/*`、`sim/p5e_udp/*`、`sim/rxpdiag/*`、`sim/p5e_rate/*`）。
- 解析不出 xelab 日志名的：**1 处**（`_gen_t3bat.py`，已手工补，见上）。

### 5.3 改动文件总清单

**门脚本：85 个文件**（`python fix_gates.py --apply` 的 `apply_log.txt` 里有**逐行 before/after 台账**）

```
_proj_10g/sim/run_tb_p7a_counters.bat      _proj_10g/tcl/run_lint_p7a.bat        _proj_pcie/run_tb_axi_regs.bat
audit_scratch/run_t1.bat                   audit_scratch/run_t2.bat              audit_scratch/run_t3.bat
audit_scratch/run_t4.bat                   audit_scratch/run_t9.bat              board/run_lint_p6e.bat
p6b_final_verify/_gen_t3bat.py             p6b_final_verify/run_t3_f2.bat        review_scratch/run.bat
review_scratch/runcons.bat                 review_scratch/runfn.bat              review_scratch/runmac.bat
review_scratch/runterm.bat                 sim/clkgen/run_tb_clk_gen_p6b.bat     sim/f4chain/run_tb_f4_chain.bat
sim/f4sim/run_tb_f4_mac.bat                sim/f4sim/run_tb_mac_f4regress.bat    sim/fifoasync/run_mut_empty1.bat
sim/fifoasync/run_mut_full.bat             sim/fifoasync/run_mut_full1.bat       sim/fifoasync/run_mut_gray.bat
sim/fifoasync/run_mut_noovf.bat            sim/fifoasync/run_mut_pref1.bat       sim/fifoasync/run_mut_rst1.bat
sim/fifoasync/run_tb_fifo_async.bat        sim/p4sim/run_tb_p4_burst.bat         sim/p4sim/run_tb_p4_burst_vlan.bat
sim/p4sim/run_tb_p4_burst_xk.bat           sim/p4sim/run_tb_p4_chain.bat         sim/p4sim/run_tb_p4_chain_active.bat
sim/p4sim/run_tb_p4_chain_active_slow.bat  sim/p4sim/run_tb_p4_chain_stall.bat   sim/p4sim/run_tb_p4_chain_stall_xk.bat
sim/p4sim/run_tb_p4_chain_vlan.bat         sim/p4sim/run_tb_p4_chain_xk.bat      sim/p4sim/run_tb_p4_replay.bat
sim/p5e_rate/run_tb_rate.bat               sim/p5e_t2/run_tb_p5e_t2_wrapper.bat  sim/p5e_udp/run_tb_app_udp.bat
sim/p5e_udp/run_tb_p5e_udp_wrapper.bat     sim/p5e_udp/run_tb_p5e_udp_wrapper_diag.bat
sim/p6a_ku5p/pf/run_preflight.bat          sim/p6a_ku5p/run_tb_frame_fifo_k7.bat sim/p6a_ku5p/run_tb_frame_fifo_us.bat
sim/p6a_ku5p/run_tb_ramb36e2_sem.bat       sim/p6a_ku5p/run_tb_rgmii_dbg.bat     sim/p6a_ku5p/run_tb_rgmii_phy_model.bat
sim/p6b_lint/lint.bat                      sim/p6b_lint/lint_def.bat             sim/p6e_pcie/run_tb_p6e_pcie.bat
sim/p6e_pcie/run_tb_p6e_pcie_counters.bat  sim/retxsim/run_retx_tb.bat           sim/retxsim2/run_tb_frame_fifo.bat
sim/rxpdiag/run_tb_rxp_diag.bat            sim/rxpdiag/run_tb_rxp_v3.bat         sim/rxpdiag/run_tb_rxp_v4.bat
sim/rxpdiag/run_tb_rxp_v5.bat              sim/rxpdiag/run_tb_rxp_v6.bat         sim/rxpdiag/run_tb_rxp_v7.bat
sim/snapcdc/atk/phase/run_atk_phase.bat    sim/snapcdc/atk/ratio/run_atk_ratio.bat  sim/snapcdc/atk/req/run_atk_req.bat
sim/snapcdc/atk/reset/run_atk_reset.bat    sim/snapcdc/atk/xprop/run_atk_x.bat   sim/snapcdc/mut5_nw/run_gate_selfneg.bat
sim/snapcdc/mut5_nw/run_mut5.bat           sim/snapcdc/negctrl/run_negctrl_2rst.bat  sim/snapcdc/review/run_torture.bat
sim/snapcdc/review24/axr/run.bat           sim/snapcdc/review24/cdc/run.bat      sim/snapcdc/review24/lint/run.bat
sim/snapcdc/review24/p6e/run.bat           sim/snapcdc/review24/p6e_mut/run.bat  sim/snapcdc/review24/p6e_mut2/run.bat
sim/snapcdc/run_tb_snap_cdc.bat            sim/snapseq/run_tb_snap_seq.bat       sim/tbgate/run_tb_tcp_cam_tcb.bat
sim/tbgate/run_tb_uart_dbg.bat             sim/udprx/run_tb_udprx.bat            sim/udprx_chain/run_tb_udprx_chain.bat
sim/vlansim/run_tb_vlan_strip.bat          sim/vlansim/run_tb_vlan_strip_xk.bat
```

**文档：8 个文件 / 13 处**（`python fix_docs.py --apply` 的 `docs_apply_log.txt` 有逐处 before/after）

| 文件 | 改动行（改后行号） | 类型 |
|---|---|---|
| `CLAUDE.md` | 281-282 | ✏️ 规则源头改写（含完整订正说明） |
| `PORT_NOTES.md` | 3357 附近 / 3470 附近 / 3782 附近 | ✏️✏️ 改写 + 📝 加订正注 |
| `P7B_SPEC.md` | 627 / 671 | ✏️ 判据关键字改写 |
| `P6B_SPEC.md` | 1324 | ✏️ 判据关键字改写 |
| `P6B_INTEGRATION_REVIEW.md` | 62 / 273 | 📝 加订正注（**不改历史数字**） |
| `P7A_COMMIT_PLAN.md` | 249 | ✏️ 改写 |
| `P6E_OBS.md` | 211 | 📝 加订正注 |
| `README.md` | 「怎么跑 · 门矩阵」的 P5e-T2 行（重写前 `:369`） | ✏️ 改写 |

**未改（有意，逐条给理由）**

| 文件 | 为什么没改 |
|---|---|
| `_proj_10g/xxv_loop/tcl/s2_build.tcl` | **已经是修过的版本**（`patch_r3.py` 第 2 轮加的 `8-11241`/`undeclared symbol`）。它不含 `VRFC 10-3091`，但 synth 流程下那条不会出现，**覆盖面不受影响**。它里面两条**过宽**的键见 §4.5（登记为遗留风险） |
| `_proj_10g/xxv_loop/patch_r3.py` | **是历史补丁记录**，不是门。改它等于篡改历史证据 |
| `ISSUE_RX_BYTE_CORRUPTION.md`（6 处） | 全是**已完成调查的历史读数**（"implicit 0/0"）。改数字 = 篡改历史。**但它们是"用死关键字的读数"**，故在 §4.4 统一登记其效力边界 |
| `P7B_GATE1.md`（A14 / §7） | 同上（已完成闸的读数）。§7 的 U12 已经是"`10-3091` 未单独统计"的自认缺口，本次不再改写已完成报告 |
| `sim/p4sim/run_tb_rxclass*.bat` / `run_tb_slowrx.bat` | 结构性无法承载（不落盘日志），见 §4.3 |
| `sim/p4gates/run_matrix_p4dfix.bat` / `p4gate.py` | **无需改**：判据放在各门 bat 里（改 runner 会牵连指纹/清单契约） |

### 5.4 改动的完整性核对（**85 个脚本 + 8 份文档，逐文件**）

`python verify_integrity.py`（对每个被改文件，逐文件在工作区上量）：

```
INTEGRITY_RESULT = PASS_ALL      (exit 0, 85 files)
```

判据：① `.bat` 的 CRLF 行数 == 总行数（或与 blob 同类，见下）；② `.bat` 无非 ASCII 字节。
**逐项残余（16 条，全部判为"既存、非本次损坏"，脚本自己打印了 `PRE-EXISTING ... not damage`）**：

| 类别 | 文件 | 说明 |
|---|---|---|
| 既存 **LF-only** bat（本来就不是 CRLF，本次未改其行尾风格） | `_proj_10g/sim/run_tb_p7a_counters.bat`（0/47）· `review_scratch/run.bat`（0/24）· `review_scratch/runmac.bat`（0/15）· `sim/snapcdc/atk/ratio/run_atk_ratio.bat`（0/30）· `sim/snapcdc/atk/reset/run_atk_reset.bat`（0/26）· `sim/snapcdc/review24/axr/run.bat`（0/15）· `sim/snapcdc/review24/cdc/run.bat`（0/15） | ⚠️ **这 7 个文件本来就不符合"bat 只允许 CRLF"的工程纪律**（既存问题，非本次引入）。本次的插入行**按各文件自己的 LF 风格落地**，避免制造"混行尾"。<br>🔎 **为什么"既存"这个判断成立（不依赖 git）**：修复后这 7 个文件的 `CRLF 行数 == 0`；而本次对它们只做**单行插入**（初版插入行是 CRLF，随后已改回 LF）⇒ 若原本存在任何一行 CRLF，它现在仍会在 ⇒ **原文必然是 0 行 CRLF**。✔ |
| 既存 **无非 ASCII 字节**的 bat | `audit_scratch/run_t9.bat`(48B) · `sim/f4chain/run_tb_f4_chain.bat`(60B) · `sim/f4sim/run_tb_mac_f4regress.bat`(51B) · `sim/p4sim/run_tb_p4_replay.bat`(93B) | 逐字节与 `git cat-file` 的仓库版本**完全一致**（中文 REM 注释），**本次一个字都没动** |
| 既存 **末行无换行** | `sim/p6a_ku5p/run_tb_{frame_fifo_k7,frame_fifo_us,ramb36e2_sem,rgmii_dbg,rgmii_phy_model}.bat`（14/15 CRLF） | 最后一行 `type xsim_*.log` 无终止符；`git cat-file` 的版本同样如此 ⇒ 既存 |
| `.md`（8 份） | —— | 逐份核对：**全部仍然 uniform-CRLF**（CLAUDE.md 294/294、PORT_NOTES 4528/4528、P7B_SPEC 1002/1002、P6B_SPEC 1434/1434、P6B_INTEGRATION_REVIEW 473/473、P7A_COMMIT_PLAN 468/468、P6E_OBS 366/366、README 472/472） |

### 5.5 ⭐ 7 处修复落在 **`.gitignore` 覆盖的路径**里（**其中 1 处是现役 16 门之一**）

`git ls-files` 逐个核对这 85 个文件：**78 个被 git 跟踪，7 个没有**。

| 未跟踪的修复文件 | 忽略规则 | 后果 |
|---|---|---|
| **`sim/retxsim2/run_tb_frame_fifo.bat`** | `.gitignore:54` = `sim/retxsim*/` | ⛔ **这是现役 16 门矩阵的 `unit_fifo` 门**（`run_matrix_p4dfix.bat:174`）⇒ **本次给它补的 xelab 判据落不了库**：磁盘上有效、`git commit` 之后**在干净 checkout 里会消失** |
| `sim/snapcdc/review24/{axr,cdc,lint,p6e,p6e_mut,p6e_mut2}/run.bat`（6 个） | `.gitignore:295` = `sim/snapcdc/review24/` | 一次性复核目录，属预期；落不了库也无妨 |

**⇒ 给门主人的行动项（未执行，因为要动 `.gitignore` 或把该门挪出忽略路径 —— 属于仓库结构决定）**：
要么把 `unit_fifo` 的 bat 从忽略规则里放出来（`!.gitignore` 例外行 / 改 `sim/retxsim*/` 的具体度），
要么接受"该门的新判据只存在于工作区"。**在那之前，`unit_fifo` 这一门的新判据不算入库。**

### 5.6 附带记录：一个踩到的工具坑（**不是本次缺陷，但会咬下一次**）

`xvlog.bat` 的**默认 `-log` 名就是 `xvlog.log`**。构建脚本若写
`call ...\xvlog.bat f.v > xvlog.log 2>&1`，两个句柄撞名 ⇒
`CRITICAL WARNING: [Common 17-183] Failed to open handle xvlog.log. ...`（**且不产生任何编译输出**）。
本仓的门**普遍已避开**（用的是 `xvlog_ua.log` / `xvlog_p6e.log` 这类名字），
但 `sim/p6b_lint/lint.bat` 等目录里同时存在 `xvlog.log` 与 `xvlog_lint.log` 两份，易混。**建议不要去建名为 `xvlog.log` 的重定向**。

---

## 6. 未核实清单（**严禁当结论用**）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| U1 | **另外 76 个改过的门有没有因为"键表变宽"而新出现假阳性** | 只**真实跑通了 1 个现役门**（`unit_vlan` ⇒ PASS，新键 0 命中）+ 4 个最小复现 + 1 份真实生产日志 ⇒ **其余门没有重跑**（任务书明确不许跑 16 门长任务） | 跑一次 `cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'`（约 25 分钟），或分次 `-only` |
| U2 | `VRFC 10-3091` **到底会不会出现在 `xvlog` 日志里** | 本工程 8+ 个门早就在 grep xvlog 日志里的 `10-3091`，**但本轮 4 个最小 case 的 xvlog 全为 0**（`A1/B1/C1/W1`）。⇒ 这条既有判据**可能本来也是哑的** | 造一个"单文件内位宽不符"的 case 试 `xvlog`；或直接信任 xelab 侧（新补的那条） |
| U3 | `8-3848`（`does not have driver`）作为硬失败**是否过宽** | **完全没测**（§4.5） | 合成一个"故意悬空但不用"的设计跑 `synth_design` 看是否命中 |
| U4 | `board/run_lint_p6e.bat` 加 `xelab` 后**能否 elaborate 通过** | 没试（§4.3） | 单独试 `xelab -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl`，计时并确认 0 error |
| U5 | **`10-3091` 在真实大设计里的"良性"出现频率** | 只在 1 个真实门（`unit_vlan`）上量过 = 0 | 跑矩阵时顺带统计 |
| U6 | 145/146 处**是否覆盖了"曾经真正用过这个门"的全部路径** | 我按文件系统扫了 `.bat/.py/.tcl`；**`.ps1` / `.sh` / `.cmd` / CI 配置未扫** | 扩扩展名重扫（本仓以 git-bash + bat 为主，风险低） |
| U7 | `IMPLICIT-DECL-FAIL` 标记"0 文件命中" = **门从未失败过**？ | **不是同一个命题**（见 §4.4）。已给出"某次真隐式网 + 门报 0"的间接证据 | 找回早期会话日志才能锁死 |
| U8 | `_proj_10g/xxv_loop` 那条线（`s2_build.tcl`）**改后是否真的抓到了**它那次隐式网 | 本轮**没有重跑**该 Tcl 构建（它要跑完整 synth，属长任务） | 用 `xxv_loop` 的构建脚本重跑一次 |
| U9 | **7 个修复文件被 `.gitignore` 覆盖**（§5.5），其中 `sim/retxsim2/run_tb_frame_fifo.bat` 是现役 `unit_fifo` 门 | 已核实"未跟踪"这一事实（`git ls-files --error-unmatch` + `git check-ignore -v`）；**未**改 `.gitignore`（仓库结构决定） | 见 §5.5 的两个选项；在那之前该门的新判据**不入库** |
| U10 | 完整性脚本对**未跟踪**文件只能与"空 blob"比较 | `sim/snapcdc/review24/{axr,cdc}/run.bat` 打印的是 `blob 0/0` ⇒ 那两条的"既存 LF-only"**不是**由 git 证明的，而是由 §5.4 的"修复后 CRLF==0 且本次只做过单行插入"反证 | 若要 git 级证据，先把这两个文件纳入跟踪 |

---

## 7. 证据索引

| 内容 | 位置 |
|---|---|
| 规范检测器 + 九项自测 | `sim/p4gates/implicit_gate.bat` · `sim/p4gates/implicit_gate_selftest.bat` |
| 冻结的病理/干净/无关告警输入与日志 | `sim/p4gates/evidence/implicit_gate_2026-09-29/` |
| 最小复现源文件 | `_proj_10g/notes/p7b_implicit_repro/{A1_portconn,A2_expr,B1_clean,C1_benign,W1_widthmis}.v` |
| `xvlog` 原始日志（含 A1 的"全空"证据） | `_proj_10g/notes/p7b_implicit_repro/{A1_portconn,A2_expr,B1_clean,C1_benign,W1_widthmis}/xv_case.log` |
| `xelab` 原始日志（`10-3091`） | `…/{A1_portconn,B1_clean,W1_widthmis}/xelab_*.log` |
| `synth_design` 原始日志（`8-11241` / `8-36` / 无关告警） | `…/{A1_portconn,A2_expr,B1_clean,C1_benign}/synth_*.log` |
| `xvlog -sv` 对照（此路不通） | `…/{A1_portconn,B1_clean}/sv_probe*.log` |
| `findstr` 多 `/C:` 取或语义验证 | `_proj_10g/notes/p7b_implicit_repro/fs_semantics.bat`（T1/T2/T3 三段读数） |
| 改动台账（逐行 before/after） | `_proj_10g/notes/p7b_implicit_repro/apply_log.txt` · `fix_gates_changelog.txt` · `dryrun_before_apply.txt` |
| 文档改动台账 | `_proj_10g/notes/p7b_implicit_repro/docs_apply_log.txt` |
| 完整性核对 | `_proj_10g/notes/p7b_implicit_repro/verify_integrity.py` · `integrity_final.txt` |
| 真实门跑通读数 | `sim/vlansim/xvlog_tb.log` · `sim/vlansim/xelab_run.log`（本报告 §3.3 引用的那次运行） |
| 真实生产日志（无关告警对照 c2） | `board/lint_p6e/xvlog_p6e.log` |
| 前一轮已修的同族门 | `_proj_10g/xxv_loop/patch_r3.py` · `_proj_10g/xxv_loop/tcl/s2_build.tcl:126-136` |
