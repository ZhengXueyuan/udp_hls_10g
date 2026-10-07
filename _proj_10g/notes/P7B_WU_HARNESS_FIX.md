# P7B-WU 台架修复轮 —— **测量台架的静默错读数缺口收口**

- 日期：**2026-10-07**　角色：**台架修复 agent**　基线 HEAD = **`95c9485`**（工作区另有他支未提交改动）
- 依据（两轮独立取证在同一点会合）：`P7B_WU_P1P2_REVIEW.md` **F3 §10.1/§10.2/§10.4** +
  `P7B_WU_P1P2_REGRESSION.md` **§5 / §5.3 / §7-⑥** + `P7B_WU_P1P2_TOOLS.md` **§8-3/4/5**
- 纪律：**未烧板、未起 xsim/Vivado**；板侧**一次都没碰**（本机 **没有 `PEER_PW`** ⇒ 连 sudo 都做不了 ⇒
  reg_rw 读不了 `/dev/xdma0_user`）⇒ 所有"跑一遍"都用**替身**做，替身条件逐条写明；末节列清"没能证明的"。
- **未提交 git**；未改 `rtl/` `board/` `tb/`；未碰 `p7b_snap.sh`（实测 md5 仍 `6282843073c3…`，= 并发轮 09:06 版）。

---

## 0. 一页速查（每条都有**修前/修后实际输出**，命令在 §6）

| # | 文件 | 修前 | 修后 | 证据 |
|---|---|---|---|---|
| ① | `tcpreg_j6.sh` · `j6_fix.sh` | t0/t1 只读 `5 53 54`（**结构性不读 W61/W62**）；`NW=${NW:-61}` 只用于打印标签、**没 export** ⇒ 覆盖办法失效、且"记录错几何不报错" | 默认 **NW=63 + export**；**几何门**（(NW,BID) 成对断言 + `p7b_snap.sh id`），不符 **exit 3**；t0/t1 = **`5 53 54 61 62`**；旧几何必须显式 `J6_LEGACY_GEOM=1` | 替身 **OK=27 BAD=0**（`logs/j6_double_final.txt`） |
| ② | `p7b_biz_win/apply_c.py`（+`apply_b/apply_fixups/apply_script_updates`） | 历史补丁生成器，**无守卫**；实测今天重跑会 MISS 退出，但那是**字符串巧合**，且 `sub()` **逐文件落盘**（可留半改） | 加**硬守卫**：现役 `SNAP_NW_P6E` 必须 = 本件的 pre-state（59/57/57/55），否则 `GUARD_REFUSE` + **exit 3**、**一个字节都不写** | 干跑四件全 `GUARD_REFUSE … = 63`（`logs/dryrun_after_guard.txt`） |
| ③ | `p7b_gate4_negctrl.sh` · `p7b_gate4_livefake.sh` · `p6e_snap_selftest_fix2.sh` · `gen_inputs.py` | 夹具停在 51 字 / BID 8 ⇒ 自检台架**假红**（整套反例台架死掉） | 同步 **63 字 / BID 9 / 未实现 0x11C**；`gen_inputs.py` 另加**代际守卫**（与 accept 默认几何不同代 ⇒ 拒绝生成） | negctrl **0/15 → 15/0**；livefake **4/22 → 26/0**；fix2 **5/14 → 19/0**；criteria **0/31 → 31/0** |
| ④ | `p6b_smoke_gate.sh` | 打 `[FAIL] A1b` + `[FATAL] 拒绝继续`，末行却 **`冒烟门: PASS`**、**rc=0**；`ID_BAD` 设了从未被读 | 末行按真实判定改打 **`冒烟门: FAIL`**、**rc=7**，并点名根因；**仍读完 A3/A4**（归因纪律保留） | 替身 **OK=8 BAD=0**（`logs/smoke/`） |

**本轮新发现（3 条真缺陷，全部已修 + 有 before/after）**：
**(F-a)** `p7b_gate4_livefake.sh` 的假对端用默认 `open()` 写调用日志 ⇒ Windows **GBK** 编码遇到远端文本里的
`⚠` 直接 `UnicodeEncodeError` **崩掉整个台架**（22 条假红，**与几何无关**）；
**(F-b)** 同一假对子的几何必须**按"请求方那一代"**回（老臂 pre_fix2 = 51 字 / BID 7），
"一刀切 63" 会**反向**打断老臂；
**(F-c)** `mk_run_neg.py` 变异体的**第二处 replace 没有断言**（锚点消失 ⇒ 变异体静默退化成"与真文件一样"
⇒ 负对照假通过）。

---

## 1. ① j6 台架必须能读新字（用户决策 3 的全部目的所系）

### 1.1 逐处（`tcpreg_j6.sh`；`j6_fix.sh` 同款逐字）

| 处 | 修前 | 修后 |
|---|---|---|
| 用法注释 `:5-6` | `用法: NW=61 bash …` / `⚠️ NW 默认 61 (BIZ 位流)` | `用法: bash …`；写明默认 **63/BID 9**，读旧位流必须 `J6_LEGACY_GEOM=1 NW=61 EXPECT_BID=0x00000008` |
| 头部新增 `⑥⑦` 段 | —— | ⑥ t0/t1 也读 W61/W62；⑦ 几何门；并**点名**原 `NW=${NW:-61}` 没 export 的事实 |
| `:53` 附近（标签） | `echo "### PHASE pre_snapshot … NW=${NW:-61}"` | `NW=${NW:-63}` + **`export NW EXPECT_BID`** + 只认两套显式几何（缺省 `{63,0x9}`；`J6_LEGACY_GEOM=1` ⇒ `{61,0x8}`），其余 **exit 3** |
| 新增 `PHASE geom_gate` | 无（`snap` 子命令**根本不调 `id_check`** ⇒ 身份/几何无人核） | `BID0=$(brd 0x04)` 与声明值**成对断言** + `bash "$S" id`（含本轮新加的 UNIMPL 断言）；通过打 `J6_GEOM_OK …` |
| 元数据 | 只有 `J6META_*` | 加 `J6META_NW/EXPECT_BID/LEGACY/T0T1_WORDS`（**几何进原始件**） |
| `t0` / `t1` | `bash "$S" snap "${TAG}_t0" 5 53 54` | `… 5 53 54 $WEXTRA`（63 字档 `WEXTRA="61 62"`；legacy 档为空） |

### 1.2 替身证据（**逐字**，`logs/j6_double_final.txt`）

替身 = `/tmp/p7b_biz/p7b_snap.sh` 桩（把 argv + 它**实际看到的 `NW` 环境值**记进 `calls.txt`）
+ 假 `reg_rw`（只回 0x04 = 可注入的 BID）+ 假 `tcpdump/ss`；**台架本体一字未改地跑**。

```
# 改前副本（scratch 里的原版）——缺口真的存在:
  [OK] G1 改前: t0 字表只有 5 53 54, 且取数器收到 **NW=<unset>**
          STUB_SNAP_CALL|NW=<unset>|snap before_default_t0 5 53 54     ← "覆盖办法失效"的直接证据
  [OK] G3 改前: 却把 NW=61 写进日志 (记录错几何)          命中 'NW=61'
  [OK] G4 改前: BID=8 的板子照样跑到底 (静默)             rc=0
# 改后 —— 默认档:
  [OK] A2 几何门通过                                J6_GEOM_OK NW=63 BID=0x00000009
  [OK] A4 替身收到的 t0 字表(+NW 真的传过去了)      STUB_SNAP_CALL|NW=63|snap default_t0 5 53 54 61 62
  [OK] A5 替身收到的 t1 字表                        STUB_SNAP_CALL|NW=63|snap default_t1 5 53 54 61 62
  [OK] A7 元数据行带几何                            J6META_NW=63 J6META_EXPECT_BID=0x00000009
# 改后 —— 反例(三挡全响):
  [OK] B1/B2/B3 板侧 BID=8 而台架按 63 字跑 ⇒ rc=3 + J6_GEOM_FAIL + 不再往下跑
  [OK] D1/D2   NW=61 但没 legacy 声明       ⇒ rc=3 + "默认档要求 NW=63"
  [OK] E1/E2   取数器身份闸不过(id rc=1)    ⇒ rc=3 + "取数器身份闸未过"
# 改后 —— legacy 档(负对照臂要用):
  [OK] C1..C4  rc=0 + J6_GEOM_LEGACY 醒目行 + 字表退回 "5 53 54" + 取数器看到 NW=61
########## j6 替身汇总: OK=27 BAD=0 ##########
```

**为什么留 legacy 档**：J6-ladder 的负对照臂 = **缺陷位流 `d20c08c9…5ed5`（BIZ / 61 字 / BID 8）**
（`P7B_BIZ_PLAN.md` §4.1b）；一刀切换成 63 会让那一臂的 t0/t1 **读不到字**（W61/W62 在旧板上是 SLVERR），
反而把负对照臂打断。⇒ 缺省**硬断言 {63,9}**、旧几何**必须显式声明**且打醒目行。

---

## 2. ② `apply_c.py` 是地雷 ⇒ 硬守卫（并顺带查清整族）

### 2.1 干跑：**"重跑会不会打回旧版本"用实测回答，不靠读代码**

`_proj_10g/notes/p7b_wu_harness_fix/dryrun_apply.py` 把 `io.open` 的**写模式**打成一律抛异常
⇒ 脚本若走到写盘就会 `WRITE-ATTEMPTED`，锚点 MISS 则脚本自己 `sys.exit("MISS…")`。

```
# 修前（logs/dryrun_biz_win.txt）:
  apply_b.py              → SystemExit => MISS[wrapper] … "// 字宽 57 …"      (不写盘)
  apply_c.py              → SystemExit => MISS[wrapper] … "// 字宽 59 …"      (不写盘)
  apply_fixups.py         → SystemExit => MISS in p6e_snap_check.sh …         (不写盘)
  apply_script_updates.py → SystemExit => MISS in p7b_gate4_accept.sh …       (不写盘)
  mk_run_neg.py           → RuntimeError => WRITE-ATTEMPTED run_neg.bat       (**会写**)
```

⚠️ **对审查 F3 的一处订正（如实）**：审查写"重跑 `apply_c.py` 会把 61 字版**贴回 RTL**"；
**实测今天重跑会在第一个锚点 MISS 退出、不写盘**（`TOOLS.md` §8-9 的同款判断**成立**）。
但那**不是设计的守卫、是字符串巧合**；而且 `sub()` 是**逐文件**落盘 ⇒ 只要"前几个文件命中、
后面某个 MISS"就会留下**半改**状态（比全不写更坏）。⇒ 加守卫仍然必要。

### 2.2 修法：pre-state 硬守卫（四件）

每件在 `sub()` 之后加同一段（只差 pre-state 值）：

```python
def _guard_prestate():
    w = 'board/wrapper_p4.v'
    s = io.open(w, encoding='utf-8', newline='').read()
    m = re.search(r'localparam\s+SNAP_NW_P6E\s*=\s*(\d+)\s*;', s)
    got = int(m.group(1)) if m else -1
    if got != 59:                      # apply_c: 59; apply_b/apply_fixups: 57; apply_script_updates: 55
        sys.stderr.write("GUARD_REFUSE: %s 的 SNAP_NW_P6E = %s (期望 pre-state = 59). …" % (w, got))
        sys.exit(3)
_guard_prestate()
```

**守卫的语义 = "本件只属于那一代"**（几何是唯一那把自己会变的尺子）：

| 文件 | pre-state | 依据 |
|---|---|---|
| `apply_b.py` | NW = **57** | 首锚点 `// 字宽 57 … 51 → 57` |
| `apply_c.py` | NW = **59** | 首锚点 `// 字宽 59 … 51 → 59` |
| `apply_fixups.py` | NW = **57** | 它补的 W51..W56 标签 = 57 字那一代 |
| `apply_script_updates.py` | NW = **55** | 它把"板侧 **55** 字"改成 57（55 从未出厂） |

### 2.3 修后实测（`logs/dryrun_after_guard.txt`，逐字）

```
GUARD_REFUSE: board/wrapper_p4.v 的 SNAP_NW_P6E = 63 (期望 pre-state = 57).
  本脚本只适用于窗口 57 -> 59 那一代; 现役窗口已不是那一代
  => 拒绝执行, 未写任何文件 (防止把旧一代文本贴回现役件).
  …
  RESULT: SystemExit => 3        ×4（四件都 exit 3；mk_run_neg 仍写 run_neg.bat = 它的本职）
```

### 2.4 顺带查清：`p7b_biz_win/` 里还有没有别的"重跑会打回旧版本"的脚本

| 文件 | 干跑结果 | 判定 |
|---|---|---|
| `apply_b.py` / `apply_fixups.py` / `apply_script_updates.py` | 同族（改脚本几何/文案） | **同类地雷** ⇒ 已加守卫 |
| `check_window.py` | 只读静态核对（exit code = 判据） | 无写盘，**非地雷** |
| `mk_run_neg.py` | **会重写** `run_neg.bat` + `neg/` 三个变异体 | **不是回退**（产物是测试件），但**两处静默**已修：① 第二处 `str.replace` 无断言 ⇒ 加 assert；② 三个变异体逐个断言 `!= 真文件`（否则负对照假通过） |

---

## 3. ③ 三个测试替身（+ `gen_inputs.py`）→ 63 字 / BID 9

四者的修法一致：**夹具几何必须与 accept/check 的默认几何同代**，
`51 字 / BID 8 / 未实现 0xEC` ⇒ **`63 字 / BID 9 / 未实现 0x11C`**。

| 文件 | 逐处 | 修前 | 修后（实测） |
|---|---|---|---|
| `p7b_gate4_negctrl.sh` | `gen_snap` 的 `V=(…)` 补 12 个 0（W51..W62）；`for i<51`→`<63`；`BID 8`→`9`；`shift1` 的 `-v NW=51`→`63` | `########## 负对照汇总: OK=0 BAD=15 ##########` rc=1（**连 clean 正对照都红** = 整套台架死掉） | `OK=15 BAD=0` rc=0（与它的历史基线同数） |
| `p7b_gate4_livefake.sh` | 假对端 `W[…]` 补 `[0]*12`；`range(51)`→`range(nw)`；`BID` 与 `nw` **自适配**（见 F-b）；`open()` 显式 `encoding="utf-8"`（F-a） | `OK=4 BAD=22`（rc=1）——22 条**假红**，其根因**不是几何**而是 GBK 崩 | `OK=26 BAD=0` |
| `p6e_snap_selftest_fix2.sh` | 假 `reg_rw`：`0X04` 8→9；未实现地址 `0XEC`→**`0X11C`**（`0XEC` 归 `*)`=0，即 W51 的真值） | `OK=5 BAD=14`（case ① 正对照红） | `OK=19 BAD=0`（含 ②③④ 三个负对照与两个旧版对照） |
| `gen_inputs.py` | `snap_words` `[0]*51`→`[0]*NW_FIX(63)`；`BID 0x00000007`→`0x%08X % BID_FIX(9)`；**新增 `_geo_guard()`**：读 accept 的 `SNAP_WORDS=${SNAP_WORDS:-N}` / `EXPECT_BID=${EXPECT_BID:-0xN}`，**不同代拒绝生成**（exit 3） | 整套判据台架 `汇总: OK=0 BAD=31` rc=1 | `OK=31 BAD=0` rc=0；守卫负对照（`NW_FIX=61` 副本）⇒ `GEOM_GUARD_FAIL: accept 默认几何 = (SNAP_WORDS=63, EXPECT_BID=0x9), 本夹具 = (61, 0x9)` rc=3 |

### 3.1 ⭐ 本轮**新发现**的三条真缺陷（都在 ③ 这一族里，**都不是几何问题**）

**(F-a) `p7b_gate4_livefake.sh` 的假对端会被**远端文本里的 `⚠` 打死**（GBK）**
- 机理：accept 的 `SNAP_REMOTE`（引号 heredoc）**注释里含 `⚠️`**（那是上一轮"占位符"修复留下的），
  而假对端用 `open(LOG,"a").write(remote)` —— Windows Python 的 `open()` 默认编码 = **locale = GBK**，
  **不受** `PYTHONIOENCODING=utf-8` 影响（那只管 stdout/stderr）⇒
  `UnicodeEncodeError: 'gbk' codec can't encode character '⚠'` ⇒ 假对端**崩**，
  快照块收不到 ⇒ 台架 22 条假红。
- 归属（如实）：**既存**，由**上一轮**往远端文本里加 `⚠️` 注释引入；**修前副本（pristine）在本轮同样复现**
  （`logs/livefake_before.txt`：`OK=4 BAD=22` + 同一 Traceback）⇒ 与我的编辑无关。
- 修法：假对端的 `st()/put()/open(LOG)` 显式 `encoding="utf-8"`；**刻意不动 stdout**
  （stdout 的 **LF→CRLF 翻译是被验机制之一**，`newline=""` 会把它关掉）。

**(F-b) 假对端的几何必须"按请求方那一代"回**
- 老臂跑的是 `pre_fix2` 版 accept（`SNAP_WORDS=51` / `EXPECT_BID=0x7` / `rd 0xEC`）。
  把假对端一刀切换成 63 字 ⇒ 老臂 `窗口不完整: 缺 W51` ⇒ **ABORT 在快照段**，
  检查点（MSYS 改写 / 激励没跑）**够不着** ⇒ `rawabs_old` 两条 [BAD]。
- 修法：从远端文本里**解析**请求的界（`for i in $(seq 0 50)` 或 `for i in $(seq 0 $(( 63 - 1 )))`），
  按 nw 回 51/61/63 字与 BID 7/8/9。

**(F-c) `mk_run_neg.py` 的变异体有静默退化的口子**
- `neg/axi_regs_mut_dec6.v` 的第二处 `str.replace("reg [6:0]  r_word;", …)` **没有断言**
  ⇒ 锚点若因 RTL 改动而消失，`replace` 静默 no-op ⇒ 变异体可能"和真文件一样" ⇒ 负对照**假通过**。
- 修法：加 `assert "reg [6:0]  r_word;" in s` + 三个变异体逐个 `assert != src`。
- ⚠️ **一处我自己踩到的坑（写在这里给下一个人）**：**不许用 `"seq 0 50" in remote` 这种子串判定** ——
  新版远端文本的**注释里**刚好引用了"旧版写死 `seq 0 50`"这句话 ⇒ 新版被误判成 51 字 ⇒ 又整台假红
  （实测：`livefake_after2.txt` = `OK=4 BAD=22`）。判据必须锚在**代码行的实际边界**上。

---

## 4. ④ `p6b_smoke_gate.sh` —— 打 FAIL 却 exit 0、末行还写 PASS

### 4.1 逐处

| 处 | 修前 | 修后 |
|---|---|---|
| 末段（`A4` 判决之后） | `echo "########## 冒烟门: PASS (可以继续 ping/图案) …"` + `exit 0`（**无条件**） | `if [ "${ID_BAD:-0}" -eq 0 ] && [ "$FAIL" -eq 0 ]` ⇒ PASS/exit 0；**否则** `冒烟门: FAIL (上面有红 ⇒ 不许当'可以继续 ping/图案')` + 点名根因 + **`exit 7`** |
| 头部退出码表 | `0=通过 2/4/5/6=…(停)` | 补 **`7=身份闸红但按归因纪律继续读完了 (上面有 FAIL ⇒ 不许当通过)`** + 说明"本门是 P6b 时代的口径，现代板上预期红/SKIP" |
| `ID_BAD=1` | 赋值后**从未被读**（`grep -c ID_BAD` = 1） | 进入末段判定（并打印根因行） |
| 其余不动 | —— | A1b 之后**仍继续读 A3/A4**（"供归因"的原有设计**保留**，只是不再谎报通过） |

### 4.2 替身证据（`logs/smoke/`，**逐字**）

替身 = 假 `reg_rw`（复刻现役板读到的每一条：`0x00=0x50360001`、**`0x04=0x00000008`**、
`0x14=0xdeadbeef`、`0x84 bit0=1`、`0xb0=0xc7ca0efe`、`0x80/0x34` = 156.25 MHz 自由计数）+ 假 `lspci/lsmod`；
脚本只有 `KO/TOOLS/DEV/LOG` 四个路径被 sed 换掉。**该替身的读数与上一轮的真板原件
`p7b_wu_p1p2_tools/logs/old_smoke_gate_on_current_board.txt` 逐特征一致**（BID 8 / 0xb0 已实现 / SM 锁 1 /
156.24 MHz）。

```
# 修前（原版，同一替身）:
  [FAIL] A1b 判据=BUILD_ID | 期望=6 | 实测=0x00000008
  [FATAL] BUILD_ID 不是 6 ⇒ 板上不是这一版位流 ⇒ 拒绝继续 (但**仍然继续读**下面两项, 供归因)
########## 冒烟门: PASS (可以继续 ping/图案)  PASS=5 FAIL=1 SKIP=1 … ##########
== rc=0 ==                                   ← **哑门本体**

# 修后（同一替身）:
  [FAIL] A1b …  [FATAL] …（同上，前面几行逐字相同）
########## 冒烟门: FAIL (上面有红 ⇒ **不许**当'可以继续 ping/图案')  PASS=5 FAIL=1 SKIP=1 … ##########
！根因: BUILD_ID != 6 ⇒ 板上不是 P6b 那一版位流 (身份闸 A1b 红); 退出码 7
== rc=7 ==
```

替身自检 8 条（`OK=8 BAD=0`）：R0–R2 = 复现哑门；R3–R5 = 真失败且**末行不再有 PASS**；
R6 = 点名根因；R7 = **仍按归因纪律读完 A3/A4**（`[RAW] A4 结论` 仍在）。

---

## 5. 附带事实与登记（**不是本轮改动**）

1. ⚠️ **`p7b_snap.sh` 我一个字节都没动** —— 实测 md5 = `6282843073c3789e41debc14dd480ee8`，
   与 `P7B_WU_P1P2_REGRESSION.md` §5.2 记录的并发轮 **09:06 版**逐字相同。
2. **行尾事实（与本轮无关，但会误导下一个人）**：`P7B_WU_P1P2_TOOLS.md` 交付件末尾写
   "全部 `.sh`/`.v` **LF 行尾、0 个 CR**"；实测**这些文件在 HEAD blob 里本来就是 CRLF**
   （例：`tcpreg_j6.sh` HEAD blob CR=91/91 行、`p7b_gate4_livefake.sh` 212/212），工作区亦然
   （`.gitattributes` 虽写 `*.sh text eol=lf`，但既存 blob 没被规范化）。⇒ 该句**与实测不符**（既存）。
   我的编辑**保持各文件原有行尾**（改后 CR 数 == 行数，**无混合**）。
3. `_proj_10g/notes/p7b_gate4_criteria/{inputs/,logs/,negctrl_fix3.sh}`、`p7b_gate4_tools/{negctrl,fix2,selftest}/`
   下的产物被**各自的既定行为**重写（跑台架的必然结果，非手改）；`git status` 里它们出现在 M 列表**属预期**。
4. `negctrl_fix3.sh`（判据收口台架）**未被派单点名**，但它**就是** `gen_inputs.py` 的消费者 ⇒
   随 gen_inputs 一起从 `OK=0 BAD=31` 恢复到 `OK=31 BAD=0`；它自己**未改动**。
5. 派单里说的 `sim/p6e_snap*/` 替身：**本仓没有这个目录**（`ls -d sim/p6e_snap*` = 空）⇒ 无对应件可改；
   与之最接近的 `_proj_10g/notes/p7b_gate4_tools/selftest/p6e_snap_check_fake.sh` 是
   `p7b_gate4_selftest.sh` 的**运行时产物**（每次跑重写），**不是**可手改的替身。
6. ⛔ **越界未改（留给下一轮，任务明令不碰 `p7b_snap.sh`）**：审查 **F3 §10.1** 的最小修法
   （"`full`/`snap` 里先 `id_check`（或至少核 BID）"）**仍未落** —— 实测现役 `p7b_snap.sh:148-149`
   的 `full` / `snap` **只 `trig` + `dump_words`**，不调 `id_check` ⇒
   `NW=61 bash p7b_snap.sh full T1` 在 63 字板上仍会**静默少读 W61/W62 并 exit 0**。
   本轮我只在 **j6 台架**里补了几何门（`bash "$S" id` 显式一跑）⇒ **j6 这条路已闭**；
   **`full`/`snap` 直调**那条路仍开着（`UNIMPL` 断言只在 `id_check` 里，而 `id_check` 只有 `id` 会调）。

---

## 6. 我没能证明的（**不许当已答**）

1. ⛔ **真板一个读数都没有**：本机 **没有 `PEER_PW`** ⇒ `peer_ssh.py --sudo` 直接 `KeyError: 'PEER_PW'`
   ⇒ 读不了 `/dev/xdma0_user`（root only）⇒ **j6 台架与 `p6b_smoke_gate.sh` 的"改后"都没有真板读数**；
   本节所有"跑一遍"都是**替身**（替身条件写在各节）。板侧可用的**改前**真板原件 =
   `_proj_10g/notes/p7b_wu_p1p2_tools/logs/old_smoke_gate_on_current_board.txt`（上一轮所留）。
2. ⛔ **j6 几何门的"通过"分支未在真 p7b_snap.sh 上验证**：替身把 `id` 的 rc 做成可注入 ⇒ 只验了失败路径；
   `ID_UNIMPL=0xffffffff` 那条断言的真实行为依赖真板/真脚本（逻辑在 `p7b_snap.sh:113`，我只读不跑）。
3. ⛔ **`J6_LEGACY_GEOM=1` 档在真旧位流（BIZ 61 字）上的行为未测**：字表退回 `5 53 54` 是替身证实的；
   真板上"61 字窗口 + `id` 闸通过"没有读数。
4. ⛔ **四个 apply 守卫的"放行"分支未验证**：没有 `git worktree` checkout 到 55/57/59 那一代去跑一次
   （`git worktree` 建树 + 跑 = 有成本，且会与别的支抢资源）。⇒ 现在只能证明"**当前代**会被拒绝"，
   "**同代**会被放行"是**读码推断**（守卫只比对 `SNAP_NW_P6E` 一个数）。
5. ⛔ **F-a 的修法边界**：我只证明"显式 utf-8 修好了本机 GBK 崩"；未核 **Linux 上**跑同一台架
   （对端机是 UTF-8 locale ⇒ 大概率本来就没事，但**没测**）。
6. ✅ **第五个台架 `p7b_gate4_selftest.sh`（并发轮改过、本轮我未编辑）实跑 = `OK=14 BAD=0`**
   （`logs/g4selftest_after.txt`；含"正例读过末字 0X118 / 未实现 0X11C / 63 行表"与负对照 6.1）。
   ⇒ 五个台架两两同代、全绿；⚠️ 它的产物（`p7b_gate4_tools/selftest/*`）被重写是**它的既定行为**。
7. ⚠️ **未核**：`tcpreg_j6.sh` 新增的 `bash "$S" id` 会**多读一次** `0x1c`（gen）—— 不触发快照
   （`id` 只读 0x00/0x04/0x14/未实现地址），但**对"并发写者"的暴露面**没有量化。

---

## 7. 证据地图（全部在 `_proj_10g/notes/p7b_wu_harness_fix/`）

| 文件 | 内容 |
|---|---|
| `logs/j6_double_final.txt` | j6 替身 27 条（含**改前副本** G1–G4 对照）；`logs/j6double/` 下每跑一份 `*.log/*.rc/calls.txt` |
| `dryrun_apply.py` · `logs/dryrun_biz_win.txt` · `logs/dryrun_after_guard.txt` | apply_* 的只读干跑（写模式结构性阻断）与守卫实测 |
| `logs/negctrl_before.txt` / `logs/negctrl_after.txt` | negctrl 0/15 → 15/0（after 全文 + 其 `SUMMARY.txt`） |
| `logs/livefake_before.txt` / `logs/livefake_after3.txt` | livefake 4/22 → 26/0（含 F-a 的 Traceback 原件）；`livefake_after{,2}.txt` = 两个中间坑（GBK / 子串误判）的**过程证据** |
| `logs/fix2_before.txt` / `logs/fix2_after.txt` + `p7b_gate4_tools/fix2/selftest_*.log` | fix2 5/14 → 19/0 |
| `logs/criteria_before.txt` / `logs/criteria_after.txt` | 判据台架 0/31 → 31/0 |
| `smoke_double_run.sh` · `logs/smoke/{before,after}.console/.rc` | 冒烟门 rc=0(PASS 谎报) → rc=7(FAIL) |
| `logs/g4selftest_after.txt` | 第五个台架 `p7b_gate4_selftest.sh` 实跑 `OK=14 BAD=0`（本轮未编辑该文件，只跑） |
| `j6_double_run.sh` · `smoke_double_run.sh` | 两个替身台架（可复跑；**不碰真板/不起 xsim**） |

### 复跑命令（逐字）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
bash _proj_10g/notes/p7b_wu_harness_fix/j6_double_run.sh        # j6 台架替身 (OK=27)
bash _proj_10g/notes/p7b_wu_harness_fix/smoke_double_run.sh     # 冒烟门替身   (OK=8)
bash _proj_pcie/p7b_gate4_negctrl.sh                            # 闸 4 负对照  (OK=15)
bash _proj_pcie/p7b_gate4_livefake.sh                           # live 假对端  (OK=26, ~3 min)
bash _proj_pcie/p6e_snap_selftest_fix2.sh                       # fix2 自证    (OK=19)
bash _proj_10g/notes/p7b_gate4_criteria/negctrl_fix3.sh         # 判据收口台架 (OK=31)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe \
    _proj_10g/notes/p7b_wu_harness_fix/dryrun_apply.py "$(pwd -W)" \
    _proj_10g/notes/p7b_biz_win/apply_{b,c,fixups,script_updates}.py   # 守卫 (均 exit 3)
```

---

## 8. 一句话交给 TL

**四条缺口全部收口且每条都有 before/after 读数**：`j6` 台架现在**传输窗内真读 W61/W62**（几何不符当场 exit 3）、
四个历史 `apply_*` 补丁件加了**代际硬守卫**（当前代必拒）、**四个自检台架从全红恢复全绿**
（0/15→15/0 · 4/22→26/0 · 5/14→19/0 · 0/31→31/0）、`p6b_smoke_gate.sh` 从"**FAIL 却 exit 0 / 末行 PASS**"
变成 **exit 7 / 末行 FAIL**；顺带抓到并修掉 **3 条真缺陷**（假对端 GBK 崩、假对端几何一刀切反向打断老臂、
变异体无断言静默退化）。
⚠️ **但所有"板级"读数都是替身**（本机无 `PEER_PW` ⇒ 不能 sudo ⇒ 读不了 `/dev/xdma0_user`）
⇒ 下一轮烧 63 字位流后的**第一件事**仍是真板跑一次 `p7b_snap.sh id` + 一次 j6 几何门（预期 `ID_OK` / `J6_GEOM_OK`）。
