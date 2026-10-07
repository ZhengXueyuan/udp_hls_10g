# P7B_BID_SYNC —— `BUILD_ID_V` 9 → 0xA 的**全同步**（Stage C BID 同步轮）

- 日期：**2026-10-07**　角色：**同步 agent**　基线 HEAD = **`46b2f68`**（未提交任何东西）
- 真源（不是我改的，是构建支改的）：`board/wrapper_p4.v:3882` `.BUILD_ID_V (32'h0000000A)`；
  窗口 `SNAP_NW_P6E = 63`（`:3125`）**不变** ⇒ 本轮的变更是**纯身份**（9 → 10），几何一字未动。
- 依据 = `_proj_10g/notes/P7B_BUILD_STAGEC.md` **§2.4（四类清册）/ §2.5（最小全同步清单 (B)7+(C)2+(D)3）**。
- 纪律执行：**未烧板 / 未写 `0x08` / 未起 xsim / 未提交 git / 未 `git add -A` / 未碰 `rtl/`·`tb/`·`board/`**。
  构建窗口内 `tasklist` 无 `vivado`/`xsim`/`xelab`（见 §6 并发声明）。

---

## 0. 一句话

**同步完成**：改了 **10 个文件 / 29 处**（(B)7 + (C)2 + (D)1），**冻结 2 个**（另一支 agent 的独立复核件，见 §5），
**五个台架从夹具的角度全部恢复全绿**（15/0 · 31/0 · 19/0 · 26/0 · 14/0，与历史基线逐数相同），
`gen_inputs.py` 的**活守卫**两臂都实测（同代⇒放行 rc=0；不同代⇒`GEOM_GUARD_FAIL` rc=3 且**一个字节都不写**）。
**板侧零读数**（本轮纪律不烧板；板子上仍是 Build 2 / BID 9 —— 新默认 0xA 对旧位流是**响亮失败**，实测见 §4.3）。

---

## 1. 逐文件逐处（定位 / 改前 / 改后 / 理由）

**统一手法**：值行改数（原值写进同行或紧邻的订正块）；注释行**保留原句** + 紧邻 `⛔ 2026-10-07` 订正块；
行尾**保持原样**（改前改后都是**纯 LF**，实测 `CR=0`，见 §6-④）。
自动化：一次性脚本 `apply_bid_sync.py`（**在仓外**：`C:\Users\zhxue\AppData\Local\Temp\p7b_bid_sync\`），
**29 个锚点全部"恰好命中一次"才落盘**（全过才写 ⇒ 结构性不可能半改）——与 `p7b_wu_harness_fix/apply_*.py` 同款。

### (B) 板级取数 / 验收台架（7 个，**下一轮真会跑**）

| # | 文件 | 处 | 改前 → 改后 | 理由 |
|---|---|---|---|---|
| B1 | `_proj_pcie/p7b_gate4_accept.sh` | `:122`（原 `:115`） | `EXPECT_BID=${EXPECT_BID:-0x00000009}` → **`:-0x0000000A}`**（尾注 `P7B-WU 二轮 = 9` → `P7b Stage C = 10`；原句进订正块 `:123`） | G1 位流身份的**默认期望值**（唯一真源 = wrapper 的 `BUILD_ID_V`） |
|  |  | `:10-14`·`:59-60`·`:143` | 追加订正块（几何仍 63 字 / 0x11C；读 Build 2 需 `EXPECT_BID=0x00000009`）；`:143` 原句 `BID=9` → `BID=10`（原句保留） | 防"拿新默认读旧位流"被误读成板子坏了 |
| B2 | `_proj_pcie/p6e_snap_check.sh` | `:50`（原 `:46`） | `:-0x00000009}` → **`:-0x0000000A}`** + 订正块 | 判据 `1.2 BUILD_ID (0x04)` 的期望值 |
|  |  | `:6-9`·`:47`·`:65` | 代际清单：`9 = P7B-WU 二轮 63 字 (RTL 当前值)` → **`10 = P7b Stage C 63 字 (RTL 当前值)`**，9 降为（历史, Build 2）；`:65` 原句 `EXPECT_BID=9` → `=10` | 清单是"读哪一代"的唯一索引 |
| B3 | `_proj_pcie/p7b_biz/p7b_snap.sh` | `:44`（原 `:40`） | `:-0x00000009}` → **`:-0x0000000A}`** + 订正块 | 板侧取数器的 `id_check` 身份闸 |
|  |  | `:2-5`·`:8-9`·`:49` | 头注 `(P7B-WU 二轮: BID=9 …)` → `(P7b Stage C: BID=10 …)`；`BID 8 != 9` → `BID 8 != **10**`（原句进订正块）；旧位流覆盖表新增 `P7B-WU 二轮 63 字: EXPECT_BID=0x00000009` | 修 `p7b_snap.sh` 的"响亮失败"文案 + 补齐新老两代的覆盖配方 |
| B4 | `_proj_pcie/p7b_gate4_selftest.sh` | `:99`（原 `:95`） | `\${FAKE_BID:-0x00000009}` → **`:-0x0000000A}`** | 假板子 BID 必须与 `p6e_snap_check.sh` 的默认**同代**（否则正例判据 1.2 假 FAIL —— 源码注释逐字这么写的） |
|  |  | `:95-96`·`:14-16` | 订正块（现役 = 10；旧口径 `FAKE_BID=0x00000008` / P7B-WU 位流 `0x00000009`） | ⚠️ 这两行在**无引号 heredoc** 里 ⇒ 订正块刻意不含反引号 / `$(` / `${` |
| B5 | `_proj_pcie/p7b_gate4_livefake.sh` | `:104`（原 `:100`） | `{63:"0x00000009",…}.get(nw,"0x00000009")` → **`{63:"0x0000000A",…}.get(nw,"0x0000000A")`** | 假对端按**请求方那一代**回 BID（F-b 原则）；61/51 臂（8/7）是历史值**不动** |
|  |  | `:22-24`·`:103` | 订正块（几何不变 / 身份 9 → 10） | 同一性质 |
| B6 | `_proj_pcie/p7b_gate4_negctrl.sh` | `:55`（原 `:53`） | `echo "BID 0x00000009"` → **`"BID 0x0000000A"`**（尾注 `原 0x00000009`） | 负对照的**规范快照**必须与 accept 默认同代（否则连 clean 正对照都红 = 整套台架死掉） |
|  |  | `:32-34` | 订正块（几何 / 未实现地址不变，身份 9 → 10） | 同上 |
| B7 | `_proj_pcie/p6e_snap_selftest_fix2.sh` | `:74`（原 `:71`） | `0X04) V=0x00000009;;` → **`0x0000000A;;`**（尾注 `原值 0x00000009`） | 真锁存语义假板子的 BID；必须与 `p6e_snap_check.sh` 默认同代 |
|  |  | `:18-20` | 订正块（几何不变；读 P7B-WU 位流时 0X04 与 EXPECT_BID 必须**一起**改） | 同上 |

### (C) 与 (B) 绑死的夹具 / 守卫（2 个）

| # | 文件 | 处 | 改前 → 改后 | 理由 |
|---|---|---|---|---|
| C1 | `_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py` | `:39`（原 `:35`） | `BID_FIX = 0x00000009` → **`0x0000000A`**（尾注原值） | 它生成"规范形态"合成读数喂给 accept ⇒ 必须同代 |
|  |  | `:10-12`·`:36-37` | docstring / 注释订正块（窗口仍 63 字，只有身份变；`_geo_guard` 要求与 accept 默认同代） | ⭐ **这就是"半同步会把台架卡死"的那个活守卫**：`_geo_guard()` 读 accept 的默认值，不同代 ⇒ `exit 3` 拒绝生成 |
| C2 | `_proj_10g/notes/p7b_wu_p1p2_tools/mk_accept_offline.py` | `:56`（原 `:54`） | `"BID 0x00000009\n"` → **`"BID 0x0000000A\n"`**（尾注原值） | 离线档**正例**（不碰板）——BID 行必须与 accept 默认同代，否则"新脚本 × 旧板"的对照组自己先假红 |
|  |  | `:2-4` | docstring 订正块（原句 `63 字 / BUILD_ID=9` 保留） | 同上 |

### (D) 静态门（3 个，其中 **1 个已改 / 2 个冻结** —— 冻结理由见 §5）

| # | 文件 | 处 | 改前 → 改后 | 理由 |
|---|---|---|---|---|
| D1 | `sim/p5wu_p1p2/check_wu_words.py` | `:59`（原 `:57`）·`:15`·`:55-57` | `int(m.group(1),16) == 9` → **`== 10`**；判据名 `"2 BUILD_ID_V == 9"` → **`"2 BUILD_ID_V == 10"`**；docstring `BUILD_ID_V == 32'h9` → **`32'hA`**（原句进订正块） | 本门是**作者本门**（非复核件）；判据 2 是"代际钉"，跟着 wrapper 走；**判据 1/3..14 = WU 扩窗的逐处指纹，一字未动**（窗口仍 63 字 ⇒ 自然仍成立） |
| D2 | `sim/p5wu_p1p2_review/rev_window_check.py:170`（A7） | —— | **未改（冻结）** | **另一支 agent 的独立复核件** —— 见 §5 |
| D3 | `sim/p5wu_p1p2_review/rev_check_wu_words_copy.py:57` | —— | **未改（冻结）** | 同上 |

---

## 2. 全域 grep 清册（"还有谁读 BID / 还带 9"）

面 = 全仓 `*.sh *.py *.bat *.v *.tcl`（含未跟踪；排除 `vivado_prj/**` 与 IP 自己的 `.gen/**`）。

### 2.1 真源（唯一）

| 文件:行 | 值 | 说明 |
|---|---|---|
| `board/wrapper_p4.v:3882` | `32'h0000000A` | `axi_regs` 的 `.BUILD_ID_V` —— **构建支已改，本轮未再动**；其余所有件的期望值都该由它派生 |

### 2.2 本轮已同步（10 个，= §1 ）

`_proj_pcie/{p7b_gate4_accept.sh, p6e_snap_check.sh, p7b_biz/p7b_snap.sh, p7b_gate4_selftest.sh,
p7b_gate4_livefake.sh, p7b_gate4_negctrl.sh, p6e_snap_selftest_fix2.sh}` ·
`_proj_10g/notes/{p7b_gate4_criteria/gen_inputs.py, p7b_wu_p1p2_tools/mk_accept_offline.py}` ·
`sim/p5wu_p1p2/check_wu_words.py`

### 2.3 冻结的独立复核件（2 个，**明令不碰**）

| 文件:行 | 断言 | 复跑实测（只读，我跑的） |
|---|---|---|
| `sim/p5wu_p1p2_review/rev_window_check.py:170` | `A7 BUILD_ID_V == 9` | `[FAIL] A7 BUILD_ID_V == 9 (0000000A)` · `REV_WINDOW PASS=38 FAIL=1` · rc=1 |
| `sim/p5wu_p1p2_review/rev_check_wu_words_copy.py:57` | `ck(… == 9, "2 BUILD_ID_V == 9")` | `[FAIL] 2 BUILD_ID_V == 9 (实际 0000000A)` · `PASS=13 FAIL=1` · rc=1 |

### 2.4 期间件 / 快照（**按 §2.4(E) 不碰**，它们是"那一轮跑过的"记录）

| 文件 | 里面钉的 9 | 为什么不该改 |
|---|---|---|
| `_proj_10g/notes/p7b_board_stagea/j6_stagea.sh`（:63 等 4 处） | 默认档硬断言 `{NW=63, EXPECT_BID=0x00000009}` | Stage A 轮台架**快照**（含 `J6_GEOM_OK` 的原始语义）；下一轮若要跑 WU 阶梯，用它自己的 `J6_LEGACY_GEOM` 口径 |
| `_proj_10g/notes/p7b_wu_w54/j6_fix.sh`（:44 等 4 处） | 同上 | W54 关闸轮快照 |
| `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh`（:49 等 4 处） | 同上 | TCPREG 轮快照 |
| `_proj_10g/notes/p7b_gate4_3/final_state.sh:18-19` | `BID != "0x00000009"` ⇒ `[ABORT]` | gate4_3 轮收尾件（**注意**: 它的注释自己写"0x04 的期望值见 wrapper 的 BUILD_ID_V" ⇒ 若下一轮要用它收尾，**需显式改这一行**，见 §5-②） |
| `_proj_10g/notes/p7b_chain_cov/mut_*/wrapper_p4.v`（4 件） · `_proj_10g/notes/p7b_biz_win/neg/wrapper_p4_{patho,declpatho}.v`（2 件） | `32'h00000007` | **冻结负对照 / 变异体**（BID 7 世代）—— 变异体的**身份值本身不是被变异点**，改它等于改夹具语义 |
| `_proj_10g/notes/p7b_wu_harness_fix/{tcpreg_j6.sh, gen_inputs.py, j6_double_run.sh, logs/**}` | 9（含 `STUB_BID`） | 台架修复轮的**留档替身**（`j6_double_run.sh` 与它跑的 `tcpreg_j6.sh` 快照**成对**，动一边就把它自己弄红） |
| `_proj_10g/notes/p7b_gate4_tools/fix2/prev_round_selftest/**` | 7 | 上一轮 selftest 的**归档产物**（该台架每跑一次重写 `fix2/new_fake.sh`，`prev_round_selftest/` 是刻意留的旧代对照） |

### 2.5 非本工程 / 与本 RTL 无关

- `_proj_pcie/rtl/pcie_min_top.v:141`（`32'h1`）· `_proj_pcie/rtl/axi_regs.v` · `_proj_pcie/tb/tb_axi_regs.v:86` · `int_scratch/{neg5,negbase}/axi_regs.v` · `sim/p6e_pcie/tb_*.v` · `tb/tb_snap63.v:53` —— 各自**自持常量**（P6e 观测窗口的前身 / 独立 TB），不读 wrapper 的真源。
- `_proj_pcie/soak_scratch/soak_probe.sh:44`（`BID_EXP=0x00000006`）· `p6b_accept_final/srv_p6b_final_accept.sh`（`EXPECT_BUILD_ID=0x00000006`）—— 是 **P6b（36 字）那一版位流自己的身份**，那份位流仍在、仍需可被识别（先例：BIZ 轮"刻意未动"同款）。
- `_proj_pcie/p6b_smoke_gate.sh:17` —— 注释里写"在现役位流 (BID 9 / 63 字) 上跑"：**P6b 时代的门**，那句"现役"随本轮变成陈旧（**未改**，属"陈旧注释"，见 §5-③）。

### 2.6 同步后"仍含 `0x00000009`"的代码件（**逐条已归类，没有一条是漏改**）

- **在已同步文件里的命中**（`accept` 3 · `p7b_snap` 4 · `p6e_snap_check` 2 · `selftest` 2 · `fix2` 2 · `negctrl` 1 · `gen_inputs` 1 · `mk_accept_offline` 1）——**全部**落在两类合法文本里：
  ① `⛔ 2026-10-07 … 原句/原值 = 0x00000009` 的订正块；② **"读 P7B-WU 二轮/Build 2 位流要显式覆盖 `EXPECT_BID=0x00000009`"** 的覆盖配方（9 在那里是**正确的历史值**）。
  ⇒ 谁要复核本轮的完整性，请用**值行**判（`EXPECT_BID=${EXPECT_BID:-…}` / `BID_FIX =` / `"BID 0x…"` / `0X04) V=` / `== 10`），不要用裸 `grep 0x00000009`。
- **`0x0000000A` 的新值落点（可 grep 复核，10 处）**：`accept:122` · `p6e_snap_check:50` · `p7b_snap:44` · `selftest:99` · `livefake:104` · `negctrl:55` · `fix2:74` · `gen_inputs:39` · `mk_accept_offline:56` · `check_wu_words:59`。

---

## 3. ⭐ 冻结件会不会被"常驻入口"跑到？（**必答栏**）

**结论：不会。这 2 条不在任何常驻入口内 —— 只有人手工复跑时才会红。**

取证（逐条，可复现）：

| 入口候选 | 实测 | 出处 |
|---|---|---|
| **`sim/p4gates/run_matrix_p4dfix.bat`**（现役 16 门矩阵） | `grep -c "BID\|p5wu\|p1p2"` = **0**；声明的 16 门在 `:163-178`，逐行核过：全在 `sim\p4sim` / `sim\retxsim` / `sim\retxsim2` / `sim\vlansim` / `sim\tbgate`，**无一条**是 `sim/p5wu_p1p2*` | 该文件 `:163-178` |
| 其它 `*matrix*.bat/sh`（全仓 **21 个**：`sim/d2run` `sim/fifoasync` `sim/p4indm` `sim/p5b_*` `sim/p5d_multi` 等） | 逐文件 `grep -c "p5wu\|BID"` = **全部 0** | `find` + 逐文件 grep |
| `run_all_gates.py` 之类 | **本仓不存在**（`find -iname "run_all*"` 只命中各子系统自己的 `run_all.bat/sh`，均不涉 p5wu） | `find` + `ls *.bat *.sh`（仓根**无**入口脚本） |
| 任何 `run_*.bat` / `run_*.sh` | 提到 `check_wu_words` / `rev_window_check` / `rev_check_wu_words` 的文件**只有 5 个**：两个门自己 + `sim/p5wu_p1p2/run_xvlog_wrapper63.bat`（**仅 REM 注释**提到，不调用）+ `sim/p5wu_p1p2_review/mut/sim/p5wu_p1p2_review/rev_window_check.py`（复核件自己的**变异副本**）+ 复核件本体 | `grep -rIl` 全仓 |
| （旁证）`_proj_10g/notes/p7b_wu_harness_fix/j6_double_run.sh` —— 唯一"名字像 run_* 且带 BID 断言"的另一样本 | 它是**轮内替身台架**、不是常驻入口；它跑的 `tcpreg_j6.sh` 快照与本文件的 `STUB_BID=0x00000009` **成对**，两者都停在 9 ⇒ **自洽、不受本轮影响**（动一边反而会把它弄红 —— 这也是 §2.4 把它们整组冻结的理由） | 该文件 `:21/:40/:70` |

**判读方法（给下一个看到红的人，不用重推）**：

1. 红**恰好只在一行** —— `2 BUILD_ID_V == 9` / `A7 BUILD_ID_V == 9`，且括号里**实测**打的是 `0000000A`；
   其余判据（`PASS=13` / `PASS=38`）全绿 ⇒ **这是"代际钉"，不是回归**（窗口几何 / 接线 / WU 指纹一条没动）。
2. 要它变绿：把那两处 `== 9` / `"2 BUILD_ID_V == 9"` 改成 `== 10` / `"… == 10"` 即可（**30 秒**，逐字改法在 §5-①）。
   ⚠️ **不许**由本轮的实现方去改（那会削弱那一轮独立复核的效力）—— 要改得由**复核方或 TL** 显式授权后再动。
3. 反过来说：**若你看到的是别的判据红，那才可能是真回归**，按本工程老规矩查（`tasklist` 查文件锁 → 逐判据读日志尾）。

---

## 4. 实跑证据（**不是"读码推断"**）

全部在**本机、不碰板、不起 xsim**；`bash -n` / 内存 `compile()` / 只读门 / 台架替身。

### 4.1 语法面（10 个文件全覆盖）

```
bash -n OK  ×7  (_proj_pcie/*.sh 七个)
py compile OK ×3 (gen_inputs.py / mk_accept_offline.py / check_wu_words.py)
```

### 4.2 ⭐ 活守卫两臂（`gen_inputs.py` ←→ `p7b_gate4_accept.sh` 的"同代"配对）

| 臂 | 命令 | 结果 |
|---|---|---|
| **同代（放行）** | `python gen_inputs.py <tmp> <real_traffic>` | **rc=0**，生成 10 个 case；`clean/snap_A.txt` = **`BID 0x0000000A`** |
| **不同代（拒绝）** | 同脚本 staged 副本，只把 `BID_FIX` 改回 `0x9`；accept 用**已同步**的那份 | **rc=3**，逐字：`GEOM_GUARD_FAIL: accept 默认几何 = (SNAP_WORDS=63, EXPECT_BID=0xA), 本夹具 = (63, 0x9)` + "两者不同代…" ⇒ **且 `neg_out2/` 根本没被创建**（一个字节都没写） |

⇒ ① accept 的默认值**确实**被守卫读到（= 我的 B1 改动生效）；② 半同步会被**结构性拒绝**（这正是本轮必须全同步的原因）；③ 守卫的"拒绝"不是空口。

### 4.3 ⭐ accept 离线两臂（身份判据的"绿/红"都实测）

| 臂 | 输入 | 结果 |
|---|---|---|
| **同代** | 默认（0xA） + 刚生成的夹具（0xA） | **rc=0**；`[PASS] G1 位流身份 (块A/块B) 期望=…BID=0x0000000A… 实测=…BID=0x0000000A…`；尾行逐字 `PASS=26 FAIL=0 SKIP=0 (窗口 63 字; 未实现地址 0x11C; EXPECT_BID=0x0000000A)` |
| **拿新默认读旧代** | 默认（0xA） + 旧夹具（`0x9`） | **rc=2**；`[FAIL] G1 … 实测=…BID=0x00000009 ⇒ 不是本轮位流, 后面所有读数都不算数` + `[FATAL] 身份不符 ⇒ 拒绝继续 (G1 前置闸)` |

⇒ 板子现在装的 **Build 2 = BID 9**：用新默认去读它**会响亮失败并点名原因**（不是静默错读数）。
下一轮开工的覆盖配方 = `EXPECT_BID=0x00000009 …`（各文件头注释里都已写）。

### 4.4 ⭐ 五个台架（**改后台架必须恢复全绿** —— 与 `P7B_WU_HARNESS_FIX.md` §3 的表同款）

| 台架 | 复跑命令 | 我的读数 | 历史基线 | 判定 |
|---|---|---|---|---|
| 闸 4 负对照 | `bash _proj_pcie/p7b_gate4_negctrl.sh` | `OK=15 BAD=0` rc=0 | 15/0 | 逐数相同 |
| 判据收口（含 `gen_inputs.py` + accept） | `bash _proj_10g/notes/p7b_gate4_criteria/negctrl_fix3.sh` | `OK=31 BAD=0` rc=0 | 31/0 | 逐数相同 |
| fix2 假板子自证 | `bash _proj_pcie/p6e_snap_selftest_fix2.sh` | `OK=19 BAD=0` rc=0 | 19/0 | 逐数相同 |
| g4 假板子自证 | `bash _proj_pcie/p7b_gate4_selftest.sh` | `OK=14 BAD=0` rc=0 | 14/0 | 逐数相同 |
| live 路径假对端 | `bash _proj_pcie/p7b_gate4_livefake.sh` | `OK=26 BAD=0` rc=0 | 26/0 | 逐数相同 |

- 台架自己的产物摘要（**在仓内**，本轮由台架**重写**）：
  `_proj_10g/notes/p7b_gate4_tools/negctrl/SUMMARY.txt` · `.../p7b_gate4_criteria/logs/SUMMARY.txt` ·
  `.../p7b_gate4_tools/fix2/livefake/SUMMARY.txt` · `.../p7b_gate4_tools/selftest/SUMMARY.txt`（各带时间戳 17:16 / 17:16 / 17:22 / 17:19）。
- **livefake 里的身份证据（端到端、经真 Windows python 的 CRLF 通道）**：
  `.../fix2/livefake/full.log` 逐字 `[PASS] G1 位流身份 (块A) | 期望=MAGIC=0x50360001 BID=0x0000000A MARKER=0xdeadbeef | 实测=…BID=0x0000000A…`
  ⇒ 假对端的 `bid` 表（B5）与 accept 默认（B1）**在真传输通道里对上了**。
- 我的 stdout 捕获（仓外，供复核）：`C:\Users\zhxue\AppData\Local\Temp\p7b_bid_sync\{negctrl,criteria,fix2,g4selftest,livefake}.log`。

### 4.5 三条静态门（**只读跑**；两条冻结件给的就是"预期的红"）

| 门 | rc | 关键行 |
|---|---|---|
| `sim/p5wu_p1p2/check_wu_words.py`（**已同步**） | **0** | `[PASS] 2 BUILD_ID_V == 10 (实际 0000000A)`；`PASS=14 FAIL=0`；`CHECK_WU_WORDS_PASS` |
| `sim/p5wu_p1p2_review/rev_check_wu_words_copy.py`（冻结） | 1 | `[FAIL] 2 BUILD_ID_V == 9 (实际 0000000A)`；`PASS=13 FAIL=1` |
| `sim/p5wu_p1p2_review/rev_window_check.py`（冻结） | 1 | `[FAIL] A7 BUILD_ID_V == 9 (0000000A)`；`REV_WINDOW PASS=38 FAIL=1` |

⇒ 冻结件的红**恰好在 BID 断言行、只有 1 条**（其余 13 / 38 条全绿）——§3 的判读方法就是照这就地量的。

### 4.6 台架重写的"产物面"（**登记，非手改**）

`git status` 里那批 `M` 里，除去我改的 10 个文件，**116 个**是台架的**既定产物**（跑台架的必然结果）：

| 面 | 数量 | 差异内容（抽样实测） |
|---|---|---|
| `_proj_10g/notes/p7b_gate4_criteria/inputs/**/snap_*.txt` | 40 | **只差 `BID` 一行**（`-BID 0x00000009` / `+BID 0x0000000A`；`nic_*.txt` 不含 BID ⇒ 未变） |
| `_proj_10g/notes/p7b_gate4_tools/{fix2,negctrl,selftest,fix2/livefake}` | 76 | 各台架自己的 log / calls / rc / 快照 / 假脚本（`tree/**` = 现役 accept 的**副本**，故随本轮同步） |
| `_proj_10g/notes/p7b_gate4_criteria/logs/` | 1 | `gen_inputs.log` |

（先例 = `P7B_WU_HARNESS_FIX.md` §5-3 逐字："产物被各自的既定行为重写…`git status` 里它们出现在 M 列表属预期"。）

---

## 5. 未改项（**逐条带理由**）

### ① 冻结件：`sim/p5wu_p1p2_review/rev_window_check.py` 与 `rev_check_wu_words_copy.py`（2 处）

- **理由**：构建支 §2.4(D) 自己把这两条标注为"**另一支 agent 的独立复核件**"，而本轮派单的"⛔ 不许碰"点名禁止 ——
  **事后改它们会削弱那一轮独立复核的效力**（改的是"复核者当时断言的那个世界"）。TL 2026-10-07 明确裁定：**不要去改它们**。
- **为什么"不必改"也站得住**：它们**不在任何常驻入口**（§3 逐条实测），红是**响亮的、可归因的**（§4.5），
  且按本工程"期间门钉代"的惯例属**陈旧引用、不是回归**（先例：WU-F2F1 修复轮也明写"未碰 `sim/p5wu_p1p2_review/`（只读跑）"）。
- **若将来要改（需要复核方/TL 授权）**，逐字改法（**30 秒**）：
  - `rev_check_wu_words_copy.py:57`：`ck(m is not None and int(m.group(1), 16) == 9, "2 BUILD_ID_V == 9",` → `… == 10, "2 BUILD_ID_V == 10",`（同文件 `:15` 的 docstring `32'h9` → `32'hA`）。
  - `rev_window_check.py:170`：`ck(m is not None and int(m.group(1), 16) == 9, "A7 BUILD_ID_V == 9",` → `… == 10, "A7 BUILD_ID_V == 10",`

### ② (E) 期间件 / 快照 / 冻结夹具（§2.4 清单全部未改）

见 §2.4 表（`j6_stagea.sh` · `j6_fix.sh` · `tcpreg_j6.sh` · `final_state.sh` · `mut_*/wrapper_p4.v` ×4 · `neg/wrapper_p4_{patho,declpatho}.v` ×2 · `p7b_wu_harness_fix/**` · `prev_round_selftest/**`）。
**理由**：它们是**"那一轮跑过的"记录**（§2.4(E) 逐字"不应改"）；改了等于重写历史读数。
⚠️ **但有一条要提醒**：`_proj_10g/notes/p7b_gate4_3/final_state.sh:18` 的前置闸是 `BID != 0x00000009 ⇒ ABORT`。
若下一轮**要用它收尾**（它含通用的"网络配置复原"段），**必须先显式改这一行**（或按它的注释口径自替换）——否则它会**拒绝出读数**（设计如此，不是坏了）。

### ③ 陈旧注释（1 处，**未改**）

`_proj_pcie/p6b_smoke_gate.sh:17`："在现役位流 (BID 9 / 63 字) 上跑" —— P6b 时代的门，那句"现役"随本轮变陈旧。
**未改理由**：它不在 §2.5 的 (B)(C)(D) 清单内（不在本轮"只许改"的范围），且**不影响任何判据**（该门自己 `BID 必须 = 6`）。
⇒ 登记在此，留 TL 决定（先例：BIZ 轮把同类"陈旧注释"逐条列给 TL）。

### ④ 构建支自己的 3 个文件（`board/`、`rtl/`）—— **明令不许碰，一字未动**

`board/wrapper_p4.v`（真源 `0xA` 由构建支改）、`board/build_p7b_ku5p.tcl`、`board/run_build_p7b_ku5p.bat`。

---

## 6. 我没能做的 / 边界（**别当绿读**）

1. ⛔ **板侧零读数**：本轮纪律不烧板、不写 `0x08` ⇒ **`0x04` 实读 = 10 这件事本身没有板级证据**，
   本报告的全部证据都在**文件面 / 台架替身面**。"Build 3 位流 `1609d6f5…` 烧上去之后 `0x04` 读 10" 仍待**下一轮第一件事**验证
   （建议加一次 `bash _proj_pcie/p7b_biz/p7b_snap.sh id`，预期 `ID_OK` 且 `ID_BID 0x0000000A`）。
2. ⛔ **livefake / negctrl / fix2 / selftest / criteria 的"绿"是台架自证**，不是真板 —— 它们的假板子/假对端只复刻"读数的规范形态"。
3. ⛔ **`prev_round_selftest/` 与 `logs/**` 里的旧代产物我未逐一比对**（**抽样**核了它们**没被本轮重写**：`.../fix2/prev_round_selftest/p6e_snap_check_fake.sh` 的 mtime 仍是 09-30 09:44；其余未逐一核）。
4. ⚠️ **行尾**：10 个被改文件**改前改后都是纯 LF**（`CR=0`，脚本逐文件断言过）。
   ⚠️ 但 `git` 对其中 `.py` / `.txt` 会打 `LF will be replaced by CRLF the next time Git touches it` 的警告 ——
   **这是既存属性**（`.gitattributes`/`core.autocrlf` 的现状），**不是本轮引入**（改前同样是 LF）。⚠️ 这条与我无关，但会误导下一个人，故登记。
5. ⚠️ **我未提交 git**（按纪律）：所以"板上现役 Build 2 ↔ 源码 0xA ↔ 仓内未提交改动"三者是**并存**的，
   下一个人要先 `git status` 认清工作区（本轮新增的 `M` 见 §4.6）。
6. ⚠️ **并发声明**：我的编辑落盘于 **17:14**，实跑面在 **17:14–17:22**（台架自己的 `SUMMARY.txt` 时间戳 = 17:16/17:16/17:19/17:22）；期间 `tasklist` **零** `vivado`/`xsim`/`xelab`
   （= 我不是在别人的构建/仿真窗口里量读数的）。⚠️ 未核其它 agent 是否在同窗口写**别的目录**（按本工程惯例：`sim/*/run/` 与 `logs/` 的 mtime 是最便宜的证据）。
7. ⛔ **`(D)1` 我只做了"代际钉"那一半**：该门另一半（WU 扩窗逐处指纹）**逐字未动**，本轮复跑 `PASS=14 FAIL=0` 是**改后**的读数
   （我没有"改前"的同机读数 —— 改前它会在判据 2 上红，这是构建支 §2.4(D) 预告的性质，我**未实跑**改前态）。

---

## 7. 证据文件地图

| 路径 | 内容 |
|---|---|
| `C:\Users\zhxue\AppData\Local\Temp\p7b_bid_sync\apply_bid_sync.py` | 一次性同步脚本（29 锚点，全过才落盘）；**在仓外**，内容与 §1 表一一对应 |
| 同上 `\{negctrl,criteria,fix2,g4selftest,livefake}.log` | 五个台架的 stdout 捕获 |
| 同上 `\{check_wu_words,rev_copy,rev_window}.log` | 三条静态门的只读跑输出（含"预期红"的逐字行） |
| 同上 `\outA.log` / `\outB.log` | accept 离线两臂（rc=0 绿 / rc=2 响亮红） |
| 同上 `\inputs\` · `\neg_fixture\` · `\proj\` | 守卫两臂用的临时夹具（`proj\` = staged 树，只为让 `_geo_guard` 的相对路径解析得到） |
| `_proj_10g/notes/p7b_gate4_tools/*/SUMMARY.txt` · `p7b_gate4_criteria/logs/SUMMARY.txt` | 台架自己的产物摘要（**在仓内**，本轮重写） |
| `_proj_10g/notes/P7B_BUILD_STAGEC.md` §2.4/§2.5 | 本轮的清册与最小清单（**依据**） |

### 交接一句话

**下一轮开工第一件事**：烧 Build 3（`1609d6f5e8a119b2f88c1a57cd4776e2219f56d3d1e84f840b198555e576f3c`）→
`bash _proj_pcie/p7b_biz/p7b_snap.sh id` 应打 `ID_BID 0x0000000A`；
**任何"拿新默认读 Build 2"的操作都会响亮失败**（`ID_FAIL … 期望 BID=0x0000000A, 实测 BID=0x00000009`），
那不是坏了，是身份闸在干活 —— 要读 Build 2 就显式 `EXPECT_BID=0x00000009`。
