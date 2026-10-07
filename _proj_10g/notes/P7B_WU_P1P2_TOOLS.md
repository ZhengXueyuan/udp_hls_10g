# P7B-WU 二轮 —— 测量/验收脚本随窗口同步（61 → 63 字 / BID 8 → 9 / `0x114` → `0x11C`）

- 日期：**2026-10-07**　轮次：**P7B-WU 二轮（测量脚本同步 agent）**　基线 HEAD = **`95c9485`**
- 依据（作者登记）：`_proj_10g/notes/P7B_WU_P1P2_SNAP.md` **§8①/②/⑥**；现役字表 = `P7B_BIZ_WINDOW.md` **§1**
- 性质：**只改脚本 / 只读板侧**。**未烧板、未建位流、未起 xsim**（另两个 agent 在用）；
  板侧只做了「读寄存器 + 写 `0x18=1` 触发快照」（任务明许），**全程未写 `0x08`**。
- 一句话：**4 个取数/验收脚本 + `final_state.sh` + `axi_regs.v` 头注释 + `.gitignore` 全部同步到 63 字口径**，
  并按任务要求用**旧板（BID 8 / 61 字）**实测了"响亮失败"、用**离线桩**实测了"正确输入必然 PASS"；
  顺带**发现并修掉一个真缺陷**（`p7b_gate4_accept.sh` 的 live 远端口径变量**根本传不过去**，见 §4）。

---

## 0. 一页速查

| # | 文件 | 动作 | 旧板（BID 8 / 61 字）实测 | 证据文件 |
|---|---|---|---|---|
| ① | `_proj_pcie/p7b_biz/p7b_snap.sh` | NW/EXPECT_BID/字表 + **新增 UNIMPL 断言** | `ID_FAIL 期望 BID=0x00000009 实测 0x00000008` rc=1；`snap` 报 `SNAP_FAIL nff=2` rc=1 | `logs/new_script_old_board_snap.txt` |
| ② | `_proj_pcie/p6e_snap_check.sh` | EXPECT_BID/SNAP_WORDS/字表 | `[FAIL] 1.2 BUILD_ID got 8 want 9` + `[FAIL] 5.0 窗口内有 2 个字读回 0xffffffff` rc=2 | `logs/new_script_old_board_snapcheck.txt` |
| ③ | `_proj_pcie/p7b_gate4_accept.sh` | EXPECT_BID/SNAP_WORDS/注释 **+ 修 live 取数真缺陷** | `[FAIL] G1 … BID=8` + `[FAIL] B_WIN … 2 个 F` + `[ABORT]` rc=2 | `logs/new_script_old_board_accept.txt` |
| ④ | `_proj_pcie/p7b_gate4_selftest.sh` | SW/SW 派生的假字表/假 BID | 不碰板（假板子）⇒ **`OK=14 BAD=0`**（63 字与 61 字两档都跑） | `logs/selftest_sw63.txt` · `logs/selftest_sw61.txt` |
| ⑤ | `_proj_10g/notes/p7b_gate4_3/final_state.sh` | `rd 0x11C` + W61/W62 **+ 新增 BID 前置闸** | `[ABORT] BID=0x00000008 != 0x00000009` + `FINAL_STATE_INVALID` rc=**3** | `logs/new_script_old_board_final_state.txt` |
| ⑥ | `_proj_pcie/rtl/axi_regs.v` | **仅头注释**（机械证明见 §1.6） | —— | `git diff` 非注释行 0 条 |
| ⑦ | `.gitignore` | 3 个新 sim 目录口径（末尾追加） | `git check-ignore` 逐条对照 | §6 |
| ⑧ | **本轮新发现**：accept 的 live 档取数自 BIZ 轮起**结构性地取不到数** | 已修 | 见 §4 | `logs/accept_livefetch_defect_excerpt.txt` |

改动量：**7 文件 / +192 −67**（另有 7 个 selftest 产物文件被其既定行为重写，见 §7）。
交付件指纹（sha256 前 16 位，**已改后**）：`.gitignore` `ac11493c6b6cb660` · `rtl/axi_regs.v` `686abf64b951efd4` ·
`p6e_snap_check.sh` `828a9a95f855c595` · `p7b_biz/p7b_snap.sh` `93de417957661e24` ·
`p7b_gate4_accept.sh` `e905dcc85aac628c` · `p7b_gate4_selftest.sh` `ffbc3b0306797d35` ·
`final_state.sh` `e268b2a2ea0f75d4`。全部 `.sh`/`.v` **LF 行尾、0 个 CR**（与仓内既有件一致），`bash -n` 全过。

---

## 1. 逐文件逐处

### 1.1 `_proj_pcie/p7b_biz/p7b_snap.sh`（板侧取数器）

| 处 | 改动前 | 改动后 |
|---|---|---|
| `:2` 标题 | 「板侧 **61** 字快照窗口…（BID=7 (合体后 8) / SNAP_NW=61）」 | 「板侧 **63** 字…（BID=9 / SNAP_NW=63）」+ 三行"读旧位流必须显式覆盖"的口径 |
| `:7-13` 新增字清单 | 只有 BIZ 的 W51..W60 | **补 W61=`app_ctrl.stat_wu` / W62=`app_ctrl.rx_occ_bytes`**（注明"加在 MSB 端 ⇒ 旧字逐项未动"、`stat_wu` **不是"已上线"**） |
| `:38` | `NW=${NW:-61}` | `NW=${NW:-63}` |
| `:39` | 派生 → `0x114` | 派生 → **`0x11C`** + 三行"BIZ 61 字 / RATE 51 字"的覆盖命令 |
| `:40` | `EXPECT_BID=${EXPECT_BID:-0x00000008}` | **`0x00000009`** |
| `:79-84` `NAME[]`（数组定义在 `:60` 起） | `[0]..[60]` | **补 `[61]=app_ctrl_stat_wu` / `[62]=app_ctrl_rx_occ_bytes`** |
| 同上 | ⚠️ **原有重复键**：`[56]=udpapp_tx_ovf` 之后又有一行 `[56]=udpapp_tx_ovf_stat_tx_ovf`（后者覆盖前者 ⇒ W56 打出的是**拼错的**名字） | **删掉重复行**（顺带修，非本轮引入） |
| `:71-73` | ⚠️ **原有"紧贴键"**：`[33]=rx_stat_orphan_bytes[34]=rx_stat_drop_full`（bash 实测：**键 33 的值 = 字面串 `rx_stat_orphan_bytes[34]=rx_stat_drop_full`**，而 `[34]` 根本不存在）⇒ W33/W37/W48 打印出**别的字的名字拼在自己后面**，W34/W38/W49 反而打印 `?` | **加空格分开**（顺带修，非本轮引入；这是一条会误导读数的**静默**表缺陷） |
| `:79-80` | ⚠️ **原有缺口**：**W51..W55 在这张表里从来没有名字**（BIZ 轮只补了 `[56]..[60]`）⇒ 逐字打印成 `?` | **补 `[51]..[55]`**（与 `p6e_snap_check.sh` 的 WLABEL 同源，真值源 = wrapper 装配段 / `P7B_BIZ_WINDOW.md` §1） |
| `:96-105` `id_check` | `UNIMPL` **只打印** `(want 0xffffffff)`，不判 | **新增断言**：`UNIMPL != 0xffffffff` ⇒ `ID_FAIL` rc=1 |

修后自检（实跑）：`键数=63 / 缺名字: 无`，`W33=rx_stat_orphan_bytes · W34=rx_stat_drop_full · W38=rxcdc_ovf_cnt · W49=cls_dbg_occ · W51=app_tx_bytes · W55=tx_stat_retx · W61=app_ctrl_stat_wu · W62=app_ctrl_rx_occ_bytes`。

⭐ 上面最后那条断言是本轮**有意加强**的：任务要求"不许静默错读"。有了它，**任何 `NW` 覆盖值不对**（例如拿 `NW=61` 读 63 字板）都会**当场红**，而不是打出一窗真数据让人以为读的是那一代。

### 1.2 `_proj_pcie/p6e_snap_check.sh`

| 处 | 改动 |
|---|---|
| `:46` | `EXPECT_BID` `0x00000008` → **`0x00000009`**；上面那行"位流身份"清单补 `8=P7B-BIZ 61字 · 9=P7B-WU 二轮 63字 (现役)` |
| `:57` | `SNAP_WORDS=${SNAP_WORDS:-61}` → **`63`** |
| `:58` | 派生注释改为 `63 ⇒ 0x11C (61 ⇒ 0x114; 51 ⇒ 0xEC)`；`:51-53` 几何段、`:343-344` 未实现地址谱系、`:26` BIZ 轮注释里的 `0x114` 全部改成"→ 0x11C（现役）" |
| `:322-323` `WLABEL[]` | **补 2 行**：`app_ctrl_stat_wu` / `app_ctrl_rx_occ_bytes`（W61/W62 的逐字标签，缺了会打 `<无标签>`） |
| `:61` | 默认几何文案 `61 字 / EXPECT_BID=7` → `63 字 / EXPECT_BID=9` |

### 1.3 `_proj_pcie/p7b_gate4_accept.sh`（闸 4 板级验收）

| 处 | 改动 |
|---|---|
| `:115` | `EXPECT_BID` → **`0x00000009`** |
| `:116` | `SNAP_WORDS` → **`63`** |
| `:117` | 派生注释 `63 ⇒ 0x11C (61 ⇒ 0x114; 51 ⇒ 0xEC)` |
| `:3-9` / `:52-54` / `:128` | 头部几何、开关说明、`W5_NOM` 说明里的 61/0x114/0x110/BID7 全部同步；补 W61/W62 两行字义 |
| ⭐ `:273-281` + `:299-306` | **修一个真缺陷**（§4）：远端文本里的几何值改成占位符 `__SNAP_WORDS__` / `__UNIMPL_ADDR__`，由 `snap_fetch` 在**发送前**替换 |
| `:279-281` | `UNIMPL` 那一行（远端文本）改成占位符；本地 `UNIMPL_ADDR` 仍是 `printf '0x%X'` 派生的 `0x11C` |

### 1.4 `_proj_pcie/p7b_gate4_selftest.sh`（假板子自证）

| 处 | 改动 |
|---|---|
| `:34` | `SW=${SNAP_WORDS:-61}` → **`63`**；`:35-36` 的 `LAST_A`/`UNIMPL_A` 随之（脚本本来就是 SW 派生的） |
| `:59-68` | 新增 `FAKE_TAIL`：**SW ≥ 63** ⇒ `0X114/0X118` 是**窗口内真字**（`V=1234`/`V=0`），`FAKE_UNIMPL` 挪到 **`0X11C`**；**SW = 61** ⇒ `FAKE_UNIMPL` 留在 `0X114`（历史口径仍可用） |
| `:95`（原 `:67`） | 假板 BID 从写死 `0x00000008` 改成 `${FAKE_BID:-0x00000009}`（**必须与 `p6e_snap_check.sh` 的 EXPECT_BID 同代**，否则正例的判据 1.2 假 FAIL） |
| `:11-16` | 头部口径同步（61→63、末字 `0x118`、未实现 `0x11C`） |

⚠️ **这条路我踩了两个坑（都已修，写在这里给下一个人）**：
1. **无引号 heredoc 里的注释不能含反引号 / `$()`** —— 我给假板注释里写了 `` `EXPECT_BID` ``，bash 当场把它当命令执行（`line 75: EXPECT_BID: command not found`）。已改成无引号写法并在注释里点名。
2. **变量内容不参与 heredoc 的转义处理** —— `FAKE_TAIL` 里我写了 `\${FAKE_UNIMPL:-…}`（想着"给 heredoc 转义"），结果那个**反斜杠原样落进了生成的假 `reg_rw`**，它把字面串当值打印出来 ⇒ 判据 6.1 读到空串报 **假 FAIL**（`got='' want='0xffffffff'`）。正解：变量里**直接写 `${...}`**、不加反斜杠。两处都已在注释里固化成规则。

### 1.5 `_proj_10g/notes/p7b_gate4_3/final_state.sh`

| 处 | 改动 |
|---|---|
| `:11` | `rd 0x114` → **`rd 0x11C`**（并把 BID 提出来存 `$BID`） |
| `:12-22` | **新增 BID 前置闸**（本脚本原先**一条判据都没有**，纯 dump）：`BID != 0x00000009` ⇒ 打 `[ABORT] …W61/W62 若为 0xffffffff 是 SLVERR 不是数据` |
| `:26` | 新增一行 `W61=… W62=…`（P7B-WU 二轮新增） |
| `:38` | 闸未过 ⇒ `FINAL_STATE_INVALID` + **rc=3**（原先恒 rc=0） |

### 1.6 `_proj_pcie/rtl/axi_regs.v`（**仅头注释**）

- `:29-42`：`0x110 SNAP_W60 / 61 字` → **`0x118 SNAP_W62 / 63 字`**（演进链补 `→63`）；补 W61/W62 两行；`未实现地址 = 0x114 (word 69)` → **`0x11C (word 71)`**
- `:58`：`现役 = 61 字, 未实现 = 0x114` → `63 字, 0x11C`
- `:226`：把一行**中间稿残留**的错注释（`NW=55 … ← P7B-BIZ 现役`）改成"55 字从未出厂"的如实注记
- `:260-264`：新增 `★ P7B-WU 二轮 (2026-10-07) 收口: NW 61 → 63 …`（含"12 位 `snap_base` 仍不需要动，max {62,5'b0}=1984 < 4096"的复核）
- ✅ **机械证明**：`git diff -U0 -- _proj_pcie/rtl/axi_regs.v | grep -E '^[+-]' | grep -vE '^[+-]\s*//'` = **0 行**（全是注释）。

### 1.7 `.gitignore`

末尾追加三段（口径同 `sim/p5wu*` 既有各段，"排产物、留门驱动/TB 源码/脚本"）：`sim/p5wu_p1p2/*` · `sim/p5wu_p1p2_review/*` · `sim/p5wu_p1p2_regress/*`。
⚠️ **两处与派单原文的偏离，都是有意为之（理由在注释里逐字写了）**：
1. 放行用 **`run_*.bat`** 而不是 `run_tb_*.bat` —— 否则 `sim/p5wu_p1p2/run_xvlog_wrapper63.bat`（**编译面门的现役入口**）会被排除，属"现役入口从未被 git 看见"那一族；先例 = `sim/p5d_multi/*`。
2. 照 `sim/p5wu_review` 上一段的先例，把**同名 RTL 副本**显式排除：`sim/p5wu_p1p2_review/app_ctrl_head_raw.v`（实测与 `git show HEAD:rtl/app_ctrl.v` **逐字节相同**，sha256 `c38b3b96…`）与两个 `head_rtl/`。
   ⚠️ **对照**：`sim/p5wu_p1p2/app_ctrl_base.v` **故意放行** —— 它是作者登记的负对照臂（重命名过的夹具，与已入库的 `user..._mut.v` 同族），**不是** rtl/ 的现役副本。

---

## 2. ⭐ 关键判据 A：「新脚本 × 旧板」必须**响亮失败**（逐字）

板侧现役位流 = `1076e50e…1160`（**BID 8 / 61 字 / `0x114` 是 W61**），全程只读 + 写 `0x18=1` 触发快照。

### 2.0 对照：**旧脚本 × 旧板 = 一致**（证明板子是活的、工具链是通的）

```
$ bash p7b_snap.sh id && bash p7b_snap.sh snap REF 0 5 20 50 60      # 旧脚本（HEAD 版）
ID_MAGIC 0x50360001   (want 0x50360001)
ID_BID   0x00000008   (want 0x00000008 = 本构建的 BUILD_ID)
ID_MARKER 0xdeadbeef  (want 0xdeadbeef)
ID_UNIMPL 0xffffffff  (want 0xffffffff: 未实现地址必须走 SLVERR)
ID_OK 1791334278.478187233
SNAP_BEGIN REF gen=108
W0 0x20 rx_stat_frames 0x0187c737 / W5 / W20 / W50 / W60 … SNAP_END REF nff=0

$ bash p6e_snap_check.sh        # 旧脚本（HEAD 版）
########## 汇总: PASS=15 FAIL=0 SKIP=0 (窗口 61 字; 未实现地址 0x114) ##########
```
（原件 `logs/ctrl_old_script_old_board.txt` · `logs/ctrl_old_snapcheck_old_board.txt`）

### 2.1 `p7b_snap.sh`：从 **身份闸** 报错

```
$ bash p7b_snap.sh id                       # 新脚本（NW=63 / BID=9）
ID_BID   0x00000008   (want 0x00000009 = 本构建的 BUILD_ID)
ID_UNIMPL 0xffffffff  (want 0xffffffff: 未实现地址必须走 SLVERR)
ID_FAIL 身份不符 (烧了别的位流? 期望 BID=0x00000009, 实测 BID=0x00000008)
== id rc=1 ==

$ bash p7b_snap.sh snap NEW 33 34 38 49 51 55 60 61 62
SNAP_BEGIN NEW gen=157
W33  0xA4   rx_stat_orphan_bytes   0x00000000      ← 表修复前这里打的是"W34 的名字拼在后面"
W34  0xA8   rx_stat_drop_full      0x00000000      ← 表修复前这里是 `?`
W38  0xB8   rxcdc_ovf_cnt          0x00000000
W49  0xE4   cls_dbg_occ            0x00000000
W51  0xEC   app_tx_bytes           0x01900000      ← 表修复前这里是 `?`
W55  0xFC   tx_stat_retx           0x000004d0
W60  0x110  srx_stat_fifo_ovf      0x00000000
W61  0x114  app_ctrl_stat_wu       0xffffffff      ← 旧板上 0x114 的**旧身份 = 未实现地址**
W62  0x118  app_ctrl_rx_occ_bytes  0xffffffff
SNAP_END NEW nff=2
SNAP_FAIL 窗口内有 2 个 0xffffffff (SLVERR 混入, 不是数据) => 整窗作废
== snap rc=1 ==
```
**从哪报的错**：`id_check` 的 BID 比较 + **本轮新加的 UNIMPL 断言**；`dump_words` 的 `nff` 计数。
（`full` 档同形：`SNAP_END FULL nff=2` + `SNAP_FAIL`；那次我套了 `| tail -4`，管道 rc 是 `tail` 的，**别当脚本 rc**。）
⚠️ **本条证据是在 NAME 表修复之后重跑的**（脚本 sha256 `93de4179…`），所以上面的名字列就是**交付件当前的字表**。

### 2.2 `p6e_snap_check.sh`：从 **判据 1.2 与 5.0** 报错

```
  [FAIL] 1.2 BUILD_ID (0x04): got='0x00000008' want='0x00000009'
  ...
  [FAIL] 5.0 窗口内有 2 个字读回 0xffffffff ⇒ 不是数据 (读没成功/选字回绕)
########## 汇总: PASS=13 FAIL=2 SKIP=0 (窗口 63 字; 未实现地址 0x11C) ##########
== rc=2 ==
```
**从哪报的错**：`:181` 的身份判据 `chk "1.2 BUILD_ID (0x04)"` + `:331-333` 的"窗口内无 `0xffffffff`"判据（`NFF`）；rc = FAIL 计数。
⚠️ **诚实标注**：**判据 6.1（未实现地址）在旧板上仍然 PASS** —— 因为旧板的 word 71 也是空的（译码 7 位 ⇒ 两侧都未实现）。**它不是 61/63 的判别式**，真正的判别式只有 1.2 与 5.0。

### 2.3 `p7b_gate4_accept.sh`：从 **G1 前置闸** 报错并 ABORT

```
  [FAIL] G1   位流身份 (块A) | 期望=MAGIC=0x50360001 BID=0x00000009 MARKER=0xdeadbeef | 实测=… BID=0x00000008 … ⇒ 不是本轮位流, 后面所有读数都不算数
  [FATAL] 身份不符 ⇒ 拒绝继续 (G1 前置闸)
  [FAIL] B_WIN 块A 窗口内不得出现 0xffffffff | 期望=0 个 F | 实测=2 个 F ⇒ 这些是**读失败**, 不是数据
  [PASS] B_UNIMPL 块A 未实现地址 0x11C | 期望=0xffffffff | 实测=0xffffffff
  [ABORT] 前置闸未过 ⇒ 后面的读数都不算数
########## PASS=1 FAIL=2 SKIP=0 ##########
== exit 2 ==
```
（跑法 `G4_SKIP_TRAFFIC=1` ⇒ 只取停机态两块快照、不打流、不动 `/32`；现场 `snap_A.txt` 收到 **63 行 W**。）
⚠️ 同 2.2：`B_UNIMPL` 在旧板上也 PASS（不是判别式）。

### 2.4 `final_state.sh`：从 **新增的 BID 前置闸** 报错

```
MAGIC=0x50360001 BID=0x00000008 MARKER=0xdeadbeef UNIMPL=0xffffffff gen=143
  [ABORT] BID=0x00000008 != 0x00000009 ⇒ **板上不是 63 字位流**; 下面 W61/W62 若为 0xffffffff 是 SLVERR(读失败) 不是数据
W61=0xffffffff W62=0xffffffff  # P7B-WU 二轮新增 (stat_wu / rx_occ_bytes)
FINAL_STATE_INVALID (前置闸未过: BID != 9 ⇒ 窗口口径不符)
== rc=3 ==
```
⚠️ 这一跑按脚本既定行为做了 §3"网络复原"（删 `/32` 与路由）；**我在同一次 ssh 里已把 `192.168.100.100/32` 与 `192.168.100.2/32` 路由放回原样**（`ip -br addr` / `ip route get` 双确认，见日志尾）。§2 的 `rm -f /tmp/g4_*.pcap` 是 **no-op**（对端机 `/tmp` 里没有 `g4_*` 文件；WU/RATE 轮的 pcap **不在删除列表里**，未被触碰）。

### 2.5 ⭐ 最强对照：**新脚本 + 显式声明旧几何 ⇒ 恢复 PASS**

```
$ NW=61 UNIMPL_ADDR=0x114 EXPECT_BID=0x00000008 bash p7b_snap.sh id
ID_OK … rc=0
$ SNAP_WORDS=61 UNIMPL_ADDR=0x114 EXPECT_BID=0x00000008 bash p6e_snap_check.sh
########## 汇总: PASS=15 FAIL=0 SKIP=0 (窗口 61 字; 未实现地址 0x114) ##########
```
（`logs/ctrl_new_script_override_old_board.txt`）
⇒ **失败 100% 来自"口径不一致"，不是脚本写坏、也不是板子坏**：同一份新脚本，把几何说对了就与旧脚本**逐字同结果**（PASS=15/FAIL=0/SKIP=0）。

---

## 3. ⭐ 关键判据 B：合成正例（**不动板子**）

### 3.1 `p6e_snap_check.sh` × 63 字假板子（`p7b_gate4_selftest.sh`）

```
— 正例: 0X11C 回 0xffffffff (期望: 6.1 PASS, 整脚本 0 FAIL) —
  [OK  ] 正例 6.1 PASS / 正例 汇总 0 FAIL / 正例退出码 0
  [OK  ] 正例读过末字地址 0X118 / 正例读过未实现地址 0X11C
  [OK  ] section5 地址序列 (63 个, 0x20..0X118 连续不重复) / 序列长度 63 / 表格行数 63
— 负对照: 0X11C 回真数据 (期望: 6.1 FAIL, 退出码非 0) —  [OK] 两条
########## 自证汇总: OK=14 BAD=0 ##########
```
- 该门把 `p6e_snap_check.sh` **原样**跑（只换 TOOLS/DEV/LOG/sysfs 四个路径）⇒ 这是对**本文件本体**的正例。
- **历史口径仍可用**：`SNAP_WORDS=61 EXPECT_BID=0x00000008 UNIMPL_ADDR=0x114 FAKE_BID=0x00000008 bash …` ⇒ 同样 **OK=14 BAD=0**（`logs/selftest_sw61.txt`）。

### 3.2 `p7b_gate4_accept.sh` × 63 字离线桩

新写 `_proj_10g/notes/p7b_wu_p1p2_tools/mk_accept_offline.py`（W0..W50 照抄 `negctrl` 的 clean 夹具、W51..W60 用**现场真读数**、W61/W62 取合理值、BID=9、两块 TLATCH 差 10 s ⇒ Δ=156.25e6×10）：

```
$ python mk_accept_offline.py <out>
$ G4_SNAP_TEXT=…/snap_A.txt,…/snap_B.txt G4_NIC_TEXT=…/nic_A.txt,…/nic_B.txt bash _proj_pcie/p7b_gate4_accept.sh
  PASS|G1|位流身份 (块A)|… BID=0x00000009 …
  PASS|B_WIN|块A 窗口 63 字齐全且无 0xffffffff
  PASS|B_UNIMPL|块A 未实现地址 0x11C
  PASS|G2-W5 / G2-W24 / G2-W50 = 156.2500 MHz (Δ=1562500000 / 10.000000s)
  PASS|B_CONS-a / B_CONS-b / B_DIR / C1-C5 / C6-C7 / C8 / C6-ev
  PASS|N_CRC / N_BAD / N_RATE (Δ=4060000 帧 / 5.000000s = 9860.93 Mbps) / N_UCAST / N_LEN / N_AVG / N_SELF
  SKIP|N_BASE|（只给 2 个 NIC 文本 ⇒ 当测量窗用，基线自检无从做 —— **设计如此**）
########## PASS=23 FAIL=0 SKIP=1 (窗口 63 字; 未实现地址 0x11C; EXPECT_BID=0x00000009) ##########
```
⇒ **判据层在正确输入下 0 FAIL**。原件 `logs/offline_stub_accept.txt`。

---

## 4. ⭐ 本轮发现的一个**真缺陷**（已修）：accept 的 live 档取数**自 BIZ 轮起就取不到数**

| 项 | 内容 |
|---|---|
| 症状 | live 跑 `p7b_gate4_accept.sh` ⇒ `[FATAL] 快照块 A 解析: 窗口不完整: 缺 W0 (共收到 0 字; 期望下标 0..62 连续)` ⇒ `[ABORT]`，**63 个字一个都没取回来**（原始文本里 `UNIMPL 0x50360001` = 空地址读出的 MAGIC） |
| 真因 | `SNAP_REMOTE` 是**引号 heredoc**（远端执行的文本），它引用了 `$((SNAP_WORDS-1))` 与 `$UNIMPL_ADDR` —— 而这两个是**本地脚本的变量，既没 `export`、也不是 sudo 的保留变量**，远端 `sudo bash -lc` 里**是空的** ⇒ `seq 0 -1` = 空循环 |
| 引入时点 | **`de1496a`（P7b 51 字轮）时这段还是写死的** `seq 0 50` + `rd 0xEC`（所以那三轮 live 是好的）；**BIZ 轮**（`2ec6813`）把它改成"由 SNAP_WORDS 派生"却**没有把值送过去** ⇒ 从此 live 档第一次取数必失败 |
| 为什么没人发现 | ⚠️ **两个台架结构上看不见它**：`p7b_gate4_livefake.sh` 的假对端**不执行这段文本**（它自己造字）；`p7b_gate4_negctrl.sh` 走的是**离线文本**（`G4_SNAP_TEXT`），根本不发远端命令。而 BIZ 轮之后**没再 live 跑过**（`P7B_WINDOW.md` 自己写着"本轮 live 路径没跑过"） |
| 修法（最小） | 远端口径值改成占位符 `__SNAP_WORDS__` / `__UNIMPL_ADDR__`，由 `snap_fetch` 在发送前替换（`:279` / `:301-302`） |
| 证据 | 修复后同一命令：`snap_A.txt` 收到 **63 行 W** + `G1 FAIL`/`B_WIN FAIL` 的**预期**失败（`logs/new_script_old_board_accept.txt`）；机理复现（与板子无关、可重跑）见 `logs/accept_livefetch_defect_excerpt.txt` 末段 |

---

## 5. 全域 grep 清册（硬编码 `61` / `0x114` / `0x110` / `BUILD_ID` / `= 8` 一类）

判定列：**改** = 本轮改；**无关** = 与现役窗口无因果；**响亮** = 会报错/红但不静默；**⚠️静默** = 会安静地失去判别力。

| # | 引用点 | 类别 | 处理 | 备注 |
|---|---|---|---|---|
| 1 | `_proj_pcie/p7b_biz/p7b_snap.sh` | 取数器 | **改** | §1.1 |
| 2 | `_proj_pcie/p6e_snap_check.sh` | 验收 | **改** | §1.2 |
| 3 | `_proj_pcie/p7b_gate4_accept.sh` | 验收 | **改**（+修真缺陷） | §1.3 / §4 |
| 4 | `_proj_pcie/p7b_gate4_selftest.sh` | 假板门 | **改** | §1.4 |
| 5 | `_proj_10g/notes/p7b_gate4_3/final_state.sh` | 收尾读数 | **改** | §1.5 |
| 6 | `_proj_pcie/rtl/axi_regs.v` | RTL 头注释 | **改（仅注释）** | §1.6 |
| 7 | `sim/p5wu_p1p2/*` · `…_review/*` · `…_regress/*` | 新门目录口径 | **改 `.gitignore`** | §1.7 |
| 8 | `board/wrapper_p4.v`（`SNAP_NW_P6E=63` / `SNAP_P7BDP_NW=24` / `BUILD_ID_V 9` / 未实现 `0x11C`） | **源码唯一权威** | 无关（阶段 A 已改，非本 agent） | 本轮的脚本口径**逐项对齐**它 |
| 9 | `sim/p5wu_p1p2/check_wu_words.py` · `_proj_10g/notes/p7b_biz_win/check_window.py` | 静态门 | 无关（已是 63 口径，作者改） | `PASS=42` / `PASS=14` 由作者跑 |
| 10 | `_proj_10g/notes/p7b_biz_win/apply_c.py`（18 处 `0x114`） | **历史一次性改写脚本** | **不动**（越界）+ **已失效** | 它按字符串改写本轮的 5 个脚本；实测其锚点已不存在（`grep -c "预算复算.*本轮的 61" board/wrapper_p4.v` = **0**，`板侧 59 字` = **0**）⇒ **重跑会在第一处 `MISS` 退出、不会回写**（`sub()` 先断言后写） |
| 11 | `_proj_pcie/p7b_gate4_negctrl.sh:50`（`BID 0x00000008` + 51 字夹具） | gate-4 判据负对照 | **未改（越界）** | ⚠️ **响亮**：clean 正对照会 BAD（parse 缺 W51..W62）⇒ **需要一次口径更新**，见 §8-③ |
| 12 | `_proj_pcie/p7b_gate4_livefake.sh:79` + `tools/peer_ssh.py` 假件（51 字 + BID 8） | gate-4 live 台架 | **未改（越界）** | 同上（响亮） |
| 13 | `_proj_pcie/p6e_snap_selftest_fix2.sh:67`（假板 BID 8 / 字表到 `0xE8`） | fix2 假板门 | **未改（越界）** | ⚠️ **响亮**：case ① 的正对照会 BAD（它按默认 63/9 跑现在的 `p6e_snap_check.sh`） |
| 14 | `_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py`（造 `BID 7` + W0..W50） | gate-4 判据台架输入 | **未改（越界）** | ⚠️ **响亮**（喂给更新后的 accept ⇒ 缺字/fatal） |
| 15 | ⚠️ **`_proj_10g/notes/p7b_wu_w54/j6_fix.sh`** 与 **`_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh`** | **下一轮的 j6-ladder 测量台** | **未改（越界，但必须点名）** | 它们调 `/tmp/p7b_biz/p7b_snap.sh` 并把 `NW=${NW:-61}` 只用于**打印标签** ⇒ 不传 `NW` 时标签写 61、取数器按 63 跑 ⇒ **`TCPREG_ABORT pre_snapshot`**（响亮，因为身份闸会红）。⇒ **下一轮跑 W61/W62 读数前必须先处理**（改 `NW=63`/`EXPECT_BID=0x00000009` 或直接删掉该默认值）。⚠️ 这正是本轮给 `p7b_snap.sh` 加 UNIMPL 断言的用处：**`NW` 覆盖值不对时当场红，而不是打出一窗真数据** |
| 16 | `_proj_10g/notes/p7b_rate_result/rate_probe.sh:48-49`（写死 `seq 0 50` + `rd 0xEC`） | RATE 轮历史探针 | **不动** | 自持 51 字口径；在 63 字板上 `rd 0xEC`（= W51）回**真数据**，但它只打印不判 ⇒ **无关**（且已被 `p7b_snap.sh` 取代） |
| 17 | `_proj_pcie/p6b_accept.sh:80`（`EXPECT_BUILD_ID=0x00000006`） | P6b 时代验收 | **未改** | 身份不符那一支**无条件 `exit 2`**（读码确认）⇒ **响亮**。其 `:82-83` 注释只有到 BIZ 61 字的谱系（缺 63 那一行）— 注释级 |
| 18 | `_proj_pcie/p6b_smoke_gate.sh`（`BID 必须=6` / `A_UNIMPL=0xB0`） | P6b 冒烟门 | **未改** | ⚠️ **实测（在现板上跑了）**：先打 `[FAIL] A1b BUILD_ID`+`[FATAL] … 拒绝继续`，`A2` 把"地址已实现"报 **SKIP**，最后却打 `########## 冒烟门: PASS (可以继续 ping/图案)  PASS=5 FAIL=1 SKIP=1 ##########` 且 **rc=0**；`ID_BAD=1` 设了却**从未被读**（`grep -c ID_BAD` = **1**）⇒ **⚠️静默**（日志里有 FAIL、退出码 0，A2 判据安静失去判别力）。**既存问题，不因本轮新增**，但**每一块现代板**上都会触发（原件 `logs/old_smoke_gate_on_current_board.txt`） |
| 19 | `p6b_accept_final/srv_p6b_final_accept.sh:44`（`ADDR_UNIMPL=0xB0`，注释称 `ar_word` 6 位） | P6b 对端验收 | **未改** | A5 会 **FAIL**（`0xB0` 现在回真数据）⇒ **响亮**；注释里的 6 位说法已被 BIZ 轮推翻（现 7 位） |
| 20 | `tools/gen_stim_tcp_rx.py:170`（`wnd=0x1100`） | 假阳性 | 无关 | 不是地址 |
| 21 | `sim/snapcdc/**`（`review24/axr_mut`、`mut5_nw`…）· `int_scratch/**`（`neg5`/`negbase`） | 历史单元门/负对照件 | 无关 | 自持 `NW=24/36` 口径、自己带 BUILD_ID |
| 22 | `CLAUDE.md` / `README.md` / `PORT_NOTES.md` / `P7B_HANDOFF.md` / `P7B_BIZ_PLAN.md` / `P7B_BIZ_WINDOW.md`（各 1–5 处 `0x114`） | 文档 | **未改** | 任务明令不碰（并发/别的支在写）；`P7B_WU_P1P2_SNAP.md` §8-②b 已登记这一批 |
| 23 | `_proj_10g/notes/p7b_gate4_tools/selftest/*`（`addrlog_*` / `addrseq*` / `SUMMARY.txt` / `bin/reg_rw` / `p6e_snap_check_fake.sh`） | 门的**产物**（被 git 跟踪） | **随跑重写** | 那是 `p7b_gate4_selftest.sh` 的**既定行为**（`P7B_BIZ_WINDOW.md` §7 已写明）；现在内容 = **63 字真相**。⚠️ 它们出现在 `git status` 的 M 列表里，**不是**我手改的 |

---

## 6. `.gitignore` 的逐条自检（`git check-ignore` 实测）

放行（应可入库）：`run_tb_wu_p1p2.bat` · `run_tb_snap63.bat` · **`run_xvlog_wrapper63.bat`** · `check_wu_words.py` · `app_ctrl_base.v` · review 的 `tb_rev_*.v` / `rev_*.py` / `run_tb_rev_*.bat` · regress 的 `*.py` / `run_*.bat` ⇒ **全部 "tracked-eligible"**。
忽略（产物/副本）：`p1p2/run|xsim.log` · `runsnap/a.wdb` · `work_xvlog/*` · review 的 `mut/` `mutw/` · **`app_ctrl_head_raw.v`** · 两个 `head_rtl/` ⇒ **全部 IGNORED**。

---

## 7. 我动过的"非交付"东西（如实）

| 项 | 说明 |
|---|---|
| 对端机 `/tmp/wusync_old/` · `/tmp/wusync_new/` | 暂存 5 个脚本副本（含修复前/后），供"同一命令不同版本"对照 |
| `_proj_10g/notes/p7b_gate4_tools/selftest/*`（7 文件） | 被 `p7b_gate4_selftest.sh` **既定行为**重写（同 `P7B_BIZ_WINDOW.md` §7 的登记） |
| `_proj_10g/notes/p7b_gate4_tools/snap_A.txt` | accept 的 live 跑写下的快照原件（未跟踪） |
| 对端机网络配置 | `final_state.sh` §3 删了 `/32` ⇒ **已在同一次 ssh 里放回**（addr + route 双确认） |
| 板子 | **未写 `0x08`**（复核：`0x08` 仍 = `0x00000002`）、未烧板、未改任何 RTL/状态 |

---

## 8. 我没能证明的 / 待办（**不许当已答**）

1. **63 字真板**：本轮**没有位流**可烧 ⇒ "新脚本 × 新板 = 全绿"**一次都没跑过**（旧板上是响亮失败，离线桩是 PASS）。下一轮烧了 63 字位流后，**第一件事**：`p7b_snap.sh id` 应给 `ID_OK` + `W0..W62` 齐 + `0x11C → 0xffffffff`。
2. **`W61/W62` 的读数语义未定标**（沿用 `P7B_WU_P1P2_SNAP.md` §6-⑥）：本轮只保证接线与字表对齐。
3. ⚠️ **三个 gate-4 台架 + 一个 fix2 台架现在会响亮失败**（清册 #11/#12/#13/#14）——**未改（越界）**，且**我没有试过它们的过桥方案**。下一轮要么按 `p7b_gate4_selftest.sh` 的 SW 派生手法改，要么显式传旧几何 env。**这是本轮交付后最大的已知缺口**。
4. ⚠️ **`j6_fix.sh` / `tcpreg_j6.sh`（下一轮 j6-ladder 的测量台）未改**（清册 #15）——它是"测量脚本"，但不在派单名单里；**下一轮跑 j6 前必须先处理**，否则开场就 `TCPREG_ABORT`。
5. **清册 #18（`p6b_smoke_gate.sh`）的"⚠️静默"我只验到"退出码 0 + 日志有 FAIL"**；它是否被任何自动化消费（据此判"可以继续 ping"）**未核**。
6. **`p6b_accept.sh` / `srv_p6b_final_accept.sh` 未实跑**（清册 #17/#19 的"响亮"是**读码推断**，不是读数）。
7. **本轮的 `.gitignore` 三目录口径**：`…_review` / `…_regress` 两目录是**别的 agent 正在写**的，我按 `git check-ignore` 的**当时快照**核对（§6）；它们**后续新加**的文件类型可能不在放行集里。
8. **`final_state.sh` 的 §2（`rm -f /tmp/g4_*`）实际是 no-op**（对端机没有那些文件）⇒ 它的破坏性那一支**没有真的被执行过**。
9. 清册 #10 关于 `apply_c.py`"重跑会 `MISS` 退出"的结论：我核了**两个锚点串**（=0 命中）+ 读了 `sub()` 的"先断言后写"逻辑 ⇒ 是**代码+抽样证据**，不是"完整重跑过一次"。

### ⚠️ 顺带修的**既存**缺陷（**不是本轮引入**，逐条登记以免被当成"本轮改动"混淆）

10. `p7b_snap.sh` 的 `NAME[]` 表三处：① **W51..W55 从来没有名字**（BIZ 轮只补了 `[56]..[60]`，逐字打印成 `?`）；
    ② **紧贴键** `[33]=x[34]=y`（bash 实测：**键 33 的值 = 字面串 `x[34]=y`**，键 34 不存在）⇒ W33/W37/W48 打出**被污染的**名字、W34/W38/W49 打出 `?`；
    ③ 尾部**重复键** `[56]=udpapp_tx_ovf_stat_tx_ovf` 覆盖 `[56]=udpapp_tx_ovf`。
    三者**只影响打印出来的名字列，不影响任何读数/判据逻辑**；修后自检 `键数=63 / 缺名字: 无`。

### 给 TL 的下一轮清单（按优先级）

① 烧 63 字位流后跑 §8-1 的三条前置闸；② 处理清册 #15（j6 台架）→ 才能拿 `ΔW61/ΔW62` 把 wu 机理从推断升为观测；③ 处理清册 #11–#14（四个台架）；④ 文档口径（`0x114 → 0x11C`）归 DOCFIX/文档轮。
