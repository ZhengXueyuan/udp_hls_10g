# GATE_HARDEN.md —— `gate_sinkfix.py` 加固 + 对照扩充 (2026-10-10, 门加固 agent)

> **本门判 = 源码 token/结构形态与修复一致 + （加固后）条件语义与见证同源。**
> **本门不判 = ① 编译能否通过 ② 真 Linux 上的行为 ③ 旧臂在**行为**上是否真的等于 HEAD。**

（同一段已逐字写进 `gate_sinkfix.py` 头注释；本件**不含 PASS/FAIL 裁定** —— 判据层裁定权在
判据所有者。本件只报读数与边界。）

---

## 0. 结论速览（≤20 行，每条一句；细节在对应节）

1. 【事实】加固 = 新增 **C11–C14** 四条判据（`gate_sinkfix.py`）+ 追加 **14 条对照**（`run_gate_controls.py`）。
2. 【事实】C1–C10 与 `extract_fn_body` **零行改动**：git diff 显示我方改动 = 469 insertions / **3 deletions（全是头注释行）**（§5）。
3. 【事实】REVIEW §D.1 四个逃逸件现在**全红**，且 fired 集合**恰好**是对应那条：`A→{C11}` · `C→{C11}` · `B2→{C12}` · `F→{C13}`（§2.4）。
4. 【事实】正件（工作树 .cpp）仍绿：**14/14 OK、violations=0、RC=0**（§2.2）。
5. 【事实】既有 7 对照里 **P/M1/M2/M3/M4/M5 六条与 `gate_controls.txt` 逐字相同**；**N0 一条不同** —— 原因是 HEAD 已被并行 session 推进到修复后（§2.3），**不是本次加固造成的**。（⛔ **收尾已修：见 §9** —— N0 改钉死取件后 `mismatch=0`。）
6. 【事实】代偿：追加 **N0pin**（锚定修复前提交 `61cc107`，md5 硬核 `5b6d757b…`），它复现出历史 N0 的 fired 集合 **恰为 C1..C10**（新判据在它上面是空判据 —— §2.4 给了为什么这不构成放水的组合论证）。
7. 【事实】5 个"应当绿"的等价小改全部**仍绿**（G1..G5）；其中 **G3/G5 在首版 C11 下曾是红的** ⇒ 抓到一次**过度敏感**，当日修（§4.1）。
8. 【事实】另 7 条边界探针里 6 条按语义红（else 形态 / 括号内多语句 / 括号不配平 / 见证换变量 / CLI 写 false / shadow 声明），1 条走既有 C2 假红（guard 空白改写，**既有脆性、未改 C2**）（§4.2）。
9. 【事实】探针还抓到一次**静默空判据**：helper 内花括号不配平时 C11 曾判空 ⇒ 已收紧（guard 字面量在 + body 配不平 ⇒ 判红）（§4.3）。
10. 【事实】**加固后仍逃逸**的实测形状 2 个：`X1_goto_skip`（结构完好但不可达，RC=0）、`P_EQ8`（经指针别名间接写 flag，RC=0，与 F 同语义）。
11. 【事实】`_proj_pcie/p7b_biz/p7b_tcp_sink.cpp` 逐字节未动：加固前 md5 = 加固后 md5 = `8d02ef6426d4ef6ad5fd2c514965c1e8`（§5）。
12. 【事实】`run_gate_controls.py` 整体退出码 = **1** —— 由上面第 5 条的既有 N0 失效单独造成；追加块自身 `mismatch=0`（§2.3 + §2.4）。（⛔ **收尾已修：见 §9** —— 整体 RC 现为 **0**。）
13. 【推断】C11/C12/C13 的"锚点缺失 ⇒ 空判据"不会变成"锚点没了还全绿"：三个锚点各自被既有判据钉住（C2/C6/C9）—— 组合论证，未穷举反例。
14. 【推断】控制流可达性（goto/提前 return）与间接写（别名）这两族是**结构门原则上判不到**的，不是本刀的漏改；要盖它们需要另外一类判据（§6 给了形状，未实施）。
15. 【事实】本件可复算：三条命令 + 两个证据文件（`gate_harden_positive.txt` / `gate_harden_controls.txt`）+ `%TEMP%` 探针脚本（不落仓）。

---

## 1. 本刀边界与产物清单

| 文件 | 状态 | 说明 |
|---|---|---|
| `gate_sinkfix.py` | **改**（允许区内） | 新增 C11–C14；头注释更新（判据清单 10→14 + 判/不判声明） |
| `run_gate_controls.py` | **改**（允许区内） | 追加块（14 条对照）；既有 7 条生成器/期望/循环/`run_gate` **未动** |
| `GATE_HARDEN.md` | 新建 | 本件 |
| `gate_harden_positive.txt` | 新建 | 加固后正件输出（**新文件名**，不覆盖 `gate_positive.txt`） |
| `gate_harden_controls.txt` | 新建 | 加固后对照输出（**新文件名**，不覆盖 `gate_controls.txt`） |
| `%TEMP%/sinkfix_probe_boundary.py` 等 | 不落仓 | 边界探针 + 全部突变件 |

⛔ 未触碰：`_proj_pcie/p7b_biz/p7b_tcp_sink.cpp`（§5 双核 md5）· `REPORT.md` · `REVIEW.md` · `peer_verify/`。
零板卡 / 零 Vivado / 零 xsim / 零 ssh；本机 Windows；`python` 用 `/c/Users/zhxue/anaconda3/python.exe`
（`python` 不在 PATH —— 审查者已踩过，此处照抄登记）。

---

## 2. 步骤与原始输出

### 2.1 加固前复现（先跑现状，不信转述）

```bash
$ /c/Users/zhxue/anaconda3/python.exe gate_sinkfix.py ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp
C1..C10 全 OK / GATE_SINKFIX checks=10 ok=10 violations=0 / RC=0      ← 与 gate_positive.txt 逐字相同 ✅
$ /c/Users/zhxue/anaconda3/python.exe run_gate_controls.py
P RC=0 / N0 RC=0 want=1 MISMATCH / M1..M5 各按期望 / GATE_CONTROLS cases=7 mismatch=1 / RC=1   ❌ 与描述不符
```

【事实】**与派单描述不符的两处**（按要求如实报，不迁就）：

- ① **N0 对照已失效**：脚本用 `git show HEAD:` 取"修复前版"，但 **HEAD 已在本轮之前被并行 session
  推进**（`a03d227 台架 sink 时序修复：SO_RCVBUF 落点移到 connect 之前（+开关+见证行）…`，其父
  `61cc107` = 历史 `aaf17dc` 同内容）。⇒ `git show HEAD:` 现在取到的是**修复后**文件
  （md5 `8d02ef64…`），于是 N0 ≡ P ⇒ RC=0。**这是脚本的锚点漂移，不是门的问题，也不是本次加固造成的**
  （第一次运行即如此，此时我尚未改任何文件）。
- ② 因此 `run_gate_controls.py` 的 **mismatch=1 / RC=1 是加固前的既存状态**，不是回归。（⛔ **收尾已修：见 §9**。）
- ③ 派单里"7 对照 mismatch=0"在**写下派单时**成立（`gate_controls.txt` 就是那个记录）；
  现在不再成立，原因见 ①。【推断】该 commit 与我方是并行 session（REVIEW §F.8 亦登记"此刻仓库里有别人在写"）。

### 2.2 加固后正件（命令 + RC）

命令与输出原件 = `gate_harden_positive.txt`（本件只摘汇总行）：

```bash
$ /c/Users/zhxue/anaconda3/python.exe gate_sinkfix.py ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp
C1..C10 全 OK（与加固前逐字相同）
C11 guard_direct_setsockopt  OK guards=2 direct=2
C12 witness_arg_live_value   OK arg1=rcvbuf_after_connect ? "after_connect_LEGACY" : "before_conn
C13 flag_writes_pinned       OK writes=2 decl=1 cli_true=1
C14 no_cond_preproc          OK non-include_directives=0
GATE_SINKFIX checks=14 ok=14 violations=0 file=../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp
RC=0
```

### 2.3 加固后既有 7 对照（逐字比对）

原件 = `gate_harden_controls.txt` 前半；比对脚本按"行首令牌 (P/N0/M1..M5/汇总)"抽行、把 `tmp=` 字段归一：

```
SAME  | P  working_tree_now        RC=0 want=0 OK fired=-
DIFF  | N0 HEAD_version_pre_fix    RC=1 want=1 OK fired=C1..C10   ||   RC=0 want=1 MISMATCH fired=-
SAME  | M1 guards_swapped          RC=1 want=1 OK fired=C2
SAME  | M2 default_true            RC=1 want=1 OK fired=C9
SAME  | M3 witness_removed         RC=1 want=1 OK fired=C6,C7,C8
SAME  | M4 true_revert             RC=1 want=1 OK fired=C3,C4,C5
SAME  | M5 both_arms_late          RC=1 want=1 OK fired=C2
DIFF  | GATE_CONTROLS cases=7 mismatch=0 tmp=<TMP>  ||  cases=7 mismatch=1 tmp=<TMP>
```

【事实】**6/7 逐字相同**（新判据没有改变它们的任何一条结果）；唯一差异是 N0，原因是 §2.1①。
`tmp=` 字段每次运行都不同（历史件里也如此），故比对时归一。
（⛔ **收尾后见 §9**：N0 改钉死取件，判定字段与历史件 **8/8 逐字相同**（只有名字令牌与其 `%-26s` 补齐空格不同）。）

### 2.4 追加块（新对照，逐条 fired 集合）

原件 = `gate_harden_controls.txt` 后半（⛔ **收尾后**：这里的三行 `[HARDEN-NOTE]` 已改成四行 `[ANCHOR]` 并**移到追加块之前**，追加块其余逐字不变 —— 见 §9）：

```bash
$ /c/Users/zhxue/anaconda3/python.exe run_gate_controls.py
[HARDEN-NOTE] legacy N0 anchor drifted: git show HEAD:<file> md5=8d02ef6426d4ef6ad5fd2c514965c1e8 (post-fix)
              != historical 5b6d757b17ed9b49db77c34494319264 (pre-fix)
[HARDEN-NOTE]   => in-script N0 is now equivalent to P (RC=0); this run did NOT touch it
[HARDEN-NOTE]   => compensation = appended N0pin case (pinned to pre-fix commit 61cc107, md5 verified)
---- harden block: 4 escapees + same-family bonuses (want RED) / equivalent edits (want GREEN) / known-escape probe ----
N0pin pre_fix_61cc107          RC=1 want=1 OK fired=C1,C2,C3,C4,C5,C6,C7,C8,C9,C10 want_fired=C1,C2,C3,C4,C5,C6,C7,C8,C9,C10
A_unguard_before               RC=1 want=1 OK fired=C11          want_fired=C11
C_fix_disabled_if0             RC=1 want=1 OK fired=C11          want_fired=C11
B2_witness_const_ternDEAD      RC=1 want=1 OK fired=C12          want_fired=C12
F_forces_fixed_arm             RC=1 want=1 OK fired=C13          want_fired=C13
E1_legacy_arm_if0              RC=1 want=1 OK fired=C11          want_fired=C11
P1_preproc_if0                 RC=1 want=1 OK fired=C14          want_fired=C14
Y1_rcvbufforce                 RC=1 want=1 OK fired=C11          want_fired=C11
G1 comments_blank              RC=0 want=0 OK fired=-            want_fired=-
G2 witness_reformat            RC=0 want=0 OK fired=-            want_fired=-
G3 braces_around_body          RC=0 want=0 OK fired=-            want_fired=-
G4 add_include                 RC=0 want=0 OK fired=-            want_fired=-
G5 braces+reformat             RC=0 want=0 OK fired=-            want_fired=-
X1_goto_skip KNOWN-ESCAPE      RC=0 want=0 OK fired=-            want_fired=-
GATE_CONTROLS_HARDEN cases=14 mismatch=0
```

对照的**精确性要求**：每条红案的期望是"RC=1 **且 fired 集合精确等于**该表"（`tuple(fired)==tuple(want_fired)`），
偏一条即 MISMATCH —— 即"不许靠全红蒙混"。
`N0pin` 的取值有**前置硬门**：`git show 61cc107:` 的 md5 必须 `== 5b6d757b17ed9b49db77c34494319264`，
不符则拒跑，不许拿错件当对照。（⛔ **收尾后**该硬门与 `N0` **共用** `fetch_pre_fix_pinned()`，
拒跑退出码由 `9` 统一为 `2` —— 见 §9.3/§9.4。）

**为什么新判据在 N0pin 上是空判据而不算放水**（组合论证，【推断】级、未穷举反例）：
C11 的锚点 = `if (!rcvbuf_after_connect)` 字面量 = C2 的 `gb`；C12 的锚点 = 见证 printf 标记 = C6 的字面量；
C13 的锚点 = 声明行 = C9 的字面量 ⇒ **锚点真没了，既有的牙会响**（N0pin 实测 fired 恰为 C1..C10 即此）。

### 2.5 四个逃逸件的逐字 diff（证明突变确为 REVIEW §D.1 描述的形状）

```diff
--- A_unguard_before（旧臂也变 connect 前设；guard 文本保留）
     if (!rcvbuf_after_connect)               // 默认 (修复后): 抢在 SYN 之前落位
-        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
+        ;
+    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
--- C_fix_disabled_if0（修复被 if (0) 静默禁用）
-    if (!rcvbuf_after_connect)               // 默认 (修复后): 抢在 SYN 之前落位
+    if (!rcvbuf_after_connect) {   // 默认 (修复后): 抢在 SYN 之前落位
+        if (0)
         setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
+    }
--- B2_witness_const_ternDEAD（见证打常量；三元留死码）
-    printf("SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\n",
-           rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect", rcvbuf);
+    if (0) { const char *dead_arm = rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect"; (void)dead_arm; }
+    printf("SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\n", "before_connect", rcvbuf);
--- F_forces_fixed_arm（调用点把 flag 钉死）
         //   (旧 :306 的 `setsockopt(fd, SOL_SOCKET, SO_RCVBUF, ...)` 已移进本函数)
+        rcvbuf_after_connect = false;
         int fd = sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why);
```

---

## 3. 新增判据（C11–C14）的形状与容差边界

| 判据 | 判什么 | 容差（明确允许） | 不容差（会红） |
|---|---|---|---|
| **C11** `guard_direct_setsockopt` | 每个 flag guard（`!` 与正极性两种）的**直接体**逐字是那条 SO_RCVBUF setsockopt | guard 内部空白；`setsockopt` 各 token 间空白；**可选的一对配对花括号**（`if (g) { setsockopt(...); }` 允许） | `;` 空体 / `if (0)` 嵌套 / 括号内多一条语句 / 括号不配平 / `SO_RCVBUFFORCE` 或换 `&rcvbuf` 等 token 替换 |
| **C12** `witness_arg_live_value` | 见证 printf 的**第一个实参**逐字 = `rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect"` | 任意空白/换行（call 可重排行；三元内部空白也容忍） | 打常量 / 换变量 / 加括号包裹 / 三元只在死码里 |
| **C13** `flag_writes_pinned` | 对 flag 的**写**只许两处：声明行 + `--rcvbuf-after-connect` 解析行；后者必须 `= true` | 声明行的初值取值不限（那是 C9 的事） | 任何第三处直接赋值（含 `= false` 钉死、CLI 写 false、shadow 局部声明） |
| **C14** `no_cond_preproc` | 全文件除 `#include` 外无其它预处理指令 | 任意 `#include`（含新增） | `#if 0` / `#ifdef` / `#define` / `#pragma` … 任何非 include 指令 |

【事实】C14 的定义依据 = 本文件实测 **16 行预处理全为 `#include`，0 条件指令**（工作树版与修复前版皆是）。
【推断】若将来本文件真要用条件编译，C14 会先红——那时应改判据而不是改文件（本门作用域声明在先）。

---

## 4. 反噬检查（逐条留原始输出）

### 4.1 (d) 应当绿的等价小改 —— 5 条全绿；其中 2 条曾抓到我自己的过度敏感

```diff
--- G3_braces_around_body（guard 体加一对配对花括号，语义等价）
-    if (!rcvbuf_after_connect)               // 默认 (修复后): 抢在 SYN 之前落位
+    if (!rcvbuf_after_connect) {   // 默认 (修复后): 抢在 SYN 之前落位
         setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
+    }
--- G5 = G3 + G2（见证 printf 重排行，三元逐字保持单行）
+    printf(
+        "SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\n",
+        rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect",
+        rcvbuf);
```

【事实】**首版 C11 对 G3/G5 判红**（`C11 ... VIOLATION guards=2 direct=1; L232`）—— 原因是花括号模式
`(?P<b>\{)?` 前面漏了 `\s*`，guard 的 `)` 与 `{` 之间的空格使匹配失败。当日修（见 gate 源码注释）。
这正是 (d) 要求的那类检查：**没有绿色对照，这个假红会一直躺在门里**。
其余绿件：G1（加注释/空行×3 处）、G4（加 `#include <stdint.h>`）→ RC=0、fired 空。

### 4.2 边界探针（一次性，`%TEMP%`，非常驻对照）

```bash
$ /c/Users/zhxue/anaconda3/python.exe %TEMP%/sinkfix_probe_boundary.py
P_EQ1_guard_spacing          RC=1 fired=C2            # `if ( ! rcvbuf_after_connect )` 等价空白改写
P_EQ2_else_form              RC=1 fired=C11           # `if (g) ; else setsockopt(...)` 条件反用
P_EQ3_extra_stmt_in_brace    RC=1 fired=C11           # `{ setsockopt(...); *why = 0; }` 括号内多语句
P_EQ4_unclosed_brace         RC=1 fired=C11           # 括号不配平（修前 RC=0，见 4.3）
P_EQ5_witness_other_var      RC=1 fired=C7,C12        # 见证三元换变量（同值不同源）
P_EQ6_cli_writes_false       RC=1 fired=C13           # CLI 行写 false ⇒ 开关接住但永不生效
P_EQ7_shadow_local_decl      RC=1 fired=C13           # 新增 shadow 局部 bool 声明（decl=2）
P_EQ8_alias_indirect_write   RC=0 fired=-             # 指针别名间接写 flag ⇒ **仍逃逸**（见 §6）
```

【事实】P_EQ1 的红走的是**既有 C2**（`gb=-1`：C2 是逐字判据，对 guard 空白敏感）⇒ 这是**既有脆性**，
不是我引入的；按派单"不改 C1–C10 语义"，**未改 C2**，登记为"等价空白改写会被整体判红"的已知代价。
（C11 自己对这种写法是宽容的，但整体判决由 C2 决定。）

### 4.3 (发现) 静默空判据 —— 已收紧

【事实】P_EQ4（helper 内插一个**不配平**的花括号）修前 **RC=0 全绿**：原因是 C11 用花括号配平截取 helper，
配不平 ⇒ `body=None` ⇒ 按"锚点缺失"定义判 vacuous OK；而既有 C1/C2 用的是另一套截取
（`src.find("\n}\n")`），在这形态下**照样通过** ⇒ 那条"锚点缺失时 C1/C2 会响"的兜底**在此形态下不成立**。
修法 = 收紧：**guard 字面量存在 + body 配不平 ⇒ C11 判红**（"判据不可评"而非"通过"）。
修后 P_EQ4 走 C11 红；N0（连 helper 都没有）不受影响，fired 仍恰为 C1..C10（§2.4）。

---

## 5. 既有机制与 .cpp 的未动证明

```bash
$ git -C . diff --stat HEAD -- .../gate_sinkfix.py .../run_gate_controls.py
 gate_sinkfix.py        | 216 ++++++++++++++++-      # 214 增 / 2 删
 run_gate_controls.py   | 256 +++++++++++++++++-     # 255 增 / 1 删
# 3 处删除逐字 = 头注释行（'# 判据 (10 条…)' / '# 退出码…' / '# 退出码: 0 = 全部对照…'）
$ md5sum _proj_pcie/p7b_biz/p7b_tcp_sink.cpp      # 加固前与加固后各一次
8d02ef6426d4ef6ad5fd2c514965c1e8  (前 = 后, 逐字节相同)
```

| 问 | 答 |
|---|---|
| 动过 `extract_fn_body` 吗？ | **没有**（一字未动）。新判据用**另写的** `extract_fn_body_balanced`（花括号配平 + 跳字符串），两者并存互不影响。 |
| 动过 C1–C10 的代码块吗？ | **没有**。新块整段插在 C10 之后、`n_ok=0` 之前。 |
| 动过既有 7 对照的生成器/期望/循环吗？ | **没有**。只在其后**新增** `run_harden_controls()`；`main()` 尾部只**插入** 4 行汇总（`bad_h`），原 `return` 行文本未变。 |
| 动过既有 `run_gate` 吗？ | **没有**。追加块自带 `run_gate_h`（显式 UTF-8 双向）——【事实】既有 `run_gate` 在环境变量 `PYTHONIOENCODING=utf-8` 时会因子/父编码不一致而 `UnicodeDecodeError`（本次实测踩到一次），那是**既存脆性**，我未改它，只在自己的块里绕开。 |
| `.cpp` 改了吗？ | **没有**。md5 逐字相同（上表）。 |

---

## 6. 明示：加固后**仍逃逸**的形状（实测 / 推断分列）

- 【事实·实测】`X1_goto_skip`：guard 与 setsockopt 结构**一字未动**，但在其**前面**插一行 `goto x_skip_before_fix;`
  并在其后加标签 ⇒ 修复**不可达**，RC=0，全绿。**控制流可达性不在本门作用域内**（头注释第 ②/③ 条同族）。
- 【事实·实测】`P_EQ8`：`bool *x_force = &rcvbuf_after_connect; *x_force = false;` 插在调用点前 ⇒ 与 F **同语义**
  （开关永不生效），但 C13 判的是"直接赋值文本" ⇒ RC=0 逃逸。
- 【推断·未实测】同族的其它形状：提前 `return` 绕过、把 flag 塞进结构体/闭包后再写、
  经 `memcpy`/`memset` 批量写。列表未穷举 —— **"未观测到" 不等于 "不存在"**。
- 若要盖它们（未实施，供裁定）：C13 可由"黑名单直接写"改成"白名单用法点"（枚举 flag 的合法出现行：
  声明 / CLI / 两个 guard / 见证 / 调用点 / 形参），代价是**任何新增的合法使用点都会红**（例如调试打印）——
  在"假红比漏判更贵"的口径下，本刀**没做**这一步。

---

## 7. 逐条回答派单的问题

1. **4 个逃逸件现在都红了吗（逐个 fired 集合）？** 都红了，且**恰好**各自对应：
   `A_unguard_before → {C11}` · `C_fix_disabled_if0 → {C11}` · `B2_witness_const_ternDEAD → {C12}` ·
   `F_forces_fixed_arm → {C13}`（A 与 C 共用的正是 REVIEW §D.1 末尾推荐的那一条形状："guard 之后紧接的
   语句就是该 setsockopt 且无嵌套条件"）。同批还红：`E1_legacy_arm_if0 → {C11}`（对称件）、
   `P1_preproc_if0 → {C14}`、`Y1_rcvbufforce → {C11}`；**期望绿件无一被误伤**（G1..G5 全绿）。
2. **有没有新发现的、加固后仍逃逸的形状？** 有两条**实测**（§6：goto 绕过、指针别名间接写），
   另加 §4.2 的一条**假红**（等价空白改写走既有 C2）与 §4.3 的一条**已修**的空判据。
3. **动过 `extract_fn_body` 或其它既有机制吗？** 没动 `extract_fn_body`、没动 C1–C10、没动既有
   7 对照与 `run_gate`；git diff 的全部删除 = 3 行头注释（§5 有逐条清单）。新判据另写配平截取函数。
4. **`.cpp` 的 md5 改前改后是否逐字相同？** 相同：两次都是 `8d02ef6426d4ef6ad5fd2c514965c1e8`。

## 8. 复算命令（三条）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_sinkfix_20261010
/c/Users/zhxue/anaconda3/python.exe gate_sinkfix.py ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp   # 14/14, RC=0
/c/Users/zhxue/anaconda3/python.exe run_gate_controls.py                                          # 追加块 mismatch=0; 整体 RC=1 (N0 漂移, 见 §2.1)
md5sum ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp                                               # 8d02ef6426d4ef6ad5fd2c514965c1e8
```

---

## 9. 收尾（2026-10-10，同一门加固 agent）：N0 锚改钉死

**背景（照实复述派单）**：§0-5/§2.1 报的 N0 锚漂移属实 ⇒ `GATE_CONTROLS` 常红
（`mismatch=1` / 整体 `RC=1`）。**常红的判据等于没有判据**（一个永远失败的对照会训练下游忽略红灯），
所以必须修 —— 理由不是"它错了"，而是它**不再有判别力**。

**选路（二选一）：选 ①「让 N0 走同一条钉死取件路径」，不选 ②「标 superseded 只跑 N0pin」。**
理由：① 保留 N0 在既有块**原位**（`cases` 仍是 7 条、期望仍是 `RC=1 / fired=C1..C10`），
把"取哪份文件"从随 `HEAD` 漂移改为**提交 `61cc107` + 内容 md5 `5b6d757b…` 双钉**
⇒ 判定字段与历史件**逐字相同**（§9.2），且**强度只增不减**（原版无内容校验）；
② 会让既有块少一条、`cases=7` 变 6、历史可比性下降，收益为零。

### 9.1 改前 / 改后（原始末行，逐字）

```text
# 改前（本收尾轮起点；加固轮收口时的原始输出末两行 + RC）
GATE_CONTROLS cases=7 mismatch=1 tmp=C:\Users\zhxue\AppData\Local\Temp\sinkfix_gate_tm9odh4b
GATE_CONTROLS_HARDEN cases=14 mismatch=0 tmp=C:\Users\zhxue\AppData\Local\Temp\sinkfix_gate_harden_zydrr6bs
RC=1

# 改后（本次落盘证据 gate_harden_controls.txt 的原始末行，逐字）
GATE_CONTROLS cases=7 mismatch=0 tmp=C:\Users\zhxue\AppData\Local\Temp\sinkfix_gate_6jpmdob8
[ANCHOR] N0/N0pin share ONE pinned fetch: commit 61cc107, md5=5b6d757b17ed9b49db77c34494319264 verified (== historical pre-fix value)
[ANCHOR]   why pinned: HEAD advanced to the post-fix commit a03d227; the old `git show HEAD:` fetch
[ANCHOR]   made N0 permanently green (a control that never turns red = no control).
[ANCHOR]   current HEAD md5=8d02ef6426d4ef6ad5fd2c514965c1e8 (diagnostic only; NOT what N0 reads)
GATE_CONTROLS_HARDEN cases=14 mismatch=0 tmp=C:\Users\zhxue\AppData\Local\Temp\sinkfix_gate_harden_4es9l3ly
RC=0
```

（`[ANCHOR]` 四行**在追加块之前**、旧汇总行**之后** ⇒ 旧块的前 8 行仍与历史件对齐。）

### 9.2 与历史件 `gate_controls.txt` 的逐字比对（收尾后）

```text
N0 raw:  old = N0 HEAD_version_pre_fix    RC=1 want=1 OK fired=C1,C2,C3,C4,C5,C6,C7,C8,C9,C10
N0 raw:  new = N0 pre_fix_pinned_61cc107  RC=1 want=1 OK fired=C1,C2,C3,C4,C5,C6,C7,C8,C9,C10
判定字段逐字比对 (N0 名字归一 + 空白折叠): lines=8 diff=0
```

【事实】8 行（P/N0/M1..M5/旧汇总）**判定字段 8/8 相同**：唯一不同的只有 **N0 的名字令牌**
（`HEAD_version_pre_fix` → `pre_fix_pinned_61cc107`）与它带出的 `%-26s` 补齐空格。
**名字改的理由（不是美化）**：判据的名字必须与它的取件一致 —— 留 "HEAD" 而实际不读 HEAD，
就是本工程反复抓过的那类"措辞被下游当权威照抄"的坑。

### 9.3 N0pin 强度（派单要求：不许降低）

- 【事实】`N0pin` 的期望未动：`fired` 仍**恰为 C1..C10**（§9.1 原始行 + §2.4）。
- 【事实】md5 硬核**仍在**，且从"追加块自己的前置门（`return 9`）"上移到**共用取件函数**
  `fetch_pre_fix_pinned()`（提交 + md5 双钉，不符即 `return 2` 拒跑）—— **N0 也因此第一次有了内容校验**
  ⇒ 相对加固前/收尾前**只增不减**。
- 【事实】`N0pin` 与 `N0` 现在共用同一份取件（不再各取一次），`hcases` 仍 14 条、全部 mismatch=0。

### 9.4 本轮改了什么 / 没改什么

| 项 | 状态 |
|---|---|
| `gate_sinkfix.py` | **未动**（本收尾轮一字未碰；正件复跑仍 14/14、violations=0、RC=0） |
| `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp` | **未动**：md5 收尾前 = 收尾后 = `8d02ef6426d4ef6ad5fd2c514965c1e8` |
| `gate_controls.txt` | **未覆盖**（加固前历史记录，原样保留） |
| `gate_harden_controls.txt` | **重写**（新文件头注明"本次改动 = N0 锚改钉死；历史记录见 `gate_controls.txt`"） |
| `run_gate_controls.py` 的 7 条对照 | 期望/生成器/循环**未动**；只改 N0 的**取件路径**与**名字** |
| `run_gate_controls.py` 的 14 条追加对照 | **未动**（逐条 fired 集合与 §2.4 相同） |
| 退出码语义 | `9`（追加块前置拒跑）取消 ⇒ 取件失败统一为 `2`（纯代码路径简化，**无期望被放宽**） |

【事实】本轮 `git diff` 的全部删除行 = 被我**替换掉的实现**：旧 `git show HEAD:` 取件块（main 4 行 +
追加块 11 行）、3 行 `[HARDEN-NOTE]`、旧 case 名 1 行、旧 `9` 退出码 1 行、两处头注释行 —— **没有删除任何
一条对照的期望或断言**。

### 9.5 收尾后仍未收口（与 §6 同，重申不扩大）

- 【事实·实测】`X1_goto_skip`（结构完好但不可达）与 `P_EQ8`（指针别名间接写 flag）**仍逃逸**（RC=0）。
- 【事实·实测】`P_EQ1`（guard 等价空白改写）仍走**既有 C2** 假红（按派单"不改 C1–C10 语义"，未改 C2）。
- 【推断】本件仍**不含**任何 PASS/FAIL 裁定；本门的判/不判声明（顶部）继续有效。
