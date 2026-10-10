> ⚠️ **2026-10-11 追记（TL 指令后）** —— ① **本目录已由 TL 侧更名**：`p7b_build0x1C/` → **`p7b_readside_bid1c_20261011/`**
> （原因逐字 = "因与 `p7b_build_0x1C` 撞名"；脚本内 `ALLOW` 的路径正则已同步，**该改动已保留**）。本文其余内容**未变**（当时写的路径按新目录读）。
> ② **脚本已参数化**：`--bid 0x1C`（缺省 = 本文描述的现状兼容）/ `--bid 0x1D`（persist 刀；阶段链 `0x1C → 0x1D`）；
>   ⚠️ 目标值**不再从权威源推导** —— 现读 `board/wrapper_p4.v` 已是 `0x1D`（persist 构建 agent 已改），
>   脚本改为"`--bid` 钉死 + 与权威源不一致时打**警告行**"。
> ③ **0x1D 的编辑表 + 两步内存演练 + 负彩排 = 见同目录 `REPORT_BID1D.md`**（两步演练都全绿）。
> ④ 本文 §0 里那批产物文件名有变：负对照现为 `NEGCTL_{table,bid,tier,face}_0x1C.txt`（按目标加后缀），
>   并新增 `*_BID1D_*` 一批；干跑/彩排的**读法与结论不变**。

# P7B 缺陷刀构建 (BID `0x1C`) —— 读侧默认值同步：预建 + dry-run 报告

日期 2026-10-11 · 派单 = 「为'板上从构建 F（BID `0x1A`）换成缺陷刀构建（BID `0x1C`）'预建读侧默认值同步脚本」
**本轮只预建 + 干跑，⛔ 未 apply（仓内现役文件一个字节都没动，见 §7 取证）。**
除本目录（`_proj_10g/notes/p7b_build0x1C/`）外，本轮没有写任何文件（`rtl/` `tb/` `sim/` `board/` 只读；git 只读；未跑 xsim/Vivado；未 ssh 写对端）。

---

## 0. 交付物（全在本目录）

| 文件 | 内容 |
|---|---|
| **`apply_readside_bid1c.py`** | 主脚本（52 KB；显式 24 处 EDITS × 命中数断言 + A/B/C/D 四条结构性断言 + 4 条负对照 + `--rehearse` 沙盘） |
| `DRYRUN_OUTPUT.txt` | 干跑原始输出（默认模式；RC=1 = 见 §3 读法） |
| `REHEARSE_OUTPUT.txt` | 沙盘彩排：24 处 edit 全在内存应用后重跑同一套断言 ⇒ 全绿 RC=0 |
| `NEGCTL_{table,bid,tier,face}.txt` | 4 条负对照原始输出（全部 RC=1 = 判据有牙） |
| `FACE_OUTPUT.txt` | 搜索面全表（244 行 / 118 文件；每行的分类） |
| `TARGET_SHA_BEFORE.txt` | 14 个目标文件的 apply 前 sha256（apply 后逐条重算 ⇒ 只应有这 14 个变） |
| `LINES_CURRENT.txt` | 14 个目标里 `0x1A` 的现读行号（供人核对脚本注释里的"现读 :NN"） |

模式（⚠️ 与 F 轮正好相反：F 轮默认 apply、`--check` 才是干跑）：

```
python apply_readside_bid1c.py                # 默认 = DRY-RUN（只报命中数，不落盘）
python apply_readside_bid1c.py --apply        # 真正落盘（本轮未使用）
python apply_readside_bid1c.py --rehearse     # 内存沙盘：全 apply 一遍再跑断言（期望全绿）
python apply_readside_bid1c.py --assert       # 只跑 A/B/C/D 断言（不同步）
python apply_readside_bid1c.py --face         # 搜索面全表（命中文件 + 分类）
python apply_readside_bid1c.py --negctl=table|bid|tier|face   # 负对照（破坏件只在 tempfile）
```

---

## 1. 权威源与本轮目标值（一律现读，脚本里不写死）

`board/wrapper_p4.v`（工作树；其未提交态已由另一 agent 在会话中途提交进 `420230e`）：

```
:3241  localparam SNAP_NW_P6E = 70;        // 总字数 W0..W69 (未实现地址 = 0x138 = word 78)
:4063  .BUILD_ID_V (32'h0000001C),         // ← 本轮唯一变化的权威值
:2155  tcp_tx_frame #(.RING_CAP(WIN_CAP_5), .PERSIST_EN(1'b0)) u_tcp_tx (
```

⇒ 本轮 = BID-only：NW 仍 70（本刀不加字）· 未实现地址仍 0x138（= 0x20+4×70）· 只动身份。
`0x1C` 的语义（wrapper 注释链 `:4064-4078` 逐字）：重放越界缺陷修复 (RETXHI-GHOST)；
`0x1B` 已被 persist 刀占用且从未构建 ⇒ 本版（persist 关）改判 `0x1C`；persist 刀留 `0x1D`。

---

## 2. EDITS 清单 —— 14 文件 / 24 处（每条带命中数断言，不做任何通配替换）

hits = 干跑实测（全部 1/1）。行号 = 现读（见 `LINES_CURRENT.txt`）。

### 2.1 两个 j6 台架脚本（4 处）

| 文件 | 现读行 | 改什么 |
|---|---|---|
| `_proj_10g/notes/p7b_affinity/j6_r6fix.sh` | :76 | `EXPECT_BID=${EXPECT_BID:-0x0000001A}` → `0x0000001C`（行尾注释同步，旧代降为"原 …"） |
| 同上 | :82 | `GEOM_TIERS` 加一行（照 F 轮该行格式）：`"70\|0x0000001C\|61 62\|缺陷刀 (2026-10-11) 70 字 / BID 0x1C (RETXHI-GHOST 重放越界修复; 字长/未实现地址不变)"`；`70\|0x0000001A` 那行逐字保留为历史档 |
| `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh` | :70 / :77 | 同上两处（该文件的"原 …"链以 `0x09 = WU 二轮` 结尾，故单独写 old 串） |

> ⚠️ 同几何、两个身份：70 字那一代现在档表里有两行（`0x1C` 现役 / `0x1A` 历史）—— 台架按
> `(NW, EXPECT_BID)` 双键匹配（`:93-95`），旧行保留 ⇒ 读 F 归档位流仍可按档显式声明。

### 2.2 取数器 `_proj_pcie/p7b_biz/p7b_snap.sh`（2 处）

| 现读行 | 改什么 |
|---|---|
| :51 | `EXPECT_BID=${EXPECT_BID:-0x0000001A}` → `0x0000001C`（裸行，全文唯一） |
| :2-:4 | 头部"现役 = 70 字 / BID 0x1A" → `0x1C`，并在 F 那行上面插一行 ⭐ 缺陷刀订正块（字长/地址不变；70 字有两个身份） |

### 2.3 `_proj_pcie` 的验收/夹具脚本（13 处）

| 文件 | 现读行 | 改什么 |
|---|---|---|
| `p6e_snap_check.sh` | :60 | `EXPECT_BID` 默认 `0x1A` → `0x1C`（行尾"原默认"链同步；`SNAP_WORDS`/`UNIMPL_ADDR` 不动） |
| `p7b_gate4_accept.sh` | :131 | 同上 |
| `p7b_gate4_selftest.sh` | :132-:134 | "现役 = 0x1A (构建 F …)" 注释块 → `0x1C`（缺陷刀），旧口径列成 `FAKE_BID=0x0000001A (构建 F; SNAP_WORDS=70) / …` |
| 同上 | :137 | 假板子 `0X04) V=\${FAKE_BID:-0x0000001A};;` → `0x0000001C` |
| `p7b_gate4_negctrl.sh` | :31 | 合成夹具"几何"自述：`构建 F (2026-10-10, BID=0x1A / 未实现 0x138)` → `缺陷刀 (2026-10-11, BID=0x1C / …)` + 旧句降为"原句" |
| 同上 | :58 | `echo "BID 0x0000001A"` → `0x0000001C`（假快照文本的身份字段） |
| `p7b_gate4_livefake.sh` | :118 | 注释块加一条 ⛔ 缺陷刀行（70 槽身份 0x1A→0x1C + 字典按 NW 索引 ⇒ 读 F 归档需配套回改） |
| 同上 | :119 | `bid = {70: "0x0000001A", …}.get(nw, "0x0000001A")` → 70 槽与兜底值都改 `"0x0000001C"` |
| `p6e_snap_selftest_fix2.sh` | :77 | `0X04) V=\${FAKE_BID:-0x0000001A};;` → `0x0000001C` |
| `p7b_gate4_criteria/gen_inputs.py` | :10 | 几何 docstring：`70 字 / BID 0x1A (P7b 构建 F, …)` → `0x1C (P7b 缺陷刀, 2026-10-11 同步轮从 70 字/BID 0x1A 同步)` + 原句链下推 |
| 同上 | :39 | `本夹具现 = 70 字 / BID 0x1A …` → `0x1C`（这一行有专用断言） |
| 同上 | :41 | 逐代链 `… → 70 字/0x1A (构建 F, 未实现地址 0x138)。` → `… → 70 字/0x1A (构建 F) → 70 字/0x1C (缺陷刀, 未实现地址 0x138 不变)。` |
| 同上 | :43 | `BID_FIX = 0x0000001A` → `0x0000001C`（⚠️ 它自带 `_geo_guard`：与 accept 默认不同代 ⇒ 响亮失败 exit 3 + 零文件） |

### 2.4 `final_state.sh` + sim TB（3 处）

| 文件 | 现读行 | 改什么 |
|---|---|---|
| `_proj_10g/notes/p7b_gate4_3/final_state.sh` | :29 | `EXPECT_BID` 默认 `0x1A` → `0x1C`（`UNIMPL=$(rd 0x138)` 不动） |
| `sim/p6e_pcie/tb_p6e_pcie_counters.v` | :206 | 判据 0b：`chk("0b BUILD_ID (构建 F 70-word = 0x1A; …)", v, 32'h0000001A)` → `32'h0000001C` + 标签改"缺陷刀 70-word = 0x1C" |
| `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` | :149 | 判据 2：同上（`32'h0000001C`） |

### 2.5 上一轮(A3 负对照轮)的档位自检 —— 它描述的是现役缺省档（2 处）

| 文件 | 现读行 | 改什么 | 为什么 |
|---|---|---|---|
| `_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh` | :4 | `(i) 缺省档 (NW=70 / 0x138 / BID 0x1A) …` → `0x1C` | 该脚本 C-a 那条命令是 `bash $SREAD id` 不带任何覆盖 ⇒ 用的就是 `p7b_snap.sh` 的默认值；默认值换代后这里的文字必须跟上 |
| 同上 | :46 | `C-a) 默认档 (… BID 0x1A) … (BID 0x18 != 0x1A)` → `… 0x1C` | 同上 |

---

## 3. dry-run 结果（`DRYRUN_OUTPUT.txt`，RC=1）

**① 锚点：0 条 miss。** 24 处 edit 全部 `hits=1/1` —— 没有"锚点没找到"也没有"命中数不符"。
**② A 表长断言：全绿**（5 张表 == 70 字；FAKE_TAIL 地址 10 条 == NW−60，末条 `0x138`）。
**③ B 搜索面全扫：全绿**（4 族 / 244 命中文件 / 未登记 0）。
**④ D 清单-断言覆盖：全绿**（14 个 EDITS 文件 / 14 个都自带断言）。
**⑤ C 默认值一致性：24 条红 —— 这不是 miss，是"待改处"**，且 24 红 ↔ 24 处 edit 基本 1:1：
22 处 edit 各 1 条红；`livefake` 字典 1 处 edit 由 2 条断言覆盖（70 槽 + 兜底值）；`livefake` 的
纯叙述注释那 1 处 edit 无独立断言（它描述的就是这次 diff 本身，见 §5-④）。

> 读法（脚本自己在输出里也印了这句）：A/B/C/D 跑在未 apply 的现状上 ⇒ C 的红 = 待改处
> （apply 后必须逐条转绿）；A/B 的红才是真问题。
> 更强的证据 = `--rehearse`：24 处 edit 全在内存应用后，A/B/C/D 全绿 (0 fail, RC=0) ⇒
> 清单完整且自洽：apply 后 ①没有残留的旧身份 ②不破任何表 ③不新增未登记命中。

负对照（判据有牙；破坏件只写在 tempfile，仓内原件不动）—— 4 条全 `NEGCTL_VERDICT 有牙 / NEGCTL_EXIT=1`：

| 负对照 | 破坏 | 结果 |
|---|---|---|
| `table` | 把 `p6e_snap_check.sh` 的 WLABEL 末项删掉（70→69） | A 红（表长 69 ≠ 70） |
| `bid` | 把 `j6_r6fix.sh` 的 `EXPECT_BID` 改成 `0x00000009` | C 红，且目标断言 `j6_r6fix.sh[BID]` 在红名单里 |
| `tier` | 把 `tcpreg_j6.sh` 档表首行改成 `70\|0x00000009` | C 红，目标断言 `tcpreg_j6.sh[TIER_TOP]` 在红名单里（本轮新增的断言有牙） |
| `face` | 造一个未登记路径的新文件带 `BID_EXPECT=0x0000001A` | B 红（3 族同时抓到它） |

---

## 4. "看似该改但判定不改"（逐条 + 理由 + 分类出处）

分类权威 = `_proj_10g/notes/p7b_readside_harden_20261010/FULL_TABLE.tsv`（771 行/149 文件；构建于
2026-10-10 10:44–10:57）。⚠️ 它有三个目录的时间盲：`p7b_buildF_board2_20261010/`(11:57)、
`p7b_microwin_20261010/`(19:00)、`p7b_aliasgate_20261010/`(10-11 00:46) 都晚于该扫描 ⇒ 本轮由我现读现场分类。

| # | 文件 | 里面有什么 | 判定 | 理由（+ 分类出处） |
|---|---|---|---|---|
| 1 | `_proj_10g/notes/p7b_a3_negctl_20261010/burn_arm.sh:21` | `BID=0x0000001A; BIE=0x0000001A; NW=70` | 不改 | ⚠️ 它的 `BIE` 是绑"具体位流"的：该 E 臂烧的是 `p7b_buildE_build/E/wrapper_p4.bit`，其 sha = `b88b2bee…a64f` = 构建 E（BID 0x19 / 67 字）⇒ 这一行的正确值本来是 0x19/67；F 轮把它改成 `0x1A/70` 时只改了身份、没改 `REL/WANT/BIT` ⇒ 现状已是"半代"。再叠 `0x1C` 只会更错。正确处置 = 退回 `0x00000019/67` 或整臂重指（属另一件事）。`FULL_TABLE` 该行分类 = "必须同步（F 轮 EDITS 目标）" —— 那个分类是描述性的（"F 改过"），不是"必须继续改"。已在脚本 `ALLOW` 里按"位流绑定"登记并附理由。 |
| 2 | `_proj_10g/notes/p7b_buildF_board_20261010/{burn_arm.sh,run_arm.sh,_tools/p7b_snap.deployed.sh}` | `BIE=0x0000001A; NW=70` 等 | 不改 | 构建 F 那一轮的板级现场/跑臂：它们烧的就是 F 位流 ⇒ `0x1A` 是它的真值。`FULL_TABLE` 原分类 = "现役: 构建 F 板级轮（在飞）"；F 轮已收口 ⇒ 本轮改归"旧位流读法"。⚠️ 同批移除了 F 脚本里对这两件的 `BID_NW_PAIR` 断言（它们现在会正确地红 = 噪声）。 |
| 3 | `_proj_10g/notes/p7b_buildF_board2_20261010/*` · `_proj_10g/notes/p7b_microwin_20261010/{burn_F.sh,run_mw.sh}` | `BIE=0x0000001A; NW=70` | 不改 | 同上（F 位流的两轮后续现场；微窗轮）。分区晚于 `FULL_TABLE` ⇒ 由本轮补分类。 |
| 4 | `_proj_10g/notes/p7b_defect_board_20261011/**`（在飞：`burn_F_archive.sh` 01:00、`step0_selfcheck.sh`、`burn/` 01:02…） | 刻意带 `0x1A` | 不改，且整目录 ALLOW | 这是缺陷刀板级轮的 A 臂（S-0）：刻意在修复前的 F 归档位流上造构型（`burn_F_archive.sh` 的 `WANT=89e89f31…` = F 位流）⇒ 它的 `0x1A` 是刻意的、不是漏同步。⚠️ 该目录正被另一个 agent 并发写入（我这一轮期间它从"空目录"长出了 8+ 个文件）。 |
| 5 | `_proj_10g/notes/p7b_buildF/apply_*.py` · `p7b_buildE/` · `p7b_a7/` · `p7b_gate4_tools/` 等 | 各代旧值 | 不改 | 补丁左值/历史副本（old 侧必须留旧值，否则左值失效）—— 沿用 F 轮 `ALLOW` 分类。 |
| 6 | `sim/aliasgate/_selftest/{mutboard/wrapper_p4.v,wrapper_p4_mutant.v}` · `_proj_10g/notes/p7b_aliasgate_20261010/` · `p7b_p5wrapper_diag_20261010/work/{E,F,H}/wrapper_p4.v` | `BUILD_ID_V 32'h0000001A` | 不改 | 另一路 agent 的对拍副本/突变件（其 `0x1A` 是它的实验变量）。分区晚于 `FULL_TABLE` ⇒ 本轮补分类（"只登记不动"）。 |
| 7 | `_proj_10g/notes/p7b_biz_win/tb_biz_win.v:50` | `axi_regs #(… .BUILD_ID_V(32'h00000008) …)` | 不改 | 同名不同物：这是该 TB 自己例化的 `axi_regs`（单元被测件的参数），不读板；任何值都可。F 轮同样没动它。 |
| 8 | `_proj_10g/notes/p7b_gate4_tools/{fix2/new_fake.sh,selftest/p6e_snap_check_fake.sh}` | 一份 `p6e_snap_check.sh` 的旧拷贝（`EXPECT_BID=0x1A`） | 不改 | 门工具那一轮的历史副本/生成物（`FULL_TABLE` 原分类）。 |
| 9 | `_proj_10g/notes/p7b_a3_negctl_20261010/_tools/p7b_snap.deployed.sh` · `p7b_buildF_board*_tools/p7b_snap.deployed.sh` | 取数器部署件快照 | 不改 | 各轮"部署了什么"的取证快照（改它反而毁掉那一代的取证）。 |
| 10 | `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的 `0x138` 未实现地址行（:333-:339） · `_proj_10g/p7b_chain/sim/tb_p7b_chain.v` | `0x138` | 不改 | 本轮未实现地址不变（仍 0x138）⇒ 这两件本轮没有 BID 变更点（TB 的 BID 行在 §2.4 已改）。 |

---

## 5. 与派单描述不符 / 需要知悉之处（如实报告，未迁就）

1. **"sim/ 侧 TB 的 BID/未实现地址常量"** —— 只改了 BID（`32'h0000001A → 32'h0000001C`）；
   未实现地址常量本轮一个字都没动（仍 `0x138`，与派单正文"未实现地址仍 = 0x138"一致，但与
   这一句的并列写法略有出入）。同理 `final_state.sh` 的 `UNIMPL=$(rd 0x138)`、`SNAP_WORDS`、
   `FAKE_TAIL` 地址表、`NAME[]`/`WLABEL` 表长 —— 全部不动（已由 A 条断言证明它们仍 == 70）。
2. **"FULL_TABLE 里'必须同步'那类 = 现役面"** —— 实测该类的字面语义 = "F 轮 apply 命中的行"
   （124 行），不是"本轮必须同步"的指令集。我的 BID-only 视图与它有两处方向相反的差异：
   - 剔除 1 件：`p7b_a3_negctl_20261010/burn_arm.sh`（在位流绑定，见 §4-1）；
   - 补入 1 件：`_proj_pcie/p7b_gate4_livefake.sh` —— 它的 `bid = {70: "0x0000001A"}` 行
     F 轮改了、但旧搜索面看不见（family 里没有 `bid = {` 这条规则）⇒ 属"现役面"却不在该类里。
     本轮已把这条规则加进搜索面（identity-BID 族新增 `bid = {\d+: "0x…"` 与 `echo "BID (0x…)"`）
     ⇒ 这两处（livefake 字典 / negctrl echo）从此在搜索面里可见。
3. **"几何档表加一行 `70|0x0000001C|…`"** —— 已照做（两个 j6 脚本各一行，插在 `70|0x0000001A` 上面，
   旧行逐字保留）。⚠️ 但注意 F 轮那一行的格式是 `"NW|BID|WEXTRA|标签"`（WEXTRA = `"61 62"`），不是只有三段。
4. **有一处 edit 是"纯叙述注释"、没有独立断言**：`p7b_gate4_livefake.sh:118` 的 ⛔ 注释（它描述的
   正是这次 diff 本身："身份 0x1A → 0x1C"）—— 给它配"值 == 现役"的断言在语义上不成立
   （它必然会提到旧值）。该文件的数值面（70 槽 / 兜底值）各有一条断言；D 条覆盖断言保证
   "每个文件至少有一条断言"仍成立。
5. **`board/wrapper_p4.v:4063` 的行尾注释仍写"构建 F = 0x1A"**（值已是 `32'h0000001C`；下面 `:4064-4078`
   的块把改判写清楚了）。文件在 `board/`（本轮只读）⇒ 未动，仅登记。
6. **会话中途 HEAD 动了**：开工时 HEAD = `139d7b7`，现在是 `420230e`（"缺陷刀构建 0x1C 收口（位流 09c280e4）…"）
   —— 另一个 agent 把构建轮的产物提交了。已核：该提交没有碰我 14 个目标里的任何一个
   （`git diff --name-only 139d7b7..HEAD -- <14 件>` = 空）。我的 24 处锚点在提交前后逐字未变。
7. **并发写入者**：`_proj_10g/notes/p7b_defect_board_20261011/` 正在被另一个 agent 写（S-0 臂）。
   我的搜索面把该目录整目录 ALLOW 了（理由见 §4-4）。⇒ 若在 apply 前重跑本报告，
   文件清单可能会更长（但不应出现"未登记"）。
8. **`0x1C` 不是"带缺陷的构建"**：它是修复构建（RETXHI-GHOST 重放越界修复）；"缺陷刀"这个名字指的是
   "这一刀动的是一处缺陷"。`0x1B` = persist 刀（已分配、从未构建）；`0x1D` = persist 保留。

---

## 6. 判据/断言结构（照搬 F 轮 + 两处加强）

- **A. 表长断言**：5 张表（WLABEL 70 / NAME[] 键 {0..69} / livefake W 表 70 / negctrl V 表 70 /
  selftest FAKE_TAIL 地址 10 条）—— 项数 == NW（现读）。
- **B. 搜索面全扫**：4 族 —— ① `bid-oldvalue`（本轮新增：`0x0000001A` / `32'h0000001A` 的任何拼法，
  只认 8 位零填充形态以免踩 base64 假阳性 —— 实测 `xdma_0_sim_netlist.v` 的 base64 行里逐字含 `0x1A`）
  ② `identity-BID`（F 轮族 + 本轮两条新规则）③ `geometry-NW` ④ `unimpl-addr`。
  每个命中文件必须是 EDITS 目标或 ALLOW 分类，否则 FAIL。全扫前去掉整行注释（历史注释可留）。
- **C. 默认值一致性**：37 条 spec + 1 条派生式 —— 每个读侧默认值（NW / BID / UNIMPL）必须 == 权威源现读值；
  本轮新增 7 条：`p7b_snap.sh` 头部"现役"行、`selftest` "现役"行、`livefake` 70 槽、
  `gen_inputs` 几何行 ×2、"本夹具现 ="行、`step0_selfcheck` "默认档"行；
  以及新的 `TIER_TOP`（档表首行必须 == (现役 NW, 现役 BID)）。
- **D. 清单-断言覆盖（本轮新增）**：每个 EDITS 目标必须自带断言 —— 把"清单完整性"从人的记忆
  变成脚本的结构（F 轮"五处只改三处"的缺口类别）。
- ⚠️ F 轮的两个 `BID_NW_PAIR` 断言已移除（`p7b_buildF_board_20261010/{run,burn}_arm.sh`）—— 理由同 §4-2。

---

## 7. 硬约束遵守（取证）

- 未 apply：干跑/彩排/负对照/face 四种模式各跑多次，全部不落盘；
  `git status --porcelain` 对 14 个目标 + 全部读侧件 = 空（并另有 `TARGET_SHA_BEFORE.txt` 逐件 sha256 存档）。
- 只写本目录：`_proj_10g/notes/p7b_build0x1C/`（新建；9 个文件）。
- 未跑 xsim/Vivado；未改 `rtl/` `tb/` `sim/` `board/`（只读）；git 只读；未 ssh 写对端（本轮未 ssh）。
- 负对照的破坏件一律写在 `tempfile.mkdtemp()` 里（脚本末尾 `finally: shutil.rmtree`）。

---

## 8. 授权后怎么用（apply 步骤 + apply 后必须核什么）

```
# 1) 先干跑一遍（应仍 = 24 hits 全中）
python _proj_10g/notes/p7b_build0x1C/apply_readside_bid1c.py
# 2) apply
python _proj_10g/notes/p7b_build0x1C/apply_readside_bid1c.py --apply     # 期望末行 OK + RC=0
# 3) apply 后核 (a) 指纹: 只应有那 14 个文件变 (对照 TARGET_SHA_BEFORE.txt)
#            (b) 再跑 --rehearse / 默认干跑: 期望全绿（24 红全转绿）
#            (c) 对端 /tmp 的旧副本必须重新部署（p7b_snap.sh 等；配方 = _proj_10g/notes/p7b_affinity/BUILD.md）
```

⚠️ apply 的时机由执行者按台账 §10-5-4 执行序决定：该序写的是"S-0 回来 → 读侧同步 → 烧 0x1C 归档副本 →
S-1 臂"。S-0 臂刻意跑在 F 位流（0x1A）上 ⇒ 在读侧同步之前/之后跑 S-0 都不受影响，但
0x1C 一上板，对端 `/tmp/p7b_biz/` 里的旧取数器就会"响亮失败"（ID_FAIL）⇒ 部署件必须与板上同代。

---

## 9. 本报告未做的事（边界）

- 未判定任何 PASS/FAIL（按派单：不下裁定）；§3 的"全绿/红"只描述判据自身的机械结果。
- 未改 `burn_arm.sh` 的半代问题（§4-1）—— 只登记 + 给出两种正确处置，等指令。
- 未追踪 `p7b_defect_board_20261011/` 的后续文件（并发写入中，每次重跑 `--face` 即现读）。
