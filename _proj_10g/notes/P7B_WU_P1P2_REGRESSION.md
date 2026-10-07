# P7B-WU 二轮（P1/P2 + 快照 61→63）—— **独立回归报告**

- 日期：**2026-10-07**　角色：**回归测试 agent（独立于实现 agent）**
- 基线：HEAD = **`95c9485`**，工作区改动 = `rtl/app_ctrl.v`（P1/P2）+ `board/wrapper_p4.v`（窗口 61→63 /
  `BUILD_ID_V` 8→9 / 未实现地址 `0x114`→`0x11C`）+ 新 TB `tb/tb_wu_p1p2.v` `tb/tb_snap63.v`
- 我做了什么：**全仓 16 门 P4 矩阵**（作者未跑）+ **作者未跑的追加门**（`p5_wrapper`/`p5_status`/`p5_pattern` +
  `p5d_multi` 四个档）+ **每一个红的 HEAD 双臂 A/B 归属** + **一条覆盖面的硬裁定**（见 §4）。
- 纪律：⛔ 未烧板、未碰板子、未写 `0x08`；⛔ 未改任何既存源文件/tb/bat（所有副本都在 `sim/p5wu_p1p2_regress/`）；
  ⛔ 未提交 git。**零位流、零板级读数。**

---

## 0. 一页结论

| # | 问题 | 结论 |
|---|---|---|
| ① | 16 门 P4 矩阵 | **16/16 EXIT=0，`VERDICT: FROZEN`**（237 文件逐字节不变）；逐门都有**真判据行**（不是只有 banner） |
| ② | 矩阵**能**发现这两个改动文件的回归吗 | ⛔ **不能。** 见 §4 —— **硬证据**：矩阵哈希集（237 文件）**一个都不含** `app_ctrl.v` / `wrapper_p4.v`，且与本轮无关的 09-30 旧 commit 运行**逐字节同指纹** |
| ③ | 作者未跑的追加门 | `p5_status` 绿 · `known_idle_fifo` 绿 · `p5d_multi` 三个负对照**红得正确**（只红在注入判据上）· `p5_wrapper` **红（既存）** · `p5_pattern` **红（既存，且与本轮结构无关）** |
| ④ | 每一个红的归属 | **全部 4 个红都有双跑对照**：`p5_wrapper`（HEAD 臂逐字相同）/ `p5_pattern`（编译集 = HEAD 字节）/ `p5d neg_wq`（HEAD 臂逐条相同）/ `p6e_pcie` 的 `0xEC`（HEAD 臂同样红）。**没有一个是新红** |
| ⑤ | 作者"忘了改会响亮失败、不会静默误判"这条声称 | **对两个检查脚本成立**（`p6e_snap_check.sh` 判据 6.1 / `p7b_gate4_accept.sh` B_UNIMPL 都**当场断言**）· **对 `p7b_snap.sh`（它点名的那个）在其落笔版本上不成立**：`id_check` 只断言 MAGIC+BID，`UNIMPL`/`MARKER` **只 print**；`full/snap/pair` 三个子命令**根本不调 id_check**。详见 §5（含并发事实：该缺口已在 08:52:12 被另一个 agent 补上） |
| ⑥ | 有没有别处会**静默** | 有**两条仍在**（都不在作者的 §8 清单里）：`tcpreg_j6.sh:53` / `j6_fix.sh:58` 自带的 `NW=${NW:-61}` 元数据（取数器升 63 后它会把几何记错且**不报错**）。另有一条**已被并发轮修掉**（`final_state.sh` 08:53 → `0x11C`）。见 §5.3（带时间戳） |

---

## 1. 环境与并发（**读数归属的前提**）

| 项 | 值 |
|---|---|
| 仓库 | `D:\repo\XCKU5PMini\udp_hls_10g`，`git rev-parse HEAD` = `95c9485` |
| 我的工作目录（独占） | `sim/p5wu_p1p2_regress/`（所有副本、日志、A/B 臂都在这里；**canonical 目录一律不动**） |
| ⚠️ 唯一被我写过的**已跟踪**文件 | `sim/p4sim/matrix_p4dfix.log` —— 这是 **runner 自己的产物路径**（`paths.txt` 的 `MATRIX_LOG`），不是我改的源码；副本已存进我的 scratch |
| 矩阵运行窗口 | **08:49:42 → 09:14:57**（≈25 min），16 门 |
| 追加门窗口 | **09:15:24 → 09:29:46**，7 门（该窗口内 09:26:48 `tasklist` 复测：只有我这一串 sim） |
| A/B / 追加臂窗口 | **09:25:36 → 09:39**；⚠️ **我自己造成过一次重叠**：09:25:36 起的两条 A/B 臂（`p5_wrapper` 然后 `neg_wq`）与还没跑完的 `known_idle_fifo`（09:24:17–09:29:46）**同机并跑约 4 min** —— 正是全局 #50 的形态。⇒ **两个红都做了隔离重跑**（09:37:06 / 09:38:09，各先 `tasklist` 确认零别的 sim）：**`ab_wrapper_head_iso.log`（EXIT=1）与 `ab_neg_wq_head_iso.log`（EXIT=1）都与首跑、与工作区臂三方 `diff` 逐字节相同** ⇒ **重叠没有制造伪影**（另：两个"工作区臂"本身都跑在隔离窗口内） |
| 同机并发（实测，**按证据写**） | 两个时间点的 `tasklist`：08:52:55 **只有我的** `xsim.exe`+`xsimk.exe`；09:15:24（追加门前）**零** xsim/xelab/vivado。⚠️ **但文件 mtime 证明窗口内有别的 agent 在仿真**：`sim/p5sim/resp_p5_app.memh` = **08:57**、`sim/p5sim/{adv_cmds,resp_p5_adv}.memh` = 08:42、`sim/p5wu_p1p2_review/run/` = 09:00（对抗审查 agent 的工作目录，08:49–09:00 持续在写）。⇒ **不能宣称"全程只有我一个 sim"**；能宣称的是：我的**每一个读数都是绿的或已归属的**（没有一个"孤零零一条红"），且 16 门全绿里每一门都有真判据行（不是只有 banner）⇒ 按全局 #50/#48 的口径，**没有需要隔离复跑的红**。无 Vivado 构建运行 |
| ⚠️ 但有一个**真实的并发写入** | 另一个 agent（测量脚本轮）在 **08:52:12 / 08:52:33 / 08:52:47 / 08:53:23 / 09:06:33** 改了一批板侧脚本：`_proj_pcie/{p7b_biz/p7b_snap.sh, p6e_snap_check.sh, p7b_gate4_accept.sh, p7b_gate4_selftest.sh}`、`_proj_pcie/rtl/axi_regs.v`、`_proj_10g/notes/p7b_gate4_3/final_state.sh`（`git status` 可证）。**这些文件不在矩阵的哈希集/编译集里** ⇒ 实测矩阵 `VERDICT: FROZEN`、前后 `DIGEST_ALL` 完全相同 ⇒ **未污染本轮任何仿真读数**；但 §5 的静态结论必须**带时间戳**读（见 §5.3） |

---

## 2. 全仓 16 门 P4 矩阵（作者未跑 · 我跑了）

**逐字命令**（自定位 runner，无参数 = 全 16 门；Git Bash 经 `cmd //c` 调 .bat）：
```bat
:: sim/p5wu_p1p2_regress/run_matrix_here.bat（我写的唯一入口，内容 3 行）
cd /d "%~dp0..\.."
call sim\p4gates\run_matrix_p4dfix.bat > "%~dp0matrix_stdout.log" 2>&1
```
```bash
# 从 Git Bash 调：
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p5wu_p1p2_regress\run_matrix_here.bat'   # 退出码 0
# 两列取数器（A = 矩阵日志 per-gate EXIT + gatebrief 尾 6 行；B = 各门 work 目录自己的 console + xsim 日志）
python sim/p5wu_p1p2_regress/collect_matrix.py sim/p4gates/work_20261007_084942 sim/p4sim/matrix_p4dfix.log
```

**总结行（逐字）**：`gates run : 16 / 16` · `gates failed: 0` · `MATRIX_BAT_EXITCODE=0` ·
`VERDICT: FROZEN -- all 237 hashed files byte-identical across the run` ·
`DIGEST_COMPILE=1dc18432…d1b9 (201 文件)` · `DIGEST_ALL=eeda6b6a…299d (237 文件)` · `GIT_HEAD=95c9485`

### 2.1 逐门表（**两列都抓**）

| # | 门 | EXIT | A 列（矩阵日志里的判据行） | B 列（门自己 work 目录的日志） |
|---|---|---|---|---|
| 1 | `chain` | 0 | `P4 CHAIN OK`（RX=9 TX=11 fast=6 slow=5 STRIPPED=0） | console 6 行一致 |
| 2 | `burst200` | 0 | `BURST OK`（TRUNCS(0,0) ECOMAX 182 · STRIPPED 0） | console 16 行一致 |
| 3 | `trunc50` | 0 | `BURST OK` | console 16 行一致 |
| 4 | `trunc100` | 0 | `BURST OK` | console 16 行一致 |
| 5 | `halfdrop` | 0 | `BURST OK` | console 16 行一致 |
| 6 | `txdrop50` | 0 | `BURST OK` | console 一致 |
| 7 | `gate4096` | 0 | `BURST OK` | console 一致 |
| 8 | `dupstorm` | 0 | `BURST OK` | console 一致（⚠️ 见 §2.2） |
| 9 | `pcackoob` | 0 | `BURST OK` | console 一致 |
| 10 | `vlanchain` | 0 | `P4 CHAIN OK` | console 一致 |
| 11 | `vlanburst` | 0 | `BURST OK` | console 一致 |
| 12 | `stallgate` | 0 | `PCSTALL OK (burst=200, echo 帧 240)` | console 一致 |
| 13 | `unit_retx` | 0 | `ALL 7 GROUPS PASS` | ⚠️ 该门 bat 以 `type xsim.log` 收尾（**exit 0 无条件**）⇒ 必须读 B 列：`xsim.log` 里 `GRP C/D/E/F/G : PASS` + `ALL 7 GROUPS PASS` |
| 14 | `unit_fifo` | 0 | `PASS_ALL frame_fifo unit: writes A=568139 … cycles=750700` | ⚠️ 同上无条件 exit ⇒ B 列 `xsim_ff.log` 4054 行，`PASS_ALL` 在 |
| 15 | `unit_vlan` | 0 | `VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)` | console 只有 2 行，判据行在 A 列 |
| 16 | `unit_uart` | 0 | `UART-GATE-OK`（`ALL_OK`） | console 252 行，`ALL_OK`+`UART-GATE-OK` |

**附加硬扫描**：16 个 `_gate_console.log` 里 **`grep -i fail` 命中数全部为 0**；`scanlog` 每门都报 `0 outside the repo`。
（`xsim` 日志里有若干 `Memory Collision Error on RAMB36E1 … chk_for_col_msg` —— 是 TB 的 BRAM 模型诊断输出，
**不是**门判据，且与本轮两个改动文件无关：这些日志里 `app_ctrl`/`wrapper_p4` 一个都不出现。）

### 2.2 `dupstorm`：上一轮的"孤零零一条红"**本轮没有复现**

- 上一轮（`sim/p5wu_regress/matrix_stdout.log`，02:11）此门 `EXIT=1`，其 console 里是
  **检查器 IndexError**（`tools/gen_stim_p4_chain.py:518 parse_gmii … IndexError`，resp memh 被截断）——
  正是全局 #50 的"引擎被饿死 ⇒ 截断 ⇒ 检查器炸"签名；上一轮隔离重跑即 `RERUN_DUPSTORM_EXIT=0`。
- **本轮**：`dupstorm EXIT=0 / BURST OK`，且我的运行窗口内**没有别的 xsim**（§1）⇒ **判为上游间歇，非既存缺陷**。

---

## 3. 作者未跑的追加门（**7 门**）

> 为什么必须跑这三门 + 四档：它们是**唯二**会编译 `rtl/app_ctrl.v` 的仿真门（另一族是 p6e_pcie），
> 而 §4 会证明全仓 16 门矩阵**根本不编译**这两个改动文件。

**逐字命令**（每个 .bat 都是我 scratch 里的**逐字副本**，只替换 `cd`/`SIM` 两个 token 以把产物落进我的目录；
canonical `sim/p5sim/` 与 `sim/p5d_multi/` **一个字节都没被写**；副本与原文 sha256 已登记）：

```bash
python sim/p5wu_p1p2_regress/mk_p5sim_ab.py        # 生成 run_tb_p5_{wrapper,status,pattern}_here.bat
cp sim/p5d_multi/run_tb_p5_multi.bat sim/p5wu_p1p2_regress/   # 逐字副本（REPO_ROOT 自定位照旧成立）
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p5wu_p1p2_regress\run_extra_gates.bat'
```

| 门 | EXIT | 关键读数（逐字） | 归属 |
|---|---|---|---|
| `p5_wrapper` | **1** | `wrapper GMII: 0 帧 (conn0 数据 0 / 其它 0 / 坏 FCS 0)` → `MISMATCH: wrapper 只出了 0 个 conn0 数据帧 (<2)` → **`P5 WRAPPER FAIL (1 项)`**；sim 本体跑完（`P5W DONE` @133200 ns，`tx(frames=0 bytes=0)`），`resp_p5_wrapper.memh` = **0 字节** | ⭐ **既存红**（§3.1 A/B） |
| `p5_status` | **0** | `STATUS got : 'P5B1 ST=1 NX=12345679 … UTB=12345678 UTF=0BB8'` 与 `exp` **逐字符相同** → `P5 STATUS OK` | 绿 |
| `p5_pattern` | **0（内容却是 FAIL）** | `P5 PATTERN FAIL viol=0 last_beats=2 keep_bad=1 active=0`（+ case1/case2 两行） | ⭐ **既存红 + 与本轮结构无关**（§3.2） |
| `p5d_multi neg_wq` | **1** | `112 checks, 24 FAIL` = ①×2 + ⑥×2 + ⑦×1；`[neg_wq] 期望 ① FAIL` 断言在（门有牙） | 设计性红 ✔ |
| `p5d_multi neg_mgn` | **1** | `112 checks, 7 FAIL` = **只有 ④×7**；`[neg_mgn] phys_bad=[…]` 断言在 | 设计性红 ✔（最干净的一个） |
| `p5d_multi neg_mgn0` | **1** | `112 checks, 4 FAIL` = ⑥×2 + ⑦×2；`[neg_mgn0] 期望 ⑦ FAIL: seq=2 rewind=2` 断言在 | 设计性红 ✔ |
| `p5d_multi known_idle_fifo` | **0** | `[probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728` | 绿 |

⚠️ **读法坑（必须写下来）**：`neg_*` 三档的 `EXIT=1` 是**设计使然**（判据 ①/④/⑦ 被注入的缺陷打红 ⇒
`ck.fails` 非空 ⇒ 检查器 `return 1`）；**"红的名单"才是判据** —— 我逐条比对过名单（§3.3）。
⚠️ **`p5_pattern` 的 EXIT=0 是假绿**：该 bat 的最后两行是 `findstr /C:"P5 PATTERN" …` / `findstr /C:"W3 case" …`，
**退出码 = 最后一个 findstr 的命中与否**，与 PASS/FAIL 无关。⇒ 本工程"bat 只打印 banner 不置退出码"的老坑，
在这一门上是**现役**的。

### 3.1 `p5_wrapper` 的 A/B（HEAD 双跑）——**逐字相同**

```bash
python sim/p5wu_p1p2_regress/mk_head_ab.py sim/p5sim/run_tb_p5_wrapper.bat ctrl,wrap head
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p5wu_p1p2_regress\run_ab_head.bat'
```
| 臂 | 编译的 `app_ctrl.v` / `wrapper_p4.v` | EXIT | 读数 |
|---|---|---|---|
| 本轮（工作区） | `295d5ecf…`(ctrl) / `d804a64a…`(wrap) | **1** | `wrapper GMII: 0 帧 …` + `P5 WRAPPER FAIL (1 项)` |
| HEAD（`git show 95c9485:`） | `c8e00067…`(ctrl) / `10056819…`(wrap) | **1** | **与上行 `diff` 结果：完全相同（0 行差异）** |

⇒ **判定：既存红**，且与本轮改动无关。
⚠️ **补一步（我自己的并跑污染自查）**：HEAD 臂首跑与 `known_idle_fifo` 重叠了约 4 min（§1），
故 **09:37:06 隔离重跑**（`ab_wrapper_head_iso.log`，EXIT=1）⇒ 与首跑、与工作区臂**三方逐字节相同**
（**本报告里的 `p5_wrapper` 读数取隔离重跑那一份**）。
根因**未定位**（症状 = TB 的 APP_MODE 激励路径产不出帧；`P5W DONE` 说明 TB 跑到了终点）——
明确登记为**未定位的遗留**，不冒充已答。

### 3.2 `p5_pattern` 为什么连"归属"都不需要跑 A/B —— **结构论证**

该门的**全部编译集** = `rtl/app_pattern.v` + `tb/tb_p5_pattern.v`。两者的 **sha256 与 HEAD 完全相同**
（`b6a9fa0e…` / `3ed9f21e…`，`git status` 对二者**无修改**）⇒ 本轮 diff **不是它的输入** ⇒
它的红**不可能**由本轮引入。（读数也与上一轮 `p5_pattern_stdout.log` 逐字相同：`keep_bad=1`。）

### 3.3 负对照档：与**09-30 canonical 基线**逐条比对（零成本，不烧 xsim）

同一检查器（`tools/gen_stim_p5_multi.py`，本轮**未改动**——它同时在矩阵哈希集里，前后一致）直接跑
`sim/p5d_multi/<case>/resp_p5_multi.memh`（09-30 现场件）：

```bash
python tools/gen_stim_p5_multi.py sim/p5d_multi/<case> <case> check     # 只读，返回 ck
```

| 档 | 09-30 canonical | 本轮（工作区） | 名单是否逐条相同 |
|---|---|---|---|
| `neg_wq` | 112 / 24 FAIL | 112 / 24 FAIL | ✅ **完全相同**（去空白后集合相等） |
| `neg_mgn` | 112 / 7 FAIL | 112 / 7 FAIL | ✅ 同结构（7 条全 ④）；**仅两条计数值差**：快照5 `555837→555949`、快照6 `557871→557983` |
| `neg_mgn0` | 112 / 4 FAIL | 112 / 4 FAIL | ✅ 同结构（⑥×2+⑦×2）；**仅一处** `MULDONE k=2558285→2558157`（−128 拍） |
| `known_idle_fifo` | `失配 0 … sink=73728` | 同 | ✅ |

⚠️ 口径：09-30 的 memh 来自**更早的 DUT**（BIZ 轮），所以上表是"与 09-30 基线比"，**不是**本轮 A/B。
`neg_wq` 我另外做了**本轮的双臂 A/B**（下面），两者一致。

### 3.4 `neg_wq` 的 A/B（HEAD 双跑）

```bash
python sim/p5wu_p1p2_regress/mk_head_ab.py sim/p5d_multi/run_tb_p5_multi.bat ctrl head
cmd //c '…\run_ab_head.bat'    # 第二臂 = neg_wq
```
| 臂 | EXIT | 汇总行 | FAIL 名单 |
|---|---|---|---|
| 本轮（工作区） | 1 | `== P5d multi: 112 checks, 24 FAIL ==` | ①×2 / ⑥×2 / ⑦×1 |
| HEAD（`c8e00067…`） | 1 | `== P5d multi: 112 checks, 24 FAIL ==` | **集合完全相同**（脚本判定 `identical = True`） |
| HEAD **隔离重跑**（09:38，`tasklist` 确认零别的 sim） | 1 | 同上 | **`ab_neg_wq_head_iso.log` 与首跑、与工作区臂 `diff` 三方逐字节相同**（整份日志，不只是 FAIL 名单） |

⇒ **判定：设计性红，且与本轮改动无关**（强版：连整份响应派生的报告行都逐字节相同 ⇒ 这一档对本轮 diff **零敏感**）。

---

## 4. ⭐ 覆盖面硬裁定：**16 门矩阵对这两个改动文件是"结构性盲"**

这一条比任何绿都重要，且**是我能给出的最硬的证据**：

1. **清单面**：矩阵的 5 个 manifest（`chain_src.f` 覆盖 12 门 + `retx_src.f`/`fifo_src.f`/`uart_src.f`/`vlan_src.f`）
   **一个都不含** `rtl/app_ctrl.v`，**一个都不含** `board/wrapper_p4.v`（逐字读过 5 个 `.f`）。
2. **指纹面**：矩阵哈希集 = 编译集 ∪ HLS 网表 ∪ `FINGERPRINT_GLOBS`，共 **237 文件**；我把它与
   **上一轮那次运行的指纹**（`sim/p4sim/P4_MATRIX_FINGERPRINT_20261007_014439_before.txt`，
   `run at 2026/10/07 01:44:40`、**`GIT_HEAD = ff78247`** —— 与我的 `95c9485` **不同的 commit、
   不同的 DUT 版本**）逐行 diff（path+sha256）：
   ```
   FILE LISTS IDENTICAL (paths+hashes)
   含 app_ctrl / wrapper_p4 的行数 = 0
   ```
   ⇒ **两个不同 commit 的矩阵"修订指纹"逐字节相同**，因为它根本不看这两个文件。
   （另一个可引的旧点：`sim/p5wu_regress/baseline_matrix_prev_commit.log`（`GIT_HEAD=d417589`）
   的 `DIGEST_COMPILE/DIGEST_ALL` 与我也**完全相同** ⇒ 三个 revision 同一个指纹。）
3. **日志面**：本轮 16 个门的 `xvlog/xelab/xsim` 日志里 **0 次**出现 `app_ctrl` 或 `wrapper_p4`。

**推论（必须写进 HANDOFF 的东西）**：
> 「16 门全绿」在本轮**不是**"P1/P2 + 快照改动没有回归"的证据；它只证明**另外 19 个模块**
> （mac/tcp/tcb/retx/echo/rx_classify/vlan/slow_*/tx_arb/frame_fifo + HLS 网表 + UART）仍各自通过。
> 改动本身的覆盖在别处：`rtl/app_ctrl.v` 由 `p5sim`/`p5d_multi` 一族编译；`board/wrapper_p4.v` 的**快照段**
> （`ifdef PCIE_OBS`，第 3035 行起）**只有 `sim/p6e_pcie` 一族会 elaborate** —— 见 §6。

---

## 5. 逐条核作者的声称：「忘了改会**响亮失败**、不会**静默误判**」

作者原文（`P7B_WU_P1P2_SNAP.md` §8-①，点名 `_proj_pcie/p7b_biz/p7b_snap.sh:33-35`）：
> 好消息：忘了改会响亮失败（`0x114` 现在回真数据 ⇒ 未实现地址负对照红；`EXPECT_BID=8` ⇒ 身份闸红），不会静默误判。

### 5.1 证实的部分（两个**检查**脚本：真断言，真响亮）

| 脚本 | 断言处 | 行为 |
|---|---|---|
| `_proj_pcie/p6e_snap_check.sh` | `1.2 BUILD_ID (0x04)` vs `EXPECT_BID`；`6.1` 要求 `$UNIMPL_ADDR == 0xffffffff` **且**同趟 `0x00 != ffffffff` **且** `0x14 == 0xdeadbeef`，否则 `[FAIL]` | 忘改 ⇒ **两条 FAIL**（且 6.1 把"地址没随窗口挪"写进 FAIL 文本） |
| `_proj_pcie/p7b_gate4_accept.sh` | `G1` 身份；`B_UNIMPL`：`un -eq 4294967295` 否则 `FAIL … 或该地址其实是已实现字 (窗口挪了地址没挪)` | 忘改 ⇒ **两条 FAIL** |

### 5.2 ⛔ 推翻的部分：`p7b_snap.sh`（**正是作者点名的那个**）在落笔版本上**不成立**

`git show 95c9485:_proj_pcie/p7b_biz/p7b_snap.sh` 的 `id_check()`（77–90 行）逐字：
```bash
  m=$(rd 0x00); b=$(rd 0x04); k=$(rd 0x14); u=$(rd "$UNIMPL_ADDR")
  echo "ID_UNIMPL $u  (want 0xffffffff: 未实现地址必须走 SLVERR)"
  ...
  [ "$m" = "0x50360001" ] && [ "$b" = "$EXPECT_BID" ] || { echo "ID_FAIL 身份不符 …"; return 1; }
  return 0
```
* **`$u`（未实现地址）与 `$k`（MARKER）只 print，从不比较** —— 全函数只有两处 `return 1`：`m=0xffffffff`、
  以及 `m/BID` 不符。⇒ 只更新 `EXPECT_BID=9` 而忘改 `NW` 时：`id` 会打出
  `ID_UNIMPL 0x00000000 (want 0xffffffff …)` **然后 `ID_OK`、`exit 0`** —— **静默**。
* `full` / `snap` / `pair` **根本不调 `id_check`**（case 分支逐字可证）⇒ 走这三条路时**没有任何身份/几何断言**。
* 它**唯一**的兜底是 `dump_words` 的 `nff`（窗口内出现 `0xffffffff` ⇒ `SNAP_FAIL`）——
  这条兜的是"**板上窗口比脚本小**"（读越过末字 ⇒ SLVERR）；"**板上窗口比脚本大**"（= 忘改 NW 的情形）
  **不触发**它。⇒ 静默方向恰好是**危险的那个方向**。
* ⚠️ **并发事实（不许忽略）**：另一个 agent 在 **08:52:12**（我第一次读完之后 ~2 min）已经把
  `p7b_snap.sh` 改为 `NW=63 / EXPECT_BID=9` **并加上了未实现地址的当场断言**（09:06:33 又改过一次，
  我复核的是 **09:06 版 `md5 6282843073c3…`**：`NW=${NW:-63}`@38 / `EXPECT_BID=0x00000009`@40 /
  断言在 **113 行**）。`git diff HEAD -- _proj_pcie/p7b_biz/p7b_snap.sh` 里能看到它自己的理由，
  逐字："未实现地址必须**当场断言** (不能只 print): 若板上是**更大**的窗口, 这个地址会回**真数据**,
  只打印 "(want ...)" 的话往下就看不出读的是哪一代几何 (本工程"判据安静失效"的老坑)"。
  ⇒ **对 08:52 之后的版本，作者这句话成立**；对**作者落笔时的版本**（以及任何还带着旧副本的地方），**不成立**。
  ⇒ 我把结论**按版本+时间**写，不写成"已修/未修"。

### 5.3 静默面：逐版本清点（**我按 09:36 实测状态写，带上时间戳**）

| # | 位置 | 09:36 实测状态 | 形态 / 建议 |
|---|---|---|---|
| ① | `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh:53`（mtime **02:23**，**未被 08:52 那批改到**） | `echo "### PHASE pre_snapshot … NW=${NW:-61}"` —— **仍是 61** | 这个 61 是**脚本自己的默认值**，**不由所调用的 `p7b_snap.sh` 派生**。取数器升 63 后，J6 的元数据行会写 `NW=61` 而 dump 有 63 行 ⇒ **记录错几何且不报错**。已知用途：J6-ladder 的判读必须带 pace **与几何**（该脚本自己的头注释就要求引用它）⇒ 建议从取数器读几何，或交叉断言 dump 行数 == NW |
| ①b | `_proj_10g/notes/p7b_wu_w54/j6_fix.sh:58`（mtime **03:16**） | 同款 `NW=${NW:-61}`，**仍是 61** | 同上 |
| ② | `_proj_10g/notes/p7b_gate4_3/final_state.sh` | ✅ **已被并发 agent 修**（mtime **08:53:23**）：`rd 0x114` → **`rd 0x11C`**、注释改"63 字 ⇒ 0x11C"、并**新增前置闸**（"上面这行与下面两行都**不判断**读数对不对"） | 我 09:19 读到的旧版本（`rd 0x114` + 只打印）**已不复存在**；此条**闭合**（并发轮） |

⚠️ 记法：本节按**版本 + 时间戳**写，不写成"有/没有"——并发轮正在持续改这批脚本
（`p7b_snap.sh` 在我读完之后又被改了一次：8:52 版 → **09:06 版 `md5 6282843073c3…`**，NW=63/BID=9/断言都在）。

### 5.4 第四种形态：**响亮，但"既存"** —— `sim/p6e_pcie/tb_p6e_pcie_wrapper.v:302`

该门（唯一带 `-d PCIE_OBS` 的**全 wrapper** 门）把未实现地址写死成 **`0xEC`**（P7b **51 字**时代的空地址：
`0x20..0xE8`）。**61 字（BIZ 轮）起 `0xEC` 就是 W51 `app_tx_bytes` 的真地址** ⇒ 该判据自 BIZ 轮起就红。
同一行的 `BUILD_ID` 期望也停在 `7`。⇒ **"未实现地址负对照红"这个方向的判断是对的，但它不是本轮造成的**
（A/B 实证见 §6 的 `head` 臂）。作者 §8-① 的清单**漏了**这个文件。

---

## 6. 追加（超出派单清单）：**唯一真 elaborate 快照段的门** `sim/p6e_pcie`

为什么追加：§4 证明矩阵盲；`p5sim/p5d` 的门编译 `wrapper_p4.v` 时**只有 `-d APP_MODE`、没有 `PCIE_OBS`**
⇒ 快照段（含本轮 61→63 的全部改动）**不被 elaborate**。全仓只有 `sim/p6e_pcie` 一族同时带
`-d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ` 并例化**真 wrapper**。

**逐字命令**（副本在我 scratch；canonical `sim/p6e_pcie/` 未写）：
```bash
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p5wu_p1p2_regress\p6e_pcie_ab\run_p6e_ab.bat'   # canon + bid9 两臂
post: cmd //c '…\p6e_pcie_ab\head\run_tb_p6e_pcie.bat'   # HEAD 源臂（files.f 过滤后追加 head_rtl 两份）
```

| 臂 | 编译源 | EXIT | FAIL 数 | FAIL 名单 |
|---|---|---|---|---|
| `canon` | 工作区 + **原版 TB**（期望 BID=7 / `0xEC`） | 1 | 2 | ①`BUILD_ID = 00000009 (期望 7)` ②`未实现地址 0xEC ⇒ rresp = SLVERR = 00000000 (期望 2)` |
| `bid9` | 工作区 + TB 期望改 `9`（**仅这一行**，我 scratch 的副本） | 1 | **1** | 只剩②：`0xEC ⇒ rresp = 0 (期望 2)` |
| `head` | **HEAD 的 `app_ctrl.v`+`wrapper_p4.v`** + 原版 TB | 1 | 2 | ①`BUILD_ID = 00000008 (期望 7)` ②**同一条 `0xEC` FAIL** |

**读数结论**：
* **`0xEC` 那条红在 HEAD 臂上照样红**（且 HEAD 臂读到的 BID 正是 HEAD 的 `8`，证明它真编的是 HEAD 源）
  ⇒ **既存红（BIZ 轮引入）**，**不是本轮新红**。
* `bid9` 臂 **其余全 PASS**：`MAGIC`/`MARKER`/`HW_STATUS.bit3`、W0..W34 的 force 值逐字对上、
  `ΔW24/ΔW5 = 5023/4018 = 1.2501 ∈ [1.24,1.26]`（数据面 156.25MHz）、`gen 恰好 +1`、
  "未触发时字冻结" —— **63 字装配在真 wrapper 里 elaborate 且行为正常**（无错位别名、无 X 传播）。
* ⚠️ **边界**：这个 TB 的判据只到 W34 + 两个守卫，**没有覆盖 W35..W62** ⇒ 它**不能**证明
  "W61/W62 接到 `app_ctrl.stat_wu`/`rx_occ_bytes` 正确"。那条链**至今只有静态证据**
  （`check_wu_words.py` 14 项 + `check_window.py` 42 项 + `xvlog` 解析面）——**没有仿真端到端读数**。见 §7。

---

## 7. ⚠️ 未测 / 未定位清单（**不许当成已答**）

| # | 项 | 状态 |
|---|---|---|
| ① | 作者自己跑过、**我没有复跑**的那些（其 `P7B_WU_P1P2_SNAP.md` §5 表共 10 行）：`sim/p5wu/run_tb_app_wu.bat` · `run_tb_wu_p1p2.bat` · `run_tb_snap63.bat` · `run_xvlog_wrapper63.bat` · `check_wu_words.py` / `check_window.py` · `p5sim` 的 `fc`/`app`/`flow` · `p5d_multi main` · `p5_adv multi` | **未复跑**（派单范围 = "作者未跑的门"）。⚠️ 其中 `p5d_multi main`（作者读数：122 checks / 0 FAIL）是 `app_ctrl` 的**正**档，建议下一轮至少复跑这一门 |
| ② | `sim/snapcdc` / `sim/snapseq` 门（`NW` 参数化位宽/时序门） | **未跑**——本轮改了 `SNAP_P7BDP_NW` 22→24 与 `SNAP_NW_P6E`，这两族是**改 `NW` 参数值**时最该跑的；作者声明"只改参数值、未动语义"，**我没有验证这句话** |
| ③ | **W61/W62 的接线端到端** | **只有静态证据**（见 §6 边界）。要闭环需要：一个带 `PCIE_OBS+APP_MODE` 的门**读 0x114/0x118 并对照 `app_ctrl.stat_wu`/`rx_occ_bytes`**（现有 TB 不读） |
| ④ | `p5_wrapper` 红的**根因** | **未定位**（只证明了"与本轮无关"）。症状：TB 的 APP_MODE 激励产不出帧、`resp_p5_wrapper.memh` 0 字节 |
| ⑤ | `neg_mgn` 两条计数差（555837→555949 / 557871→557983）与 `neg_mgn0` 的 `k` 差（2558285→2558157） | 相对 **09-30 基线**的差；判据结构不变。**归因未做**（要归因需把这两个档也做 HEAD 双臂；`neg_wq` 双臂一致 ⇒ 差应来自更早的 BIZ/首轮修复，但**我没有读数背书**） |
| ⑥ | 板侧脚本的几何元数据（§5.3） | `tcpreg_j6.sh:53` / `j6_fix.sh:58` 的 `NW=${NW:-61}` **09:36 仍是 61**（我按纪律未改任何既存脚本；属测量脚本轮的边界）；`final_state.sh` 已被并发轮修到 `0x11C` |
| ⑦ | 板级 / 位流 / 时序 | **零**（纪律：不烧板）。`BUILD_ID=9`、63 字窗口、`0x11C` 的板级读数**一个都没有** |
| ⑧ | `p6e_pcie` 门的 `0xEC`/`BID=7` 双硬编码 | 未修（越界）；下一次用它做验收前必须先处理，否则**必然红**（且是既存红，不是你引入的） |

---

## 8. 证据地图（全部在 `sim/p5wu_p1p2_regress/`）

| 文件 | 内容 |
|---|---|
| `matrix_stdout.log` | 矩阵 runner 的 stdout（逐门 `GATE x EXIT=n` + `MATRIX_BAT_EXITCODE=0`） |
| `matrix_p4dfix.log` | **矩阵日志原件副本**（含 before/after 指纹块 + `VERDICT: FROZEN`） |
| `P4_MATRIX_FINGERPRINT_20261007_084942_{before,after}.txt` | 两个 237 文件指纹 |
| `matrix_two_column.txt` | **两列提取**（A 列 per-gate 判据行 + B 列各门自己的 console/xsim 日志尾） |
| `gate_consoles/<gate>.console.log` ×16 | 16 门的 console 原件（我对其做过 `grep -i fail` = 0） |
| `extra_p5_wrapper.log` / `extra_p5_status.log` / `extra_p5_pattern.log` | 三个追加门读数 |
| `extra_p5d_{neg_wq,neg_mgn,neg_mgn0,known_idle_fifo}.log` | 四个 p5d 档读数 |
| `ab_wrapper_head.log` / `ab_neg_wq_head.log` / `ab_wrapper_head_iso.log` / `ab_neg_wq_head_iso.log` | **HEAD 双臂读数**（与工作区臂逐字比对过）；`*_iso` = 09:37/09:38 的**隔离重跑**（证明并跑期没有伪影） |
| `ab_p6e_{canon,bid9,head,head}.log` / `p6e_pcie_ab/` | p6e_pcie 三臂读数 + 三个编译目录 |
| `head_rtl/{app_ctrl.v,wrapper_p4.v}` | `git show 95c9485:` 导出的两个改动文件（`c8e00067…` / `10056819…`） |
| `mk_p5sim_ab.py` · `mk_head_ab.py` · `mk_p6e_head_arm.py` · `collect_matrix.py` | 生成/取数脚本（可复跑） |
| `run_matrix_here.bat` · `run_extra_gates.bat` · `run_ab_head.bat` · `run_tb_p5_*_here.bat` · `run_tb_p5_multi.bat` | 我 scratch 里的入口（原件 sha256 已在脚本输出里登记） |

---

## 9. 一句话交给 TL

**「16 门全绿」+「三个负对照档红得正确」+「4 个红的双跑归属全是既存」⇒ 本轮改动没有引入可观测的回归**
（在此覆盖面的边界内）；**但覆盖面本身有一格是空的**：16 门矩阵**不编译** `app_ctrl.v`/`wrapper_p4.v`（§4），
而"W61/W62 真接到 `stat_wu`/`rx_occ_bytes`"**至今没有仿真端到端读数**（§6 边界、§7-③）——
下一轮若要用 `ΔW61/ΔW62` 当判据，先补这一格，别把它当前提。
