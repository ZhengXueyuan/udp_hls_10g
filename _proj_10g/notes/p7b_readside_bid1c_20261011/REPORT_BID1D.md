# 0x1C → **0x1D**（persist 刀）读侧 BID 同步 —— 编辑表 + 两步内存演练（**未 apply**）

日期 2026-10-11 · 本目录 = `_proj_10g/notes/p7b_readside_bid1c_20261011/`（TL 指定名；**同一目录**装 0x1C 与 0x1D 两份，避免造近似名）
⛔ **本轮只预建 + 干跑/彩排**：仓内被同步目标文件**一个字节都没动**（`git status` 对该 14 件为空）。

## 0. 一句话

脚本已**参数化**（单文件 `apply_readside_bid1c.py`，`--bid 0x1C`(缺省，现状兼容) / `--bid 0x1D`）；
**0x1D 的 24 处编辑表已备**（old 侧 = **0x1C 树**）；**两步内存演练都全绿**（1 阶段 0x1C 绿；2 阶段 0x1C→0x1D 绿）；
**负对照 4 条 × 两个目标 = 8 跑全有牙**，外加一条**负彩排**（故意漏掉 1 处 0x1D 编辑 ⇒ 只红那一处）。

## 1. 参数化用法（单文件，路径不变 ⇒ 你们已引用的命令不受影响）

```
python _proj_10g/notes/p7b_readside_bid1c_20261011/apply_readside_bid1c.py                      # 缺省 target = 0x1C; DRY-RUN
python .../apply_readside_bid1c.py --bid 0x1D                                                  # 目标换 persist 刀 (DRY-RUN)
python .../apply_readside_bid1c.py --apply                                                     # 落 0x1C (仍**未放行**, 等 S-0)
python .../apply_readside_bid1c.py --bid 0x1D --apply                                          # 落 0x1D —— ⚠️ 要求 0x1C 已落盘 (前置门)
python .../apply_readside_bid1c.py --rehearse [--bid 0x1D]                                     # 内存彩排 (链式; 期望全绿)
python .../apply_readside_bid1c.py --assert [--bid 0x1D]                                       # 只跑 A/B/C/D
python .../apply_readside_bid1c.py --face [--bid 0x1D]                                         # 搜索面全表
python .../apply_readside_bid1c.py --negctl=table|bid|tier|face [--bid 0x1D]                   # 负对照 (tempfile 破坏件)
```

- **目标值不推导**: `--bid` 显式钉死（缺省 `0x1C`）；权威源 `board/wrapper_p4.v` 只用来读 **NW / 未实现地址**，
  并在 `BUILD_ID_V != 目标` 时打**警告行**（不是 FAIL）—— 因为该文件正被 persist 构建 agent 改。
- **多阶段语义**: `0x1D` 的 old 侧 = `0x1C` 树的末态 ⇒ 阶段链 `[0x1C, 0x1D]`；
  `--apply --bid 0x1D` 只落**最后一阶段**，并要求前置阶段**已在盘上**（否则**响亮 FAIL**，不半落）。
- 单阶段（`--bid 0x1C`）时的行为与参数化**之前逐字一致**（`DRYRUN_OUTPUT.txt` 对照见 §4）。

## 2. 0x1D 编辑表 —— 14 文件 / 24 处（每条**命中数断言 = 1**；old 侧逐条 = 0x1C 阶段 new 侧）

| # | 文件 | 处（old → new 的值面） | 形态 |
|---|---|---|---|
| 1-2 | `_proj_10g/notes/p7b_affinity/j6_r6fix.sh` · `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh` | `EXPECT_BID=${EXPECT_BID:-0x0000001C}` → **`0x0000001D`**（行尾"原 …"链同步） | 默认值 |
| 3-4 | 同上 ×2 | `GEOM_TIERS` **再插一行**：`"70\|0x0000001D\|61 62\|persist 刀 (2026-10-11) 70 字 / BID 0x1D"`（插在 `70\|0x0000001C` 那行**上面**；旧行逐字保留 ⇒ 70 字那一代 3 行） | 档表 |
| 5 | `_proj_pcie/p7b_biz/p7b_snap.sh` | :51 裸行 `EXPECT_BID` → 0x1D | 默认值 |
| 6 | 同上 | 头部"**现役 = 70 字 / BID 0x1C**" → **0x1D** + 新插 ⭐ persist 刀块（缺陷刀那行降为历史，删掉"两个身份"措辞） | 自述 |
| 7 | `_proj_pcie/p6e_snap_check.sh` | `EXPECT_BID` → 0x1D（`SNAP_WORDS`/`UNIMPL_ADDR` **不动**） | 默认值 |
| 8 | `_proj_pcie/p7b_gate4_accept.sh` | `EXPECT_BID` → 0x1D | 默认值 |
| 9-10 | `_proj_pcie/p7b_gate4_selftest.sh` | "现役 = **0x1C**"注释块 → **0x1D**；假板子 `0X04) V=\${FAKE_BID:-0x0000001C}` → **`0x0000001D`** | 注释 + 假板子 |
| 11-12 | `_proj_pcie/p7b_gate4_negctrl.sh` | 几何自述行 → `persist 刀 (2026-10-11, BID=0x1D …)` + 旧句降"原句"；假快照 `echo "BID 0x0000001C"` → **`0x0000001D`** | 合成夹具 |
| 13-14 | `_proj_pcie/p7b_gate4_livefake.sh` | 注释块加 ⛔ persist 行（说明字典**按 NW 索引 ⇒ 70 槽只能装现役**）；`bid = {70: "0x0000001C", …}.get(nw, "0x0000001C")` → 70 槽与**兜底值**都 → **`"0x0000001D"`** | 假对端 |
| 15 | `_proj_pcie/p6e_snap_selftest_fix2.sh` | `0X04) V=\${FAKE_BID:-0x0000001C}` → **`0x0000001D`** | 假板子 |
| 16 | `_proj_10g/notes/p7b_gate4_3/final_state.sh` | `EXPECT_BID` → 0x1D（`UNIMPL=$(rd 0x138)` 不动） | 默认值 |
| 17-20 | `_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py` | 几何 docstring → `0x1D (P7b persist 刀…)` + 原句链下推；`:39` 夹具自述 → 0x1D；`:41` 逐代链 → `… → 70 字/0x1C (缺陷刀) → **70 字/0x1D (persist 刀, 未实现地址 0x138 不变)**。`；`BID_FIX = 0x0000001C` → **`0x0000001D`** | 夹具（自带 `_geo_guard`，与 accept 不同代 ⇒ 响亮失败 exit 3） |
| 21 | `sim/p6e_pcie/tb_p6e_pcie_counters.v` | 判据 0b `32'h0000001C` → **`32'h0000001D`** + 标签 | sim TB |
| 22 | `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` | 判据 2 同上（未实现地址 0x138 行**不动**） | sim TB |
| 23-24 | `_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh` | :4 "缺省档 (… BID 0x1C)" → 0x1D；:46 "默认档 (… BID 0x1C) … (BID 0x18 != 0x1C)" → 0x1D | 自检脚本（描述**现役**缺省档） |

**共 14 文件 / 24 处**，与 0x1C 阶段**同文件同部位**（值面整体 +1 代）；`NW` / 未实现地址 / 任何表长 / 任何 `0x138` **一律不动**。

### 2b. 0x1D 阶段**不动**的件（与 0x1C 阶段同判）

- `_proj_10g/notes/p7b_buildF_board*_20261010/*` · `p7b_microwin_20261010/*`（**绑 F 位流**：0x1A 是它们的真值）；
- `_proj_10g/notes/p7b_defect_board_20261011/*`（S-0 臂**刻意**跑 F 位流；该目录在飞/并发写入）；
- `_proj_10g/notes/p7b_build_0x1D/**`（persist **构建**轮目录，非读侧；且其文件不在扫描扩展名内 ⇒ 由 `--face` 现读确认）；
- `_proj_10g/notes/p7b_a3_negctl_20261010/burn_arm.sh`（**位流绑定**：E 臂烧 build E 位流 ⇒ BIE 依位流定，见 0x1C 报告 §4-1）；
- `sim/p6e_pcie/*` 的 `0x138` 行 · `_proj_10g/p7b_chain/sim/tb_p7b_chain.v` · 各 `*_tools/*.deployed.sh` 快照 ·
  `tb_biz_win.v:50` 的 `BUILD_ID_V(32'h00000008)`（TB 自例化参数，不读板）。

## 3. 两步内存演练（**都全绿**）

### 步 1 = `--rehearse`（target 0x1C，1 阶段）—— `REHEARSE_OUTPUT.txt`
```
REHEARSE 阶段链: 0x0000001C(缺陷刀 (2026-10-11), 24 处)
REHEARSE 阶段 0x0000001C (缺陷刀 (2026-10-11)): applied=24 / skipped=0
---- 搜索面 [bid-oldvalue[0x0000001A]]: 命中 37 文件 (已登记 37 / 未登记 0)
SEARCH_FACE OK (4 族 / 246 命中文件)
OK EDIT_COVERAGE (本阶段 EDITS 文件 14 / 有对应断言 14)
REHEARSE OK —— 全绿 ⇒ 清单完整且自洽 (target 0x0000001C; 1 阶段 / 末阶段 24 edits; 0 fail)      [RC=0]
```

### 步 2 = `--rehearse --bid 0x1D`（**链式**，2 阶段；0x1C 的产物就是 0x1D 的 old 侧）—— `REHEARSE_BID1D_OUTPUT.txt`
```
REHEARSE 阶段链: 0x0000001C(缺陷刀 (2026-10-11), 24 处) -> 0x0000001D(persist 刀 (2026-10-11), 24 处)
REHEARSE 阶段 0x0000001C (缺陷刀 (2026-10-11)): applied=24 / skipped=0
REHEARSE 阶段 0x0000001D (persist 刀 (2026-10-11)): applied=24 / skipped=0
---- 搜索面 [bid-oldvalue[0x0000001A,0x0000001C]]: 命中 28 文件 (已登记 28 / 未登记 0)
---- 搜索面 [identity-BID]: 89 / [geometry-NW]: 87 / [unimpl-addr]: 33   ⇒ SEARCH_FACE OK (4 族 / 237 命中文件)
OK   _proj_10g/notes/p7b_affinity/j6_r6fix.sh   TIER_TOP = 0x0000001D,NW=70 (共 8 档) 期望 0x0000001D,NW=70
OK   EDIT_COVERAGE (本阶段 EDITS 文件 14 / 有对应断言 14)
REHEARSE OK —— 全绿 ⇒ 清单完整且自洽 (target 0x0000001D; 2 阶段 / 末阶段 24 edits; 0 fail)      [RC=0]
```
⇒ 24 + 24 处编辑**在内存里全部命中且落位后，A/B/C/D 四条断言 0 红**：清单完整、不破表、无残留旧身份、无新增未登记命中。
（搜索面每族"未登记 0"是硬要求：**任何**留旧值/旧命中的文件都必须已登记为 EDITS 目标或 ALLOW 分类。）

### 3b. 0x1D 干跑（**当前树**上）—— `DRYRUN_BID1D_OUTPUT.txt`（读法说明）
```
TARGET BID = 0x0000001D (显式 --bid; 阶段链 0x0000001C -> 0x0000001D; 本阶段 24 处 edit)
AUTHORITY board/wrapper_p4.v: SNAP_NW_P6E = 70 / BUILD_ID_V = 0x0000001D / 未实现地址 = 0x138
ℹ️ 前置阶段 0x0000001C **尚未落盘** ⇒ 本阶段 (old 侧 = 其后的树) 现在**不可能**匹配, 下面的 0/1 是预期读法。
FAIL … hits=0/1 …   (24 行, 全是 0/1)          ← 预期读法，**不是**锚点漂移
APPLY_READSIDE_BID FAIL (target 0x0000001D, 24 edits, 48 fail)                                  [RC=1]
```
⚠️ **24 处 0/1 + 24 条 C 红 = 48**：前者因为盘上还是 0x1A 树（0x1D 的 old 侧根本还不存在）；后者是同一件事在 C 段的镜像。
**0x1D 的正确验证载体 = `--rehearse --bid 0x1D`**（§3 步 2），**不是**这个干跑。

## 4. 负对照（判据有牙）—— 8 跑 + 1 条负彩排

| 件 | 破坏 | 结果（两个目标都跑） |
|---|---|---|
| `NEGCTL_table_{0x1C,0x1D}.txt` | 删 `p6e_snap_check.sh` WLABEL 末项（70→69） | A 红 1 条 · **RC=1** |
| `NEGCTL_bid_{0x1C,0x1D}.txt` | 把 `j6_r6fix.sh` 的 `EXPECT_BID` 改成 `0x00000009` | C 红，**且目标断言 `j6_r6fix.sh[BID]` 在红名单里** · **RC=1** |
| `NEGCTL_tier_{0x1C,0x1D}.txt` | 把 `tcpreg_j6.sh` 档表**首行**改成 `70\|0x00000009` | C 红，**且 `tcpreg_j6.sh[TIER_TOP]` 在红名单里** · **RC=1** |
| `NEGCTL_face_{0x1C,0x1D}.txt` | 造未登记路径新文件，带**目标的前一代值**（0x1C 目标 ⇒ 0x1A；0x1D 目标 ⇒ 0x1C） | B 红（3 族同抓） · **RC=1** |
| `NEG_REHEARSE_BID1D.txt` | **负彩排**：链式 apply 但**故意漏掉最后一处 0x1D 编辑** | C **恰好 1 条红**，就红在被漏的那处（`step0_selfcheck.sh[BID]`）· **RC=0(负彩排成立)** |

⚠️ **诚实口径**：`bid`/`tier` 两条在 **0x1D 目标**下，C 段本来就有 24 条红（树未落盘）⇒ "含目标断言"这条是
**必要不充分**；0x1D 表有牙的**更强**证据 = 上面那条**负彩排**（漏一处 ⇒ 只红那一处）——它证明了
**A/B/C/D 对 0x1D 的每一处编辑都逐处敏感**。

## 5. 权威值 / 与 TL 描述不符或需知悉（如实）

1. **`board/wrapper_p4.v` 现读已是 `0x1D`**（`:3245 SNAP_NW_P6E = 70` · `.PERSIST_EN(1'b1)`（`:2159`）· `.BUILD_ID_V (32'h0000001D)`
   （`:4067`））—— 即 persist 构建 agent 的改动**已经落进工作树**（`git status` 显示 `M board/wrapper_p4.v`，未提交）。
   ⇒ 0x1D 清单的"权威值"**按 TL 给的 `0x0000001D` 显式写**（脚本里 = `--bid 0x1D`），**不从权威源推导**；
   ⛔ **待 persist 构建完成（位流收口）后必须复读一次 `board/wrapper_p4.v` 复核**（核 `SNAP_NW_P6E == 70` + `BUILD_ID_V == 0x1D`；
   若 persist 又改判 BID，本表的目标值要跟着走）。
2. **目录名**：TL 指定 `p7b_readside_bid1c_20261011/` —— 实测**该目录已存在且就是我的目录**（由 TL 侧改名 + 顺手把脚本里
   `ALLOW` 的路径正则从 `p7b_build0x1C` 改成新名，并留了"因与 `p7b_build_0x1C` 撞名被 TL 改名"的注释）。**我保留该改动**，
   不再另造目录；0x1C 与 0x1D 两份材料**同目录**（`apply_readside_bid1c.py` 一个文件管两个目标）。
3. **脚本文件名保留 `apply_readside_bid1c.py`**（虽然它现在也管 0x1D）：为的是**不破坏你们已引用的路径**
   （台账 §10-5-4 写的就是"读侧同步 → …"，你们那条 `--apply` 命令仍逐字可用）。名字里的 `1c` 只是它的**来源代**。
4. **`0x1B` 不存在于链上**：wrapper 注释逐字"`0x1B` 记为**已分配、从未构建**" ⇒ 链 = `0x1A → 0x1C → 0x1D`，
   没有 `0x1B` 阶段（若将来真出现 `0x1B` 位流，本脚本要**加阶段**，不是改现值）。
5. **`0x1D` 的档表是"同 NW 第三行"**：70 字那一代完成后档表 = `70|0x1D` / `70|0x1C` / `70|0x1A` / `67|0x19` / `66|0x18` / `65|0x17` /
   `63|…` / `61|…`（共 8 行；彩排里 `TIER_TOP ... (共 8 档)` 即此）。台架按 `(NW, BID)` 双键匹配 ⇒ 旧位流仍可测。
6. **并发写入者仍在**：`_proj_10g/notes/p7b_defect_board_20261011/`（S-0 臂）+ `p7b_build_0x1D/`（persist 构建轮）都**在飞**；
   本脚本对前者整目录 ALLOW、对后者按扩展名自然排除。⇒ 重跑 `--face` 看到的行数会变，但**"未登记"必须恒为 0**。
7. **参数化过程中自己踩到的一个真坑（已修 + 已加防呆）**：`families_for()` 最初用 `ALL_BIDS` 过滤"更早的身份"，
   而 `ALL_BIDS` 只有链上的 `0x1C/0x1D` ⇒ 对 target `0x1C` 得到**空 alternation** ⇒ `re.compile("")` **匹配一切**
   （实测 `--face` 命中 1843 文件 / 未登记 1061）。修法 = 引入 `HISTORY_BIDS`（含链外的 `0x1A`）+ `assert pat, "…空…"` 防呆。
   ⇒ 教训：**"更早的值"集合必须显式含链外历史值**；空 regex 是"静默全命中"的经典形态。

## 6. 授权后怎么用（apply 序 + 前置门）

```
# ① 0x1C (等 S-0 回来 + TL 放行; 板级 S-0 跑在 F 位流上, 与读侧同步不冲突)
python .../apply_readside_bid1c.py                     # 干跑 (期望 24 hits 全中 + A/B/D 绿 + C 24 红 = 待改处)
python .../apply_readside_bid1c.py --apply             # 落盘 (期望末行 OK, RC=0)
# ② 0x1D (等 persist 位流收口) —— ⚠️ 先复读 wrapper 复核目标值
python .../apply_readside_bid1c.py --bid 0x1D          # 干跑: 若 0x1C 已落盘 ⇒ 期望 24 hits 全中
python .../apply_readside_bid1c.py --bid 0x1D --apply  # 落盘 (前置门: 0x1C 未落盘 ⇒ 响亮 FAIL)
# ③ 每次 apply 后: 复读 wrapper + 重跑 --rehearse (期望全绿) + 对端 /tmp/p7b_biz/ 部署件必须与板上同代
```

## 7. 本件未做的事（边界）

- **未 apply**（两个目标都没落盘）；**未改**任何被同步目标文件；**未跑** xsim/Vivado；**未 ssh 写对端**；git 只读。
- **不下 PASS/FAIL 裁定**：§3/§4 的"全绿/红"只描述判据自身的机械结果。
- **未**给 `0x1B` 建阶段（它从未构建）；**未**动 `burn_arm.sh` 的半代问题（0x1C 报告 §4-1 已登记）。
