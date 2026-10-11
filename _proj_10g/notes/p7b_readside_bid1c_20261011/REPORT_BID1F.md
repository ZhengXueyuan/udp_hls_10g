# 0x1D → **0x1E** → **0x1F** 读侧同步 —— **已 apply 落盘**（2026-10-11）

TL 指令 = 链上再加两阶段（`0x1D→0x1E` BID-only；`0x1E→0x1F` **BID + 几何**）并**链式 apply 到 0x1F**。
⛔ 只动本目录内的脚本 + 被同步目标文件（17 件）；`rtl/` `tb/` `sim/` `board/` 其余未动；git 只读（未提交）。

## 0. 一句话

**已落盘：`APPLY_READSIDE_BID OK (target 0x0000001F, 2 阶段 / 82 处 edit, 0 fail)`，RC=0。**
落盘后 `--assert` **0 FAIL RC=0**；`--face` **0 未登记**（250 行 / 123 文件）；17/17 目标件指纹变化（其余零触碰）。

## 1. 两阶段清单

### 阶段 ③ `0x1D → 0x1E`（**snd_wnd 守卫**；BID-only）—— **23 处 / 14 文件**
> ⚠️ **23 处（不是 24）**：`sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的 BUILD_ID 判据已被 **M1 实施轮**手工带到
> `0x1E`（其注释逐字"期望值 0x1D → 0x1E —— 树上 wrapper_p4.v 的 BUILD_ID_V = 32'h0000001E"）⇒ 本阶段**跳过**它。

| 文件 | 处数 | 值面（0x1D → **0x1E**） |
|---|---|---|
| `_proj_10g/notes/p7b_affinity/j6_r6fix.sh` · `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh` | 4 | `EXPECT_BID` 默认值；`GEOM_TIERS` 再插一行 `"70\|0x0000001E\|61 62\|snd_wnd 守卫 (2026-10-11) 70 字 / BID 0x1E"` |
| `_proj_pcie/p7b_biz/p7b_snap.sh` | 2 | `EXPECT_BID`；头部"现役"行 + 新 ⭐ snd_wnd 块 |
| `_proj_pcie/p6e_snap_check.sh` · `p7b_gate4_accept.sh` | 2 | `EXPECT_BID`（几何不动） |
| `_proj_pcie/p7b_gate4_selftest.sh` · `p6e_snap_selftest_fix2.sh` | 3 | "现役"注释 + 两处 `FAKE_BID` |
| `_proj_pcie/p7b_gate4_negctrl.sh` | 2 | 几何自述行 + 假快照 `BID` |
| `_proj_pcie/p7b_gate4_livefake.sh` | 2 | 注释 + `bid={70:"0x1E",…}.get(nw,"0x1E")` |
| `_proj_10g/notes/p7b_gate4_3/final_state.sh` · `p7b_gate4_criteria/gen_inputs.py` | 5 | `EXPECT_BID` / 几何 docstring / 夹具自述 / 逐代链 / `BID_FIX` |
| `sim/p6e_pcie/tb_p6e_pcie_counters.v` | 1 | `chk(… 32'h0000001E)` |
| `_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh` | 2 | 描述现役缺省档的两处文本 |

### 阶段 ④ `0x1E → 0x1F`（**M1 镜像窗**；BID **+ 几何**）—— **59 处 / 17 文件**
**BID 面 = 24 处**（= 上表 23 处 + `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的 BUILD_ID，由本阶段接走 0x1E→0x1F）。

**几何面 = 35 处**（M1: 快照 **70→71**，W70 = `app_rx_mirror.drop_bytes`；未实现地址**公式变了**）：

| 面 | 文件 | 处 | 说明 |
|---|---|---|---|
| 未实现地址**公式** | `_proj_pcie/p7b_biz/p7b_snap.sh` · `p6e_snap_check.sh` · `p7b_gate4_accept.sh` | 3 | `0x20+4*NW` → **`0x20+4*NW+16`**（M1 期B: 快照末字后接 `MIR_STATUS/DATA/CTRL/DMA_CNT` 四字）⇒ 71 字 = **0x14C**；注释明写"读旧位流须显式 `UNIMPL_ADDR=`" |
| NW 默认值 | 同上 3 件 + 两个 j6 | 5 | `70 → 71`（⚠️ j6 两处是 **C 段断言在彩排里抓出来的真漏**） |
| 表长/表尾 | `p7b_snap.sh`（`NAME[] += [70]=mir_drop_bytes`）· `p6e_snap_check.sh`（`WLABEL += mir_drop_bytes` 行）· `p7b_gate4_livefake.sh`（`+ [0]*19 → 20`）· `p7b_gate4_negctrl.sh`（`V` 数组 +1 / 循环 `i<70→71` / `awk -v NW=70→71`） | 6 | 表长断言 A 段（== NW=71） |
| 假板子地址表 | `p7b_gate4_selftest.sh`（新 `SW≥71` 分支：`0X114..0X138` 真字 + **`0X14C` 未实现**）· `p6e_snap_selftest_fix2.sh`（加 `0X138` 真字 + 未实现改 `0X14C`） | 4 | FAKE_TAIL |
| `final_state.sh` | `UNIMPL=$(rd 0x138) → $(rd 0x14c)` + 注释 + `W70=$(rd 0x138)` 行 | 3 | |
| `gen_inputs.py` | `NW_FIX 70→71` / docstring `W0..W70` / `snap_words` docstring | 3 | |
| 指纹 | `p7b_biz_win/run_xvlog_wrapper.bat` · `sim/p5wu_p1p2/run_xvlog_wrapper63.bat` | 2 | `SNAP_NW_P6E = 70 → 71` |
| 链门 TB | `_proj_10g/p7b_chain/sim/tb_p7b_chain.v` | 3 | `axil_read(32'h138→0x14C)`（⚠️ **真漏**，见 §4）· `chk("7b 0x14C …")` · bound 文本 `70-word → 71-word` |
| 档表 | 两个 j6 `GEOM_TIERS` | 2 | 插 `"71\|0x0000001F\|61 62\|M1 镜像窗 (2026-10-11) 71 字 / BID 0x1F (W70 = app_rx_mirror.drop_bytes; 未实现地址 0x138 → 0x14C)"` |
| j6 几何门注释 | 两个 j6 | 2 | `NW=${NW:-70}`（构建 F）→ `71`（M1） |

**不动**（与历轮同判）：F/E/D 各轮板级现场、`p7b_persist_board_20261011/`（两臂烧归档 0x1C/0x1D 位流）·
`p7b_sndwnd_board_20261011/`（0x1E/0x1D 臂）· `p7b_defect_board_20261011/`（S-0 刻意 0x1A）· 各 `*_tools/*.deployed.sh` 快照 ·
`p7b_build_0x1[CDE]/`（构建轮目录）· `p7b_m1*_(synth|impl)_2026*/`（M1 综合/实现产物）· `burn_arm.sh`（位流绑定）。

## 2. 内存演练（apply 前）—— 全绿

```
$ python apply_readside_bid1c.py --bid 0x1F --rehearse          [RC=0]
REHEARSE 盘上读侧代 (哨兵 _proj_10g/notes/p7b_affinity/j6_r6fix.sh) = 0x0000001D; 目标 = 0x0000001F
REHEARSE 阶段链: 0x1C(24 处)[已在盘上] -> 0x1D(24 处)[已在盘上] -> 0x1E(23 处) -> 0x1F(59 处)
REHEARSE 阶段 0x0000001E (snd_wnd 守卫 (2026-10-11)): applied=23 / skipped=0
REHEARSE 阶段 0x0000001F (M1 镜像窗 (2026-10-11)): applied=59 / skipped=0
---- 彩排 A/B/C/D (内存 overlay; 仓内文件不动; 按目标代几何 NW=71 / 未实现 0x14C) ----
SEARCH_FACE OK (4 族 / 250 命中文件)     (bid-oldvalue[0x1A,0x1C,0x1D,0x1E] 34 · identity-BID 91 · geometry-NW 91 · unimpl-addr 34; 未登记 0)
OK   EDIT_COVERAGE (本阶段 EDITS 文件 17 / 有对应断言 17)
REHEARSE OK —— 全绿 ⇒ 清单完整且自洽 (target 0x0000001F; 剩余 2 阶段 / 末阶段 59 edits; 0 fail)
```
（原文 = `REHEARSE_BID1F_OUTPUT.txt`；落盘后复跑 = `REHEARSE_BID1F_POSTAPPLY.txt`，全部阶段标 `[已在盘上]`、仍全绿。）

⚠️ **`--bid 0x1E --rehearse` 单独跑会红 5 条**（`REHEARSE_BID1E_OUTPUT.txt`）——**是"树已被 M1 轮推过"的如实反映**：
`tb_biz_win.v` / `run_tb_biz_win.bat` / `check_window.py` / `tb_p6e_pcie_wrapper.v` 的几何已被 M1 轮手工改到
`NW=71 / 0x14C`（其注释逐字"构建轮…留给读侧脚本的重生成"）⇒ 用 0x1E 的几何去断言它们必然红。**这不是漏**。

## 3. 负对照（apply 前 4 条 + apply 后 4 条 + 负彩排）

| 件 | 破坏 | 结果 |
|---|---|---|
| `NEGCTL_table_{0x1E,0x1F}.txt` | 删 WLABEL 末项（表长 −1; 锚点动态取"末项"以防逐代漂） | A 红 · RC=1 |
| `NEGCTL_bid_*` | `EXPECT_BID` 改 `0x00000009` | C 红，**含目标断言 `j6_r6fix.sh[BID]`** · RC=1 |
| `NEGCTL_tier_*` | 档表首行改 `70\|0x00000009` | C 红，**含 `tcpreg_j6.sh[TIER_TOP]`** · RC=1 |
| `NEGCTL_face_*` | 未登记新文件带**目标的前一代值** | B 红（3 族同抓） · RC=1 |
| `NEGCTL_*_0x1F_postapply.txt` | 同上（落盘后复跑） | 全部 RC=1；`bid`/`tier` 各**恰好 1 条红**（= 注入那处，隔离干净） |
| `NEG_REHEARSE_BID1F.txt` | **负彩排**：链式 apply 但故意漏掉末阶段**最后一处** | **恰好 1 条红**，就红在被漏那处（`tb_p7b_chain.v[NW]`）· RC=0（= 负彩排成立） |

⭐ 负彩排**还抓到一个真缺陷**：它第一次跑报**"没牙"（0 条红）** ⇒ 查明 = 那处（链门 TB 的 `bound` 文本行）
**原本没有断言**（历史句全是 `//` 注释，唯一活行没人核）⇒ **已补一条 NW spec**（`^\s{10,}"axi_regs decode; (\d+)-word bound`），
补后负彩排 = 恰好 1 条红。⇒ "漏一处 ⇒ 恰红那处"这条牙齿，**正是它把"改了一处没人核"抓出来的**。
⚠️ 落盘后负彩排走"**反演重建**"路径（链已空 ⇒ 把末阶段 new→old 撤回内存得到 apply 前态再跑同一套）——结果同（1 条红）。

## 4. C 段断言在彩排里抓出的 **3 处真漏**（apply 前被拦下）

1. `_proj_10g/notes/p7b_affinity/j6_r6fix.sh` 的 `NW=${NW:-70}`（+ 其几何门注释里的同一串）—— 首版 0x1F 清单只改了
   `p7b_snap.sh` 的 NW，**漏了台架自己的 NW**（台架也按 NW 匹配档表）。
2. `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh` 同上。
3. `_proj_10g/p7b_chain/sim/tb_p7b_chain.v` 的 `axil_read(32'h138, v);` —— 首版只改了 `chk("7b …")` 的**标签**，
   没改**地址实参**（典型的"改了名没改物"）。
⇒ 三处均为 **spec 的预期值 vs 实际值** 报红（不是锚点缺失），补进 `EDITS_1F` 后全绿。**这正是"逐处断言"要买的东西。**

## 5. `--apply` 输出（末 6 行 + RC）

```
OK   _proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh BID = 0x1F  期望 0x0000001F   缺省档 …
OK   _proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh BID = 0x1F  期望 0x0000001F   默认档 …
OK   _proj_10g/notes/p7b_biz_win/check_window.py   派生式  {'nnew_top': 5, 'ntx': 1, 'nnew': 14}  nnew_top+ntx+nnew == NW-51
---- D. 清单-断言覆盖 (每个 EDITS 目标必须自带断言) ----
OK   EDIT_COVERAGE (本阶段 EDITS 文件 17 / 有对应断言 17)
APPLY_READSIDE_BID OK (target 0x0000001F, 2 阶段 / 82 处 edit, 0 fail)      ← RC=0
```
（全文 = `APPLY_BID1F_OUTPUT.txt`；链式视图下 82 处 edit 全 `OK`、`SKIP` 0。）

⚠️ **首次 apply 曾"静默不落盘"（已定位并修）**：我给写盘分支写的是 `if do_apply and tag == "OK":`，而 `tag` 是**带两个
对齐空格的** `"OK  "` ⇒ **比较恒假** ⇒ 干跑看着全对、apply 后文件一个字节没变（`git status` 干净）。
修 = 判据改用**数值条件** `k == n`（不再拿显示用字符串当判据）。⇒ 与全局 #53 同族（"判据的字面量不是同一物"），
本件已把该教训写进脚本注释。

## 6. 落盘后复核

```
$ python apply_readside_bid1c.py --bid 0x1F --assert      [RC=0]  0 FAIL（A 表长 5/5 · B 搜索面未登记 0 · C 全绿 · D 17/17）
$ python apply_readside_bid1c.py --bid 0x1F --face        [RC=0]  250 行 / 123 文件 / 未登记 0
$ python apply_readside_bid1c.py --bid 0x1F --rehearse    [RC=0]  全部阶段"[已在盘上]"、全绿
```
盘上现态抽查：j6 `EXPECT_BID=0x1F` / `NW=71`；`p7b_snap.sh` `NW=71` / `UNIMPL_ADDR` 公式 `+16` / `[70]=mir_drop_bytes`；
`p6e_snap_check.sh` `SNAP_WORDS=71`；`final_state.sh` `$(rd 0x14c)`；`gen_inputs.py` `NW_FIX=71 / BID_FIX=0x1F`；
`tb_biz_win.v` `NW = 71`；j6 档表首行 `"71|0x0000001F|…"`。
指纹：**17/17 目标件全变**（`TARGET_SHA_BEFORE_BID1F.txt` vs `POSTAPPLY_SHA_BID1F.txt`）；`git status` 只有这 17 件
+ 其它 agent 自己的在途改动。

## 7. 遗留 / 需知悉（如实）

1. **有一个"两处不同代"的窗口**：读侧现 = **0x1F**，而 `board/wrapper_p4.v` 的 `BUILD_ID_V` 现读 = **0x1E**
   （M1 构建才会 bump 到 0x1F；TL 派单已知）。窗口内：`sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的判据 2
   （`chk(… 0x1F)`）对**当前树**会红 —— 它是"跟地图走"的判据，**等 wrapper bump 后自动对**；读侧身份门对 0x1E 板会 `ID_FAIL`（属预期）。
2. **几何权威值**：以现读 `board/wrapper_p4.v`（`SNAP_NW_P6E = 71`）+ `_proj_pcie/rtl/axi_regs.v`
   （`MIR_LAST_IDX+1 = 0x14C`；`未实现地址 = 0x20+4*SNAP_NW+16`）为准，两者一致；派单提到的"MIR 五字"实为
   **4 个寄存器**（`MIR_STATUS/DATA/CTRL/DMA_CNT` @0x13C/0x140/0x144/0x148）+ **1 个快照字 W70**（@0x138 = `mut.drop_bytes`）——
   合计 5 个新地址，与现读一致。⛔ **待 M1 构建收口后复读 `board/wrapper_p4.v` 复核 BID/几何一次**。
3. `_proj_10g/notes/p7b_biz_win/tb_biz_win.v` / `run_tb_biz_win.bat` / `check_window.py` 的几何**由 M1 轮手工改好**
   （NW=71 / `0x20+4*NW+16`），本轮**未再动**（只由断言核对）。
4. `--asset`… 无。未跑 xsim/Vivado；未 ssh；git 只读（改动**未提交**，等 TL/构建轮归档）。
