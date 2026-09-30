# P7B_COMMIT_PLAN2 —— P7b 归档的提交方案（第二版）

> **本文件只是方案，没有任何 git 写操作被执行过。**
> 本会话全程只用只读命令：`git status` / `git log` / `git ls-files` / `git check-ignore` /
> `git cat-file` / `git diff --stat` / `git show`，外加**一次** `git add --dry-run --verbose`
> （只打印、不写索引；实测执行前后 `git ls-files | wc -l` 恒为 **1683**，见 §D）。
> 除本文件外**未修改任何既有文件**，**未删除任何东西**，未跑 Vivado / 未烧板子。
>
> 分层建议里出现的 `git add ...` / `git add -f ...` 全部是**给执行者的工单**，不是已执行的动作。

---

## §0 实测口径与总账

### 0.1 测量方法（可复核）

| 项 | 命令 |
|---|---|
| 未跟踪清单（**含被忽略判定**） | `git status --porcelain -uall \| grep '^??'` |
| 体积/文件数 | `du -sh <dir>` / `find <dir> -type f \| wc -l`（**含被忽略文件**，与任务书同口径）|
| "git 今天真会提交哪些" | `git status --porcelain -uall -- <path>`（权威；**不要**用 `check-ignore -v` 的退出码，见 §D.3）|
| 是否已跟踪 | `git ls-files --error-unmatch -- <path>` |
| 是否被忽略 | `git check-ignore -q -- <path>`（**`-q` 的退出码才可信**）|

⚠️ 有一处**参照系会漂**：`_proj_10g/xxv_gate2/` 正被另一路使用，本会话内它从
`429 KB / 28 文件`（任务书快照）→ `8.6 MB / 44`（23:00 首测）→ **`88 MB / 244`（23:03 复测）**。
**本文件对它只给一条建议：整体排除、不要碰、不要写任何针对它的规则去"顺便"放行别的东西。**
（`du` 对它是移动靶，任何写进规则的读数都会立刻过期。）

### 0.2 总账（2026-09-29 23:03 实测）

| 指标 | 实测 | 说明 |
|---|---|---|
| 未跟踪条目（`-uall`，含已忽略） | **963 → 970**（会话内增长） | 增长全部来自 `xxv_gate2/` |
| 其中 **git 今天会提交**的 | **n = 966，227.74 MB** | 这就是"不做任何事直接提交"的代价 |
| 修改的已跟踪文件 | **n = 107**，`534 insertions(+), 242 deletions(-)` | 80 个 `.bat` + 14 个 `.log` + 13 个其它 |
| **本方案建议入库** | **新增 n = 327，18.21 MB**（排除 2 个 `dfx_runtime.txt` 后） | = 227.74 MB 的 **8.0%** |
| 其中需 `git add -f` | **n = 31，约 0.60 MB** | 逐个点名见 §C.0 |
| 建议排除 | **n ≈ 639，约 209 MB** | 见 §A |

> 一句话：**未跟踪体积的 92% 是 6 棵生成工程/工作目录**（`xxv_mac` 139M、`pcs64_2ch` 149M、
> `mac_only` 15M、`baseline` 生成树 19M、`probe_*_work` ×4 = 101M、`xxv_gate2` 88M → 去重后落在这 6 棵里）。

---

## §A 逐目录处置建议 + `.gitignore` 规则草案

### A.0 规则"实测过"的证明方式（必读）

本工程有**案底**：`.gitignore:54` 曾写 `sim/retxsim*/`（**目录排除型**），`!` 否定行**永远救不回来**
（git 不下降进被排除的目录）。所以本节的每条规则都在一个**临时 scratch 仓**里跑过
`git check-ignore -q`（33 个代表路径，正反两面）。scratch 仓建在 `%TEMP%` 下，**不在本仓内**，
测完已 `rm -rf`。

⚠️ **两条在测试中真被踩到的坑**（写进规则时务必照抄顺序）：

1. **否定行必须排在它想覆盖的排除行之后**（gitignore 是"最后匹配者胜"）。
   我第一版把 `!_proj_10g/p7b_mac_synth/baseline/xxv_loop_top_drc_routed.rpt` 写在了
   `_proj_10g/p7b_mac_synth/baseline/` **之前** ⇒ 实测该文件 `rc=0`（**被忽略，放行失败**）。
   改成"先排目录、再排内容、再逐类放行"后 `rc=1`。
2. **要放行子目录里的文件，必须先放行子目录本身，再重新排除其内容**：
   ```
   !_proj_10g/p7b_mac_synth/logs/
   _proj_10g/p7b_mac_synth/logs/*
   !_proj_10g/p7b_mac_synth/logs/gate/
   _proj_10g/p7b_mac_synth/logs/gate/*
   !_proj_10g/p7b_mac_synth/logs/gate/*.log
   ```
   （与既有 `p5diag_verify` 那段的做法同构，`.gitignore:213-220` 已有先例与注释。）

### A.1 逐行处置表

| # | 路径 | 实测体积/文件数 | 处置 | 白名单（明确到扩展名/子目录） | 依据 |
|---|---|---|---|---|---|
| 1 | `_proj_10g/notes/P7B_*.md` ×8 | **345,503 B / 8** | **保留（全部）** | 8 个文件名逐个点（§C.L5） | 任务书列的新笔记；被 `CLAUDE.md` / `P7A_COMMIT_PLAN.md` / `PORT_NOTES.md` 等引用 |
| 2 | `_proj_10g/notes/p7b_implicit_repro/` | 831 KB / 103 | **部分保留** | 顶层 `*.v` `*.py` `*.bat` `*.tcl` `*.txt` = **27 个 / 0.43 MB**；排除 5 个 xsim 产物子目录（`A1_portconn/` `A2_expr/` `B1_clean/` `C1_benign/` `W1_widthmis/` = 315 KB） | `P7B_IMPLICIT_GATE_FIX.md` 逐字引用 `apply_log.txt` / `docs_apply_log.txt` / `fs_semantics.bat` / `verify_integrity.py` |
| 3 | `_proj_10g/notes/p7b_rollout/` | **101 MB / 811** | **部分保留** | 顶层 `*.py`（19）`*.bat`（5）+ `logs/`（165 KB）= **38 个 / 0.19 MB**；排除 `probe_work/`(6.7M) `probe2_work/`(24M) `probe_p7a_work/`(32M) `probe_cfg_work/`(40M) = **101 MB** | 4 个 work 目录是语料扫描的仿真工作区（可重建：`corpus_scan*.py` / `probe_*.bat` 全在白名单里）；`logs/*.txt` 是 `P7B_IMPLICIT_GATE_ROLLOUT.md` 引用的读数 |
| 4 | `_proj_10g/notes/p7b_tail/` | 325 KB / 32 | **保留（全部）** | 32 个全留（`*.txt` 23 + `*.bat` 4 + `*.ORIG` 2 + `*.FIXED` 1 + `*.PREFIX` 1 + `logs/*.log` 1） | `CLAUDE.md` 尾段把 `_proj_10g/notes/p7b_tail/logs/` 写成**取证目录**（16 门矩阵回归 / 负对照退出码）。⚠️ 其中 `matrix_p4dfix.HISTORICAL_20260929_2203.log`（14,752 B）被全局 `*.log` 挡住 ⇒ 需放行或 `-f` |
| 5 | `_proj_10g/p7b_mac/` | 2.6 MB / 64 | **部分保留** | `rtl/`(4) `scripts/`(2) `sim/tb_mac_10g.v` `sim/run_tb_mac_10g.bat` `sim/_mut_logs/*`(13) = **21 个 / 0.31 MB**；**排除** `sim/_mut_rtl/`(4)、`sim/xsim.dir/`(1.5 MB)、`sim/*.log` 非留档者 | `_mut_rtl/` 与 `rtl/` **逐字节相同**（md5 `a9f7aee1…` 实测同值）⇒ 与既有 `_mutbak/` 同性质（"同名 RTL 出现两份"），排除无损；`_mut_logs/` 被 `P7B_MAC_GATEFIX.md` **逐字引用**（`00_clean.log` / `07_M7.log` / `08_M7b.log` / `11_M10.log` …） |
| 6 | `_proj_10g/p7b_mac_synth/` | **183 MB / 539** | **部分保留** | `tcl/`(15) `rtl/`(7) `xdc/`(?) `reports/*.rpt`(31) `logs/`(18，含 `logs/gate/` 8 个 `.log`) `baseline/*.rpt`(4，**需 -f**) = **77 个 / 14.31 MB**；排除 `xxv_mac/`(**139M**) `mac_only/`(**15M**) `baseline/` 的生成树（**19M**，仅放行 4 个 `.rpt`）`dfx_runtime.txt` | `P7B_MAC_TIMING.md` / `P7B_MAC_REVIEW.md` 引用其中 **14/32 份报告**（逐个实测见 §C.L3）；`baseline/xxv_loop_top_*` 4 份被 `P7B_MAC_TIMING.md` / `P7B_RXCLASSIFY_DESIGN.md` 引用 |
| 7 | `_proj_10g/p7b_rxcls/` | 2.2 MB / 156 | **部分保留** | `rtl/`(1) `scripts/`(1) `sim/*.v`(2) `sim/*.bat`(2) `sim/legacy/*.v`(1) `sim/legacy_mut/*.v`(1) `sim/_mut_logs/*`(11) = **19 个 / 0.26 MB**；**排除** `sim/_mut_rtl/`(12 KB，与 `rtl/` md5 同值 `67a1fcea…`)、`xsim.dir/`、`*.memh`、`*.log` 非留档者 | `P7B_RXCLASSIFY_DESIGN.md` 引用 `rtl/rx_classify_v2.v` / `tb_rxcls_v2.v` / `rx_classify_ref.v` / `run_*.bat` / `_mut_logs/06_M8_routeq_ptr.{log,src.v}` |
| 8 | `_proj_10g/xxv_loop/` | **157 MB / 454** | **部分保留** | `rtl/`(12) `tcl/`(16) `xdc/`(2) `artifacts/`(8) `logs/*.txt`(32) `sim/*.v`+`run_*.bat`(3) `patch*.py`+`mkbat.py`+`notes_appendix_r2.md`(5) = **85 个 / 1.21 MB**；排除 `pcs64_2ch/`(**149M** 生成工程) 与 `logs/*.log`(Vivado journal) | `P7B_GATE1.md` 的证据地图（§引用核查）几乎整表指向 `logs/*_stdout.txt` / `artifacts/` / `rtl/` / `tcl/` |
| 9 | `_proj_10g/xxv_gate2/` | **88 MB / 244（在涨）** | **排除（整体）** | 无 | **闸2 正在另一路手里跑**；任务书明令"先别动"。只写一条 `_proj_10g/xxv_gate2/`（目录型，不留任何 `!`），并在注释里写清"在役" |
| 10 | `sim/p4gates/implicit_gate*.bat` + `evidence/implicit_gate_2026-09-29/` | 132 KB / 15 | **保留（全部）** | `implicit_gate.bat` `implicit_gate_selftest.bat` + evidence 目录 13 个文件 | ⭐ **新的规范检测器**（九项自检）；`CLAUDE.md` / `P7A_COMMIT_PLAN.md` / `PORT_NOTES.md` / `P6B_INTEGRATION_REVIEW.md` 四处引用 |
| 11 | `sim/p4sim/P4_MATRIX_FINGERPRINT_2026*.txt` | 480 KB / **12 未跟踪** + 37 已跟踪 | **保留（12 个未跟踪者）** | `sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt`（既有 `!` 放行已覆盖，无需新规则） | 矩阵修订指纹 before/after；`.gitignore` 已有 `!sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt` |
| 12 | `sim/retxsim2/` | **7.8 MB / 61** | **部分保留：只留 1 个** | `sim/retxsim2/run_tb_frame_fifo.bat`（1,662 B） | 见 §D（实测：61 个文件里**只有这 1 个**会被提交） |
| 13 | `audit_scratch/**/*.backup.log` | **485 KB / 7** | **排除** | — | ⚠️ **现行规则的意外副作用**：`.gitignore:380` 的 `!audit_scratch/**/*.log` 把 xsim 的**轮转备份**也放行了（`ignored_rc=1` 实测）。它们与既有 `sim/**/*.backup.log`（`.gitignore:292`，明确排除）**同性质** ⇒ 补一条规则 |
| 14 | `_proj_10g/tcl/lint/xelab.txt` | 4 KB / 1 | **保留** | 该文件 | `P7B_IMPLICIT_GATE_ROLLOUT.md:445` 引用（"干净的真实设计上 `xelab.txt` 1 条"） |
| 15 | `_tmp_*.py` | 64 KB / 11 | **排除（一贯不入库）** | — | 与既有口径一致 |

### A.2 `.gitignore` 规则草案（**已实测通过**，可直接追加到文件末尾）

```gitignore
# ============================================================================
# P7b (2026-09-29): 新 MAC / rx_classify v2 / 闸1 2 通道 PCS 工程 / 隐式网检测器
#
# 实测体积: 本轮未跟踪条目 970 个 / 227.74 MB 里, **209 MB 是 6 棵生成工程或工作目录**
#   (p7b_mac_synth/xxv_mac 139M · xxv_loop/pcs64_2ch 149M · p7b_mac_synth/mac_only 15M ·
#    p7b_mac_synth/baseline 生成树 19M · notes/p7b_rollout/probe_*_work ×4 = 101M ·
#    xxv_gate2 88M) —— 全部可重建(各自的 tcl/py 驱动脚本都在白名单里)。
# **入库的 ≈ 18.2 MB**(327 个新增 + 107 个修改), 按本工程一贯口径:
#   "设计 + 门 + 全部**被文档逐字引用**的文本读数" 入库, 位流/抓包/工程/网表不入库。
#
# ⚠️ 顺序纪律(实测踩过): gitignore = 最后匹配者胜 ⇒ `!` 行必须排在它要覆盖的排除行**之后**;
#    要放行子目录内的文件, 必须先放行**子目录本身**, 再重新排除其内容, 再逐类放行。
# ============================================================================

# ---- 新 MAC 的仿真工作目录 (只留 TB/驱动/逐变异留档日志) --------------------
#      证据 (需 -f, 见文件末尾强制入库说明): sim/_mut_logs/*.log = 逐变异 xsim 读数,
#      P7B_MAC_GATEFIX.md 逐字引用 (00_clean / 07_M7 / 08_M7b / 11_M10 …)。
#      sim/_mut_rtl/ = 变异脚本改的**副本**, 与 rtl/ 逐字节相同 (md5 实测同值) ⇒ 排除无损。
_proj_10g/p7b_mac/sim/_mut_rtl/
_proj_10g/p7b_mac/sim/xsim.dir/
_proj_10g/p7b_mac/sim/xsim_m10g*.log
_proj_10g/p7b_mac/sim/xvlog*.log
_proj_10g/p7b_mac/sim/xelab*.log

# ---- rx_classify v2 的仿真工作目录 ------------------------------------------
_proj_10g/p7b_rxcls/sim/_mut_rtl/
_proj_10g/p7b_rxcls/sim/xsim.dir/
_proj_10g/p7b_rxcls/sim/*/xsim.dir/
_proj_10g/p7b_rxcls/sim/xsim_rxcls*.log
_proj_10g/p7b_rxcls/sim/xvlog*.log
_proj_10g/p7b_rxcls/sim/xelab*.log
_proj_10g/p7b_rxcls/sim/legacy/xsim_legacy*.log
_proj_10g/p7b_rxcls/sim/legacy_mut/xsim_legacy*.log
_proj_10g/p7b_rxcls/sim/*/*.memh

# ---- MAC 综合/实现 (183 MB → 14.3 MB): 排除 3 棵生成树, 保留全部报告与读数 ----
_proj_10g/p7b_mac_synth/xxv_mac/
_proj_10g/p7b_mac_synth/mac_only/
_proj_10g/p7b_mac_synth/dfx_runtime.txt
#    baseline/ 是闸1 工程的一份 routed 快照(19 MB, 可重建); 只有 4 份 .rpt 被
#    P7B_MAC_TIMING.md / P7B_RXCLASSIFY_DESIGN.md 引用 ⇒ 按 p5diag_verify 的先例
#    "先放行子目录、再排内容、再逐类放行"。
!_proj_10g/p7b_mac_synth/baseline/
_proj_10g/p7b_mac_synth/baseline/*
!_proj_10g/p7b_mac_synth/baseline/*.rpt

# ---- 闸1 的两通道 PCS 工程 (157 MB → 1.2 MB): 只排 pcs64_2ch 生成树 ----------
_proj_10g/xxv_loop/pcs64_2ch/
_proj_10g/xxv_loop/tcl/dfx_runtime.txt
#    logs/ 下被引用的是 *_stdout.txt / *_FINAL.txt (明文读数); *.log 是 Vivado journal
_proj_10g/xxv_loop/logs/*.log
_proj_10g/xxv_loop/sim/xsim.dir/
_proj_10g/xxv_loop/sim/*.log
_proj_10g/xxv_loop/sim/*.jou
_proj_10g/xxv_loop/sim/*.pb
_proj_10g/xxv_loop/sim/*.wdb

# ---- 铺开/复现/尾巴三份笔记目录: 只排工作区, 文本全留 ------------------------
_proj_10g/notes/p7b_rollout/probe_work/
_proj_10g/notes/p7b_rollout/probe2_work/
_proj_10g/notes/p7b_rollout/probe_p7a_work/
_proj_10g/notes/p7b_rollout/probe_cfg_work/
#    隐式网最小复现: 5 个子目录是每次 xvlog/xelab 的产物, 顶层脚本/源码/读数留
_proj_10g/notes/p7b_implicit_repro/*/

# ---- ⚠️ 闸2: **在役** (2026-09-29 23:03 实测 88 MB / 244 文件, 且正在增长)。
#      任务书明令先别动 ⇒ 整目录排除, **不留任何 ! 行**; 等它收工后另行归档。 ----
_proj_10g/xxv_gate2/

# ---- audit_scratch 的 xsim 轮转备份 (产物) ----------------------------------
#      既有 `!audit_scratch/**/*.log` (为本工程"归档级原始日志"而写) 把 *.backup.log
#      一并放行了 —— 实测 7 个 / 485 KB。与既有 sim/**/*.backup.log 同性质, 补挡。
audit_scratch/**/*.backup.log

# ---- ⭐ 放行 4 个被文档点名的**驱动脚本** --------------------------------------
#      `sim/p4sim/run_matrix_p4dfix.sh` 是 16 门矩阵的**现役 sh 入口**, 被
#      CLAUDE.md:135 / README.md 「怎么跑 · 门矩阵」节 (README 2026-09-30 重写前 :287,308) / PORT_NOTES.md:1649,2699 /
#      P6B_INTEGRATION_REVIEW.md:17 引用, 但从未入库 (git log 为空) ——
#      被 `.gitignore:40 sim/p4sim/*` 挡住。本仓已跟踪 34 个 *.sh, 且 .gitattributes
#      专门为 *.sh 写了 `text eol=lf` ⇒ 显然是要跟踪的, 这是**规则漏网不是设计**。
!sim/p4sim/run_matrix_p4dfix.sh
!sim/p4sim/p6logs/
sim/p4sim/p6logs/*
!sim/p4sim/p6logs/*/
sim/p4sim/p6logs/*/*
!sim/p4sim/p6logs/*/*.sh
```

---

## §B ⭐ 引用核查（本任务的核心）

### B.0 方法

对 **8 份新笔记** + **11 份被改文档**（`CLAUDE.md` `P6B_SUMMARY.md` `P6B_ACCEPT.md`
`P6B_CDC_AUDIT.md` `P6B_INTEGRATION_REVIEW.md` `P6B_SPEC.md` `P6E_OBS.md`
`P7A_COMMIT_PLAN.md` `P7B_SPEC.md` `PORT_NOTES.md` `README.md`）做**机械化路径抽取**
（正则 + 多根解析：仓根 / `_proj_10g/` / 笔记同级 / `xxv_loop/` / `p7b_mac/` / `p7b_rxcls/` /
`p7b_mac_synth/` / `p4gates/` / `board/`），再对每个命中做
"存在？→ 已跟踪？→ git 今天会不会提交？" 三问。

- 解析出**存在的路径引用 588 条**（去重后）
- 其中 **被引用但未跟踪 = 164 条**：
  - **109 条 = 未跟踪且未被忽略**（真正的"漏网"，`git add` 即可入库）
  - **55 条 = 未跟踪且被某条规则挡住**（需 `-f` 或改规则，或接受引用降级）

### B.1 ⚠️ 最要紧的发现：**8 棵树 100% 未跟踪 ⇒ 引用成片悬空**

| 目录 | 体积/文件数 | 已跟踪文件数（实测） | 引用它的文档 |
|---|---|---|---|
| `_proj_10g/p7b_mac/` | 2.6 MB / 64 | **0** | P7B_MAC_DESIGN / GATEFIX / TIMING / REVIEW |
| `_proj_10g/p7b_mac_synth/` | 183 MB / 539 | **0** | P7B_MAC_GATEFIX / REVIEW / TIMING / RXCLASSIFY_DESIGN |
| `_proj_10g/p7b_rxcls/` | 2.2 MB / 156 | **0** | P7B_RXCLASSIFY_DESIGN |
| `_proj_10g/xxv_loop/` | 157 MB / 454 | **0** | P7B_GATE1 / IMPLICIT_GATE_FIX / MAC_TIMING |
| `_proj_10g/notes/p7b_implicit_repro/` | 831 KB / 103 | **0** | P7B_IMPLICIT_GATE_FIX |
| `_proj_10g/notes/p7b_rollout/` | 101 MB / 811 | **0** | P7B_IMPLICIT_GATE_ROLLOUT |
| `_proj_10g/notes/p7b_tail/` | 325 KB / 32 | **0** | CLAUDE.md |
| `_proj_10g/xxv_gate2/` | 88 MB / 244 | **0** | （P7B_SPEC 提过闸2；本方案不动） |

⇒ **P7b 这一轮的笔记是"悬空引用"的**：所有 8 份笔记的证据栏都指向从未入库的树。
这不是几条漏网，而是**成片悬空**。§C 的分层就是按"把该在库里的拉回库里"组织的。

### B.2 "必须保留"清单（引用者 → 被引用 → 当前状态 → 建议）

> 只列**真正会把引用拉回库里**的项。"已被某规则挡住"的另见 §B.3。

#### B.2.1 新 RTL / 门源码（未跟踪 · 未被忽略 ⇒ `git add` 即可）

| 引用者 | 被引用 | 已跟踪? | 建议 |
|---|---|---|---|
| P7B_MAC_DESIGN / TIMING / GATEFIX | `_proj_10g/p7b_mac/rtl/{mac_tx_10g.v,mac_rx_10g.v,crc32_64.v,mac_10g_defs.vh}` | ✗ | **入库** |
| P7B_MAC_DESIGN / GATEFIX | `_proj_10g/p7b_mac/scripts/{gen_crc32_64.py,mutate_gate.py}` | ✗ | **入库** |
| P7B_MAC_DESIGN / GATEFIX | `_proj_10g/p7b_mac/sim/{tb_mac_10g.v,run_tb_mac_10g.bat}` | ✗ | **入库** |
| P7B_RXCLASSIFY_DESIGN | `_proj_10g/p7b_rxcls/rtl/rx_classify_v2.v` | ✗ | **入库** |
| P7B_RXCLASSIFY_DESIGN | `_proj_10g/p7b_rxcls/scripts/mutate_rxcls.py` | ✗ | **入库** |
| P7B_RXCLASSIFY_DESIGN | `_proj_10g/p7b_rxcls/sim/{tb_rxcls_v2.v,rx_classify_ref.v,run_tb_rxcls_v2.bat,run_legacy_tb_rxclass.bat}` | ✗ | **入库** |
| P7B_RXCLASSIFY_DESIGN | `_proj_10g/p7b_rxcls/sim/legacy_mut/rx_classify.v` | ✗ | **入库** |
| P7B_GATE1 | `_proj_10g/xxv_loop/rtl/{xxv_loop_top.v,xgmii_rx_chk.v,pcs64_pkt_gen_mon_ds.v}` | ✗ | **入库** |
| P7B_GATE1 | `_proj_10g/xxv_loop/xdc/{xxv_loop.xdc,xxv_loop_impl.xdc}` | ✗ | **入库** |
| P7B_GATE1 (证据地图) | `_proj_10g/xxv_loop/tcl/` 8 个 tcl/bat（`s1_prepare` `s2_build` `s3_probe` `s6_stat_cells` `s7_probe2` `s8_rst_clk` `s10_misc_query` `run_s3.bat`） | ✗ | **入库**（可重跑） |
| P7B_GATE1 | `_proj_10g/xxv_loop/artifacts/` 8 个（`pcs64_2ch.veo` `pcs64_ooc.xdc` `pcs64_top.xdc` `ip_{0,1}_pcs64_gt*.{xci,xdc}` `SHA256SUMS.txt`） | ✗ | **入库**（`artifacts/SHA256SUMS.txt` 是 sha256 的出处） |
| P7B_GATE1 | `_proj_10g/xxv_loop/sim/{tb_pay_sel.v,run_sim_pay.bat}` | ✗ | **入库** |
| P7B_IMPLICIT_GATE_FIX / ROLLOUT | `sim/p4gates/implicit_gate.bat` `implicit_gate_selftest.bat` + `evidence/implicit_gate_2026-09-29/`（13） | ✗ | **入库**（检测器本体） |
| P7B_IMPLICIT_GATE_FIX | `_proj_10g/notes/p7b_implicit_repro/{A1_portconn.v,apply_log.txt,docs_apply_log.txt,fs_semantics.bat,verify_integrity.py}` | ✗ | **入库** |
| P7B_IMPLICIT_GATE_ROLLOUT | `_proj_10g/notes/p7b_rollout/{corpus_scan2.py,ctrl_3091.bat,final_scan.py,fix_p6e_xelab.py,narrow_3091.py}` + `logs/{classify_3091,corpus_scan2,final_scan,fix_docs2_log,lint_after,lint_def_after,narrow_3091_log,p4matrix_clean,p4matrix_rollout,run_lint_p6e_after,run_lint_p7a_after}.txt` | ✗ | **入库** |
| CLAUDE.md（尾段取证栏） | `_proj_10g/notes/p7b_tail/logs/`（23 txt + 1 log） | ✗ | **入库**（1 个 `.log` 需放行/`-f`） |
| P7B_IMPLICIT_GATE_ROLLOUT | `_proj_10g/tcl/lint/xelab.txt` | ✗ | **入库** |
| **CLAUDE.md:135 / README.md 「怎么跑 · 门矩阵」节（2026-09-30 重写前 :287,308） / PORT_NOTES.md:1649,2699 / P6B_INTEGRATION_REVIEW.md:17** | ⭐ `sim/p4sim/run_matrix_p4dfix.sh` | ✗ **且从未提交过** | **入库**（改规则放行，见 §A.2 末段）。**这是全套引用里最要紧的一条：它是驱动脚本，不是证据** |
| PORT_NOTES.md | `sim/p4sim/p6logs/indep/run_matrix.sh`、`p6logs/indep4c/run_matrix4c.sh` | ✗ | **入库**（同上） |

#### B.2.2 报告/读数（未跟踪 · 未被忽略）

| 引用者 | 被引用 | 建议 |
|---|---|---|
| P7B_MAC_TIMING / REVIEW | `_proj_10g/p7b_mac_synth/reports/` **14/32 份**（`A_Base_{timing_summary_routed,utilization_placed,drc_routed}.rpt`、`B_WithMac_{timing_summary_routed,util_hier_routed,utilization_placed,drc_routed}.rpt`、`mac_rx_ooc_{setup_paths,util_hier_routed}.rpt`、`mac_tx_ooc_{drc,hold_paths,setup_paths,timing_summary,util_hier_routed}.rpt`） | **全 32 份入库**（其余 18 份同批同性质，9.15 MB；不逐份裁剪的理由：它们是同一轮 A/B 对照的完整读数面） |
| P7B_MAC_TIMING | `_proj_10g/p7b_mac_synth/logs/{analyze_ooc_stdout,mac_only_stdout,mac_only_stdout_attempt2_TOPFAIL,vd4_stdout,verify_domains_stdout,xxv_mac_stdout,xxv_mac_stdout_run1_WITH_MY_IMPLICIT_NET}.txt` | **入库**（全 18 个 logs 文件） |
| P7B_MAC_TIMING / REVIEW | `_proj_10g/p7b_mac_synth/logs/gate/{CMB,CMB2}_{impl,synth}.log`、`{mac_rx_ooc,mac_tx_ooc}.runs_{impl_1,synth_1}.log` | **入库**（需 `-f`，被全局 `*.log` 挡） |
| P7B_MAC_TIMING | `_proj_10g/p7b_mac_synth/tcl/{analyze_ooc.tcl,make_xxv_mac_top.py,run_mac_only.tcl,verify_domains.tcl}` | **入库** |
| P7B_MAC_TIMING | `_proj_10g/p7b_mac_synth/baseline/xxv_loop_top_drc_routed.rpt` | **入库**（需 `-f`：在整目录排除的 `baseline/` 里） |
| P7B_RXCLASSIFY_DESIGN | `_proj_10g/p7b_mac_synth/baseline/xxv_loop_top_timing_summary_routed.rpt` | **入库**（需 `-f`） |
| P7B_GATE1 | `_proj_10g/xxv_loop/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt:151-154,163-172` | ⚠️ **决策点，见 §B.4** |
| P7B_GATE1 | `_proj_10g/xxv_loop/logs/` 9 份（`s1_prepare_stdout` `s2_build_stdout` `s2_build_FINAL` `s2d_run_output` `s3_probe_FINAL` `s7_probe2_FINAL` `s8_rst_stdout` `s10_misc_stdout` `s11_probe3_FINAL`） | **入库**（白名单 `logs/*.txt` 覆盖 32 份） |

#### B.2.3 被引用且被忽略 ⇒ 需 `-f` 或改规则（**14 类 / 55 条**）

| 被引用 | 挡住它的规则（实测 `check-ignore -v`） | 建议 |
|---|---|---|
| `sim/p4sim/run_matrix_p4dfix.sh` + `p6logs/{indep,indep4c}/run_matrix*.sh` | `.gitignore:40 sim/p4sim/*` | **改规则放行**（§A.2） |
| `sim/snapcdc/review24/{axr,cdc,lint,p6e,p6e_mut,p6e_mut2}/run.bat` | `.gitignore:302 sim/snapcdc/review24/` | **保持排除**（笔记已自知：§5.5 写明"属预期"）。**但引用会悬空** ⇒ 见 §E 替代方案 |
| `board/lint_p6e/{xvlog,xelab}_p6e.log` | `.gitignore:294 board/lint_p6e/` | **建议 `-f` 入库**（2 个文件 / 约 60 KB）。它们是 `P7B_IMPLICIT_GATE_ROLLOUT.md:326,445` 的"真实生产日志"负对照读数（`xelab` 20 条假阳性的唯一出处）⇒ 便宜且必要 |
| `_proj_10g/p7b_mac/sim/_mut_logs/*.log`（13） | `.gitignore:35 *.log` | **`-f`**（P7B_MAC_GATEFIX 逐字引用） |
| `_proj_10g/p7b_rxcls/sim/_mut_logs/*.log`（9） | `.gitignore:35 *.log` | **`-f`** |
| `_proj_10g/p7b_mac_synth/logs/gate/*.log`（8） | `.gitignore:35 *.log` | **`-f`** |
| `_proj_10g/notes/p7b_tail/logs/matrix_p4dfix.HISTORICAL_20260929_2203.log` | `.gitignore:35 *.log` | **`-f`**（或加一行放行） |
| `_proj_10g/p7b_mac/sim/{xsim_m10g.log,xelab_m10g.log,xvlog_m10g.log}` | `.gitignore:35 *.log` | 建议**排除**（`_mut_logs/` 才是留档面；`P7B_MAC_GATEFIX.md:362` 自己写明"bat 每轮覆盖 `xsim_m10g.log` ⇒ 不留档就没有逐条证据"，留档就是 `_mut_logs/`） |
| `_proj_10g/p7b_rxcls/sim/xsim_rxcls.log` | `.gitignore:35 *.log` | 同上，建议**排除** |
| `sim/{vlansim,p6b_lint,f4sim,p5e_t2,p4sim}/*.log`（8 条） | `.gitignore:286 sim/**/*.log` | **保持排除**。它们是 `P7B_IMPLICIT_GATE_FIX.md` / `P6B_INTEGRATION_REVIEW.md` / `PORT_NOTES.md` 的**中间过程日志**，同目录的 `*.txt` 判据文件才是归档面 ⇒ 见 §E |
| `sim/p4gates/work_*/unit_uart/{_gate_console,xsim_uart}.log` | `.gitignore:306 sim/p4gates/work_*/` | **保持排除**（工作区，重跑即得） |
| `hls/slowstack_prj/solution1/{solution1.log,syn/verilog/udp_echo.v}` | `.gitignore:95 hls/slowstack_prj/` | **保持排除**。`udp_echo.v` 被 `P7B_IMPLICIT_GATE_ROLLOUT.md:216-217` 引用为**同名冲突的一方**（449,177 B）—— 它是 `run_hls.bat` 的产物，可重建 ⇒ 见 §E |
| `_p7a_probe/{nl_pos.v,nl_raw.v,pj_fin,rb_pos,rb_raw}` | `_p7a_probe/*`（P7a 段） | 保持排除（P7A_COMMIT_PLAN.md 自己已写"不进 git"的改判；读数在 `reports/`） |
| `vivado_prj/**/*.bit`、`p6b_accept_final/frozen_p6b_final.bit`、`_proj_pcie/smoke_scratch/p6b_smoke.bit`、`p6b_accept_final/host_p6b_final_pat.pcap`、`tools/cpp_peer/peer.exe` | `*.bit` / `*.pcap` / `tools/cpp_peer/*.exe` | **保持排除（既定策略）**：位流/抓包/可执行不入库，身份以 sha256/md5 记在报告里（P7A 已有先例）。`peer.exe` 的源码 `peer.cpp`/`udpsend.cpp` 已跟踪 ⇒ 可重建 |

### B.3 逐字引用密度（说明"为什么这些读数必须留"）

`P7B_GATE1.md` 的 §证据地图（第 635–644 行）是**逐行号引用**：
`pcs64_2ch.veo:58-157`、`logs/s1_prepare_stdout.txt:128,138,140,142,144,282`、
`logs/s2_build_FINAL.txt:163,1714,1726,1791,1793,1806,1808,1847,1848,1853`、
`logs/s3_probe_FINAL.txt:28,38,85,248,250,254,256,277,281,303,316,326-343,361,369,377,378,389-403,413-456,502-524,539-557`
⇒ 这些文件**必须真的在库里**，否则整张证据地图不可复核。
`P7B_MAC_GATEFIX.md` 引用 `_mut_logs/08_M7b.log` 时写明"**逐字引用**"（第 108 行）。

### B.4 ⚠️ 决策点：三份 `timing_summary_routed.rpt` 的等价性（实测 md5）

| 文件 | 体积 | md5 |
|---|---|---|
| `_proj_10g/p7b_mac_synth/reports/A_Base_timing_summary_routed.rpt` | 3,658,319 | `c1427343ed96f7e15a55a120a2ccac8d` |
| `_proj_10g/p7b_mac_synth/baseline/xxv_loop_top_timing_summary_routed.rpt` | 3,658,319 | `96bb6436659efbdab95d6d5b103e48cf` |
| `_proj_10g/xxv_loop/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt` | 3,658,319 | `96bb6436659efbdab95d6d5b103e48cf` |

⇒ 后两份**逐字节相同**（闸1 的 routed 时序），第一份是**另一轮**的读数（同名同大小但 md5 不同）。
- `P7B_GATE1.md` 引用的是**第三份的路径**（在 `pcs64_2ch/` 生成树里，该树整体要排除）；
- `P7B_RXCLASSIFY_DESIGN.md` 引用的是**第二份**。

**两个选项（请 TL 定）**：
- **①（推荐）** 两份都 `git add -f`（+7.3 MB）⇒ 引用逐字不悬空，与本工程"报告引用的东西必须真的在库里"的口径一致。
- **②** 只 `-f` 第二份（`baseline/`，不在生成树里，更"干净"），并在**提交说明**里写明
  "`baseline/xxv_loop_top_timing_summary_routed.rpt` 与 `pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt`
  逐字节相同（md5 `96bb6436659efbdab95d6d5b103e48cf`）"
  ⇒ 省 3.7 MB，但 `P7B_GATE1.md` 里的**路径字符串**仍然指不到实体。

---

## §C 分层提交计划

**绝不 `git add -A`。** 每层都用**显式路径**；需要 `-f` 的**逐个点名**。
（`git add` 对已忽略文件用 `-f`；对本方案已加放行规则的，普通 `git add` 即可。）

### C.0 强制入库清单（`git add -f`，31 项，约 0.60 MB）

> 这 31 项是"被 `*.log` 挡住但被笔记逐字引用"的读数。**逐个点名，不用通配**：

```
# 新 MAC 的逐变异 xsim 留档 (13)
_proj_10g/p7b_mac/sim/_mut_logs/00_clean.log      _proj_10g/p7b_mac/sim/_mut_logs/00_M1.log
_proj_10g/p7b_mac/sim/_mut_logs/01_M1b.log        _proj_10g/p7b_mac/sim/_mut_logs/02_M2.log
_proj_10g/p7b_mac/sim/_mut_logs/03_M3.log         _proj_10g/p7b_mac/sim/_mut_logs/04_M4.log
_proj_10g/p7b_mac/sim/_mut_logs/05_M5.log         _proj_10g/p7b_mac/sim/_mut_logs/06_M6.log
_proj_10g/p7b_mac/sim/_mut_logs/07_M7.log         _proj_10g/p7b_mac/sim/_mut_logs/08_M7b.log
_proj_10g/p7b_mac/sim/_mut_logs/09_M8.log         _proj_10g/p7b_mac/sim/_mut_logs/10_M9.log
_proj_10g/p7b_mac/sim/_mut_logs/11_M10.log
# rx_classify v2 的逐变异 xsim 留档 (9)
_proj_10g/p7b_rxcls/sim/_mut_logs/00_clean.log    _proj_10g/p7b_rxcls/sim/_mut_logs/00_M1.log
_proj_10g/p7b_rxcls/sim/_mut_logs/01_M2.log       _proj_10g/p7b_rxcls/sim/_mut_logs/02_M3.log
_proj_10g/p7b_rxcls/sim/_mut_logs/03_M4.log       _proj_10g/p7b_rxcls/sim/_mut_logs/04_M5.log
_proj_10g/p7b_rxcls/sim/_mut_logs/05_M6.log       _proj_10g/p7b_rxcls/sim/_mut_logs/06_M7.log
_proj_10g/p7b_rxcls/sim/_mut_logs/06_M8_routeq_ptr.log
# MAC 综合的"门"日志 (8)
_proj_10g/p7b_mac_synth/logs/gate/CMB_impl.log        _proj_10g/p7b_mac_synth/logs/gate/CMB_synth.log
_proj_10g/p7b_mac_synth/logs/gate/CMB2_impl.log       _proj_10g/p7b_mac_synth/logs/gate/CMB2_synth.log
_proj_10g/p7b_mac_synth/logs/gate/mac_rx_ooc.runs_impl_1.log
_proj_10g/p7b_mac_synth/logs/gate/mac_rx_ooc.runs_synth_1.log
_proj_10g/p7b_mac_synth/logs/gate/mac_tx_ooc.runs_impl_1.log
_proj_10g/p7b_mac_synth/logs/gate/mac_tx_ooc.runs_synth_1.log
# 尾巴轮的 16 门矩阵回归留档 (1)
_proj_10g/notes/p7b_tail/logs/matrix_p4dfix.HISTORICAL_20260929_2203.log
```

### C.L1 —— 检测器 + 门修复铺开 + `.gitignore`

**主题**：`P7b 门修复铺开 + 隐式网规范检测器: xelab 面判据入库, 现役 unit_fifo 门放行`

| 类 | 文件数 | 体积 |
|---|---|---|
| 新增 | **17** | 0.12 MB |
| 修改（已跟踪） | **84** | 0.38 MB |

- 新增（显式）：`sim/p4gates/implicit_gate.bat`、`sim/p4gates/implicit_gate_selftest.bat`、
  `sim/p4gates/evidence/implicit_gate_2026-09-29/` 下 13 个文件、
  `sim/retxsim2/run_tb_frame_fifo.bat`、`_proj_10g/tcl/lint/xelab.txt`
- 修改（`git add` 逐个，**80 个 `.bat`** + 4）：
  `sim/{p4sim,fifoasync,rxpdiag,p6a_ku5p,p5e_udp,vlansim,tbgate,snapcdc,p6e_pcie,p6b_lint,p5sim,f4sim,udprx,udprx_chain,snapseq,p5udp,p5e_t2}/*.bat`、
  `audit_scratch/run_t{1,2,3,4,9}.bat`、`review_scratch/*.bat`、
  `.gitignore`、`tb/tb_p5_app.v`、`sim/p6a_ku5p/pf/rtl_files.f`、`p6b_final_verify/_gen_t3bat.py`
  （建议用 `git add -u -- <这些目录>` 的**目录限定的 `-u`**，而不是 `-A`）
- ⭐ **本层必须最先提交**：`.gitignore` 的放行规则要在后续层之前生效（§A.2）。

### C.L2 —— 新 RTL 与门（源码面）

**主题**：`P7b 新 RTL 与门: mac_10g / rx_classify v2 / 闸1 两通道 PCS 工程源码入库`

| 类 | 文件数 | 体积 |
|---|---|---|
| 新增 | **85** | 1.21 MB（其中 **22 项需 `-f`**，在 §C.0 里点名） |

- `_proj_10g/p7b_mac/`：`rtl/*`(4) `scripts/*`(2) `sim/tb_mac_10g.v` `sim/run_tb_mac_10g.bat` `sim/_mut_logs/*`(13，`-f`)
- `_proj_10g/p7b_rxcls/`：`rtl/*`(1) `scripts/*`(1) `sim/*.v`(2) `sim/*.bat`(2) `sim/legacy/*.v`(1) `sim/legacy_mut/*.v`(1) `sim/_mut_logs/*`(11，其中 9 个 `-f`)
- `_proj_10g/xxv_loop/`：`rtl/*`(12) `tcl/*`(16) `xdc/*`(2) `artifacts/*`(8) `sim/*.v`+`run_*.bat`(3) `patch*.py`+`mkbat.py`+`notes_appendix_r2.md`(5)
  ⚠️ `_proj_10g/xxv_loop/tcl/dfx_runtime.txt`（113 B）**排除**（Vivado 运行残渣）

### C.L3 —— 综合/时序读数（MAC 接入 A/B 对照）

**主题**：`P7b MAC 时序收口: 接入前后 A/B 对照报告 + OOC 读数入库`

| 类 | 文件数 | 体积 |
|---|---|---|
| 新增 | **77** | **14.31 MB**（**8 项需 `-f`**） |

- `p7b_mac_synth/{tcl,rtl,xdc}/*`(23)、`reports/*`(31，9.15 MB)、`logs/*`+`logs/gate/*`(18，1.51 MB)、`baseline/*.rpt`(4，3.53 MB，`-f`)
- ⚠️ `p7b_mac_synth/dfx_runtime.txt`（1 KB）**排除**
- ⚠️ 本层含 §B.4 的决策点（`baseline/xxv_loop_top_timing_summary_routed.rpt` 已在此层；
  若要按选项 ① 补 `pcs64_2ch/...` 那一份，也放本层）

### C.L4 —— 回归与板级证据

**主题**：`P7b 回归与板级证据: 闸1 原始读数 / 语料级铺开扫描 / 16 门矩阵 / 最小复现`

| 类 | 文件数 | 体积 |
|---|---|---|
| 新增 | **142** | 2.25 MB（**1 项需 `-f`**） |
| 修改（已跟踪） | **14** | 0.49 MB |

- `_proj_10g/xxv_loop/logs/*.txt`(32)：`s3_probe_FINAL.txt`（板级定稿那一次的全量 stdout）等
- `_proj_10g/notes/p7b_rollout/`：19 `*.py` + 5 `*.bat` + `logs/*`(14) = 38
- `_proj_10g/notes/p7b_implicit_repro/`：27
- `_proj_10g/notes/p7b_tail/`：32（含 `logs/` 24，其中 1 个 `.log` 需 `-f`）
- `sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt`：**12 个未跟踪的**
- 修改：`sim/p4sim/matrix_p4dfix.log` + `audit_scratch/` 的 13 个 `.log`
  （⚠️ 这些是**已跟踪证据日志的再生成**；`audit_scratch/t3_txcdc/case_pos/xsim_pos_2952.backup.log` 那种**新出现的** `*.backup.log` 按 §A.2 排除）

### C.L5 —— 笔记、规格与文档订正

**主题**：`P7b 笔记与规格: 8 份设计/审查/修复/时序笔记 + 文档订正`

| 类 | 文件数 | 体积 |
|---|---|---|
| 新增 | **8** | 0.33 MB |
| 修改（已跟踪） | **9** | 0.74 MB |

- 新增 8 份：`_proj_10g/notes/{P7B_GATE1,P7B_IMPLICIT_GATE_FIX,P7B_IMPLICIT_GATE_ROLLOUT,P7B_MAC_DESIGN,P7B_MAC_GATEFIX,P7B_MAC_REVIEW,P7B_MAC_TIMING,P7B_RXCLASSIFY_DESIGN}.md`
- 修改 9 个：`CLAUDE.md`、`README.md`、`PORT_NOTES.md`、`P6B_SPEC.md`、`P6B_INTEGRATION_REVIEW.md`、
  `P6E_OBS.md`、`P7A_COMMIT_PLAN.md`、`P7B_SPEC.md`、`_proj_10g/tcl/lint/xvlog.txt`
- ⭐ **本层最后提交**：前面各层的文件已就位后才让引用可解析。

### C.6 合计

| 层 | 新增 | 修改 | 新增体积 | 主题 |
|---|---|---|---|---|
| L1 | 17 | 84 | 0.12 MB | 检测器 + 门修复 + `.gitignore` |
| L2 | 85 | 0 | 1.21 MB | 新 RTL 与门 |
| L3 | 77 | 0 | 14.31 MB | 综合/时序读数 |
| L4 | 142 | 14 | 2.25 MB | 回归与板级证据 |
| L5 | 8 | 9 | 0.33 MB | 笔记/规格/文档 |
| **合计** | **329 → 327**（剔 2 个 `dfx_runtime.txt`） | **107** | **18.21 MB** | — |

（`107` 个修改文件里含 80 个 `.bat`、14 个 `.log`、13 个其它；`4.56 GB` 的抓包、
`0.53 GB` 级的工程/位流全部按既定策略排除。）

---

## §D ⭐ 现状疑点实测：`sim/retxsim2/`

### D.1 结论（三问三答）

| 问题 | 实测结论 |
|---|---|
| 到底哪些文件"未跟踪且未被忽略"？ | **只有 1 个**：`sim/retxsim2/run_tb_frame_fifo.bat`（1,662 B） |
| `run_tb_frame_fifo.bat` 确实被放行了吗？ | ✅ **是**（`check-ignore -q` → `rc=1` = 未被忽略） |
| 有没有别的产物被误放行？ | ❌ **没有**。7.8 MB / 61 个文件里，另外 60 个**全部仍被忽略** |

⇒ 规则 `sim/retxsim*/*` + `!sim/retxsim*/run_tb_*.bat`（`.gitignore:60-61`）**写法正确、副作用为零**。

### D.2 实测命令与输出（逐字）

**① 权威判据**（`git status` 的 `??` ＝ 未跟踪且未被忽略）：

```console
$ git status --porcelain -uall | grep '^??' | grep -i retxsim
?? sim/retxsim2/run_tb_frame_fifo.bat
```

```console
$ git add --dry-run --verbose sim/retxsim2/       # 只打印, 不写索引
add 'sim/retxsim2/run_tb_frame_fifo.bat'
$ git ls-files | wc -l    # 执行前 1683 / 后 1683 ⇒ 索引未被改动
1683
```

**② `check-ignore -q` 的退出码**（`0 = 被忽略`，`1 = 放行`）：对 61 个文件逐个跑，
**除 1 个外全部 `rc=0`**，其中：

```console
$ git check-ignore -q sim/retxsim2/run_tb_frame_fifo.bat ; echo $?
1                                   # ← 放行
$ git check-ignore -q sim/retxsim2/frame_fifo_old.v ; echo $?
0                                   # ← 仍忽略 (规则 sim/retxsim*/*)
$ git check-ignore -q sim/retxsim2/xsim_ff.log ; echo $?
0                                   # ← 仍忽略 (规则 sim/**/*.log)
```

被忽略的另外 60 个文件的**命中规则分布**（`check-ignore -v` 实测）：
`sim/retxsim*/*`（`frame_fifo_old.v` + `xsim.dir.bak_p4c_f2/**` 共 20 个）、
`xsim.dir/`（21 个）、`sim/**/*.log`（2）、`sim/**/*.backup.log`（5）、
`sim/**/*.jou`（6）、`sim/**/*.pb`（2）、`*.wdb`（1）、`dfx_runtime.txt`（1）＝ 58+…
（含目录计数差异，总数 61 = 1 放行 + 60 忽略）。

**③ 已跟踪的同族文件**：

```console
$ git ls-files 'sim/retxsim*'
sim/retxsim/run_retx_tb.bat          # 只有这一个 (隔壁 retxsim/, 不在 retxsim2/)
```

**④ 被引用的证据**：`sim/p4gates/run_matrix_p4dfix.bat` 第 176 行把它列为现役 `unit_fifo` 门：

```
176:call :gate unit_fifo   sim\retxsim2\run_tb_frame_fifo.bat  fifo_src.f  -   "%FRAME_FIFO%"
```

⇒ **必须 `git add sim/retxsim2/run_tb_frame_fifo.bat`**（普通 `add`，不需要 `-f`）。

### D.3 ⚠️ 顺带发现的一个测量陷阱（写进本文件以免后人再踩）

**`git check-ignore -v` 的退出码在 `!` 否定行上不可信**：

```console
$ f=sim/retxsim2/run_tb_frame_fifo.bat
$ git check-ignore -v "$f" ; echo $?
.gitignore:61:!sim/retxsim*/run_tb_*.bat	sim/retxsim2/run_tb_frame_fifo.bat
0                                   # ← 说"被忽略"(错!)
$ git check-ignore -q "$f" ; echo $?
1                                   # ← 说"放行"(对)
```

`-v` 只要**匹配到任何一条规则（含 `!` 行）**就返回 0；`-q` 才返回**最终忽略判定**。
本仓 `P7B_IMPLICIT_GATE_ROLLOUT.md:229-287` 那套调查用的是 `-v` 的**文本**（对），
但若有人拿 `-v` 的**退出码**当判据就会得出相反结论。
⇒ **判"会不会被提交"只认两件事**：`git status --porcelain -uall` 的 `??`，或 `git check-ignore -q` 的 `rc`。

---

## §E 风险与未核实

### E.1 不可逆的信息损失（排除后后人拿不到）

| 排除项 | 体积 | 是否可重建 | 残余风险 |
|---|---|---|---|
| `_proj_10g/p7b_mac_synth/{xxv_mac,mac_only,baseline 生成树}` | 173 MB | ✅ 驱动脚本入库（`tcl/run_mac_only.tcl`、`make_xxv_mac_top.py`、`analyze_ooc.tcl`） | 低。**但**这几棵树的 `.dcp`/网表是"那一版 RTL 的物理实现"，RTL 若日后改动则不可复现同一读数 ⇒ 判据读数已全部以 `.rpt` 形式入库，可接受 |
| `_proj_10g/xxv_loop/pcs64_2ch` | 149 MB | ✅ `tcl/s1_prepare.tcl`→`s2_build.tcl` | 低。位流身份记在 `logs/s3_probe_FINAL.txt:28`（sha256 `5560375b…72ee2c`） |
| `_proj_10g/notes/p7b_rollout/probe_*_work` ×4 | 101 MB | ⚠️ **部分**：脚本全在库（`corpus_scan*.py`、`probe_*.bat`、`probe_configs.py`），但**语料本身是"当时磁盘上全部 xvlog/xelab 日志"**（笔记号称 869 份 xvlog / 452 份 xelab）—— 其中相当一部分日志**自己也是被忽略的产物**，日后重跑语料面会缩水 | ⭐ **中**。这是本方案里最值得留意的一处：**结论（`10-3091` 在 xvlog 侧 0 命中 / 在 xelab 侧 173 份命中）的可复现性依赖于当时的语料快照**。建议：把"语料清单"落成一个文本文件入库（`probe_*_work` 里若有 list/index 文本，应加进白名单）—— **未核实是否存在这样一份清单** |
| `_proj_10g/xxv_gate2` | 88 MB↑ | 在役，未知 | **未核实**：闸2 的驱动（`mkv2.py` + `tcl/`）不在本方案白名单内（整目录排除）。等它收工后必须单独归档，否则闸2 的读数悬空 |
| `sim/snapcdc/review24/`（6 个 `run.bat` 被 3 处引用） | — | ⚠️ 一次性复核目录，`P7B_IMPLICIT_GATE_FIX.md:571` 自述"落不了库也无妨" | 低（已自知） |
| `hls/slowstack_prj/solution1/syn/verilog/udp_echo.v` | 449 KB | ✅ `run_hls.bat` | 低 |
| `sim/*/*.log`（8 条被引用） | — | ✅ 重跑对应门 | 低。**但**引用它们的那几份笔记的读数就变成"重跑才能复核"⇒ 见 E.2 |
| 位流 / `.dcp` / 抓包 | — | ❌ | **既定策略**：身份用 sha256/md5 记在报告里（`P7A_RESULT.md §6.1` 先例）。**不要为了"齐全"破例** |

### E.2 被引用但**判断不该入库**的项 + 替代方案

| 被引用 | 引用者 | 不入库的理由 | 替代方案 |
|---|---|---|---|
| `sim/*/{xelab_*.log,xvlog_*.log,xsim_*.log}`（8 条，如 `sim/vlansim/xvlog_tb.log`、`sim/p6b_lint/xelab_lint.log`、`sim/f4sim/BITEXACT.log`、`sim/p5e_t2/xelab_wh.log`） | P7B_IMPLICIT_GATE_FIX / ROLLOUT、P6B_INTEGRATION_REVIEW、PORT_NOTES | 是**门的中间过程日志**（每次重跑覆盖），同目录的 `*.txt` 判据文件才是归档面；本仓既有口径把 `sim/**/*.log` 一律排除 | ①**在这些笔记/门目录里补写"重跑命令 + 期望读数"**；②或按 p6b 先例**只放行被逐字引用的那几行所在文件**（逐条 `!`）。**建议 ①**（成本 0，且与"可重建"原则一致） |
| `sim/p4gates/work_*/`（8 个 `.log`） | P7B_IMPLICIT_GATE_ROLLOUT | 门的工作目录，重跑即得 | 同上（`run_matrix_p4dfix.bat` 是入口） |
| `_proj_10g/p7b_mac/sim/{xsim_m10g.log,xvlog_m10g.log}` | P7B_MAC_GATEFIX | 自述"每轮覆盖"，留档面是 `_mut_logs/` | 已由 `_mut_logs/` 覆盖 ⇒ 无需动作 |
| `tools/cpp_peer/peer.exe`、`*.bit`、`*.pcap` | CLAUDE.md / P6B_ACCEPT / P6E_OBS / PORT_NOTES | 二进制/位流/抓包，本工程既定不入库 | 源码已跟踪（`peer.cpp`/`udpsend.cpp`）；位流身份记 sha256 |
| `_p7a_probe/{nl_pos,nl_raw,pj_fin,rb_pos,rb_raw}` | P7A_COMMIT_PLAN.md | P7a 段已改判"不入库" | 读数在 `_proj_10g/reports/p7a_readback.txt` |
| `hls/slowstack_prj/solution1/syn/verilog/udp_echo.v` | P7B_IMPLICIT_GATE_ROLLOUT.md:216-217 | HLS 交付产物 | 记"`run_hls.bat` 重建；449,177 B"（**当前笔记已写了体积**，足够定位） |

### E.3 未核实（**不要当成结论**）

1. **`probe_*_work` 里的语料清单是否存在**（§E.1）—— 未核实。若无，§4 的"869/452 份语料"结论的重跑面会缩水。
2. **闸2 的完整证据面**（`_proj_10g/xxv_gate2/`）—— 整目录排除是**照任务书执行**，不代表闸2 的证据已归档；它正在增长（会话内 429 KB → 88 MB）。
3. **8 份笔记我未逐份通读全文**（合计 345,503 B）。§B 的引用表来自**机械化抽取 + 抽样核对**（`P7B_GATE1.md` 证据地图、`P7B_MAC_GATEFIX.md` §1/§10、`P7B_RXCLASSIFY_DESIGN.md` §变异段落 逐段读过）。**完全可能存在"引用在正文散文里、不带路径前缀"的情形没被抽到**。
4. **`.gitignore` 草案只对 33 个代表路径实测过**（§A.0），不是对全量 970 个条目跑过。执行前建议补一次全量对照：加规则后跑 `git status --porcelain -uall | grep '^??' | wc -l`，期望值 **≈ 639**（= 970 − 327 放行 − 若干已跟踪）。
5. ⚠️ **行尾：一条已被证伪的归因（2026-09-30 订正）** —— 原稿写"`git diff` 涉及 **80 个 `.bat`**，其中
   **5 个已变成 LF-only**：…，它们的 **HEAD blob 是 CRLF**（`git cat-file blob HEAD:<f> | grep -cU $'\r'` 实测 = 全行数）
   ⇒ **是本次编辑把 CRLF 改掉了**"。**该归因不成立**：本仓 `core.autocrlf=true`
   （`git config --get core.autocrlf` 实测 `true`）⇒ 索引 / HEAD blob 里**永远存 LF** ⇒
   **从 HEAD blob 看不出工作区的行尾**，所以不能由"HEAD blob 是 CRLF"推出"是本次编辑改坏的"
   （同一课见 `PORT_NOTES.md` 的 P7b 节教训 8：`core.autocrlf=true` 下从 HEAD blob 看不出工作区的行尾，
   本轮"有两次测量栽在这上面"）。
   **实际事实（已转正 = 作为事实登记，不是推论）**：工作区里**确实存在本来就不是 CRLF 的 `.bat`** ——
   那是**既存状态**、**不是本轮编辑引入的**（`P7B_HANDOFF.md` §4 第 6 条原先记 **11 个** ——
   ⚠️ **该数字已作废**；2026-09-30 两处统一为**实测值**，命令
   `git ls-files '*.bat' | while IFS= read -r f; do if LC_ALL=C grep -qU $'\r' "$f"; then echo CRLF; else echo LF-only; fi; done | sort | uniq -c`
   ⇒ 结果 = **304 CRLF / 16 LF-only**（总 320）；⚠️ **计数随文件增删而变，命令如上可复现**。
   另用 Python 按**字节**数 `\r\n` / `\n` 交叉复核，结果相同；⚠️ 不要用按行计数的 `grep -c $'\r'` 写法。
   故此处只作事实登记）；工程纪律"`.bat` 只允许 ASCII + CRLF"依然成立 —— 那批 LF-only 是对纪律的
   **既存**违例，与本轮编辑无关。原稿点名的 5 个文件（`_proj_10g/sim/run_tb_p7a_counters.bat`、
   `review_scratch/run.bat`、`review_scratch/runmac.bat`、`sim/snapcdc/atk/ratio/run_atk_ratio.bat`、
   `sim/snapcdc/atk/reset/run_atk_reset.bat`）**本轮实测已全部是 CRLF**（逐文件 `CRLF 行数 == LF 行数`）。
   ⇒ **本方案不碰任何 `.bat` 的行尾**（零 diff）：不开"转回 CRLF"的动作（点名的 5 个已是 CRLF），
   也不为既存的那批 LF-only 单独开一个提交面。
6. **`git add -u` 的边界**：本方案建议 L1 用"目录限定的 `-u`"，但其精确路径集我未逐条枚举
   （`git status --porcelain | grep '^ M'` 的 107 行已在 §C 分类，**执行者需按目录逐个 `add`**，不要图省事写 `-A`）。

---

## §F 执行清单（给执行者，按序）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g     # git 根就是 udp_hls_10g 自己

# ---- 0) 先落 .gitignore (§A.2), 再验证放行面 ----
#   ...编辑 .gitignore...
git status --porcelain -uall | grep '^??' | wc -l    # 期望 ≈ 639 (原 970)
git check-ignore -q sim/retxsim2/run_tb_frame_fifo.bat; echo $?   # 期望 1

# ---- L1 检测器 + 门修复 ----
git add sim/p4gates/implicit_gate.bat sim/p4gates/implicit_gate_selftest.bat \
        sim/p4gates/evidence/implicit_gate_2026-09-29 \
        sim/retxsim2/run_tb_frame_fifo.bat _proj_10g/tcl/lint/xelab.txt .gitignore \
        tb/tb_p5_app.v sim/p6a_ku5p/pf/rtl_files.f p6b_final_verify/_gen_t3bat.py
git add -u -- sim/p4sim sim/fifoasync sim/rxpdiag sim/p6a_ku5p sim/p5e_udp sim/vlansim \
              sim/tbgate sim/snapcdc sim/p6e_pcie sim/p6b_lint sim/p5sim sim/f4sim \
              sim/udprx sim/udprx_chain sim/snapseq sim/p5udp sim/p5e_t2 \
              audit_scratch review_scratch
# 提交主题: P7b 门修复铺开 + 隐式网规范检测器: xelab 面判据入库, 现役 unit_fifo 门放行

# ---- L2 新 RTL 与门 (含 §C.0 前 22 项 -f) ----
git add _proj_10g/p7b_mac/rtl _proj_10g/p7b_mac/scripts \
        _proj_10g/p7b_mac/sim/tb_mac_10g.v _proj_10g/p7b_mac/sim/run_tb_mac_10g.bat \
        _proj_10g/p7b_rxcls/rtl _proj_10g/p7b_rxcls/scripts \
        _proj_10g/p7b_rxcls/sim/tb_rxcls_v2.v _proj_10g/p7b_rxcls/sim/rx_classify_ref.v \
        _proj_10g/p7b_rxcls/sim/run_tb_rxcls_v2.bat _proj_10g/p7b_rxcls/sim/run_legacy_tb_rxclass.bat \
        _proj_10g/p7b_rxcls/sim/legacy/rx_classify.v _proj_10g/p7b_rxcls/sim/legacy_mut/rx_classify.v \
        _proj_10g/p7b_rxcls/sim/_mut_logs/_suite_final.txt \
        _proj_10g/p7b_rxcls/sim/_mut_logs/06_M8_routeq_ptr.src.v \
        _proj_10g/xxv_loop/rtl _proj_10g/xxv_loop/tcl _proj_10g/xxv_loop/xdc \
        _proj_10g/xxv_loop/artifacts _proj_10g/xxv_loop/sim/tb_pay_sel.v \
        _proj_10g/xxv_loop/sim/run_sim_pay.bat _proj_10g/xxv_loop/patch_r3.py \
        _proj_10g/xxv_loop/patch_s2.py _proj_10g/xxv_loop/patch_top.py \
        _proj_10g/xxv_loop/mkbat.py _proj_10g/xxv_loop/notes_appendix_r2.md
git add -f _proj_10g/p7b_mac/sim/_mut_logs/*.log _proj_10g/p7b_rxcls/sim/_mut_logs/*.log
# 提交主题: P7b 新 RTL 与门: mac_10g / rx_classify v2 / 闸1 两通道 PCS 工程源码入库

# ---- L3 综合/时序读数 ----
git add _proj_10g/p7b_mac_synth/tcl _proj_10g/p7b_mac_synth/rtl _proj_10g/p7b_mac_synth/xdc \
        _proj_10g/p7b_mac_synth/reports _proj_10g/p7b_mac_synth/logs
git add -f _proj_10g/p7b_mac_synth/baseline/xxv_loop_top_drc_routed.rpt \
           _proj_10g/p7b_mac_synth/baseline/xxv_loop_top_timing_summary_routed.rpt \
           _proj_10g/p7b_mac_synth/baseline/xxv_loop_top_methodology_drc_routed.rpt \
           _proj_10g/p7b_mac_synth/baseline/xxv_loop_top_utilization_placed.rpt \
           _proj_10g/p7b_mac_synth/logs/gate/*.log
# + §B.4 选项①: git add -f _proj_10g/xxv_loop/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt
# 提交主题: P7b MAC 时序收口: 接入前后 A/B 对照报告 + OOC 读数入库

# ---- L4 回归与板级证据 ----
git add _proj_10g/xxv_loop/logs/*.txt _proj_10g/notes/p7b_rollout _proj_10g/notes/p7b_tail \
        _proj_10g/notes/p7b_implicit_repro sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt
git add -f _proj_10g/notes/p7b_tail/logs/matrix_p4dfix.HISTORICAL_20260929_2203.log
git add -u -- sim/p4sim audit_scratch
# 提交主题: P7b 回归与板级证据: 闸1 原始读数 / 语料级铺开扫描 / 16 门矩阵 / 最小复现

# ---- L5 笔记与文档 ----
git add _proj_10g/notes/P7B_GATE1.md _proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md \
        _proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md _proj_10g/notes/P7B_MAC_DESIGN.md \
        _proj_10g/notes/P7B_MAC_GATEFIX.md _proj_10g/notes/P7B_MAC_REVIEW.md \
        _proj_10g/notes/P7B_MAC_TIMING.md _proj_10g/notes/P7B_RXCLASSIFY_DESIGN.md \
        CLAUDE.md README.md PORT_NOTES.md P6B_SPEC.md P6B_INTEGRATION_REVIEW.md \
        P6E_OBS.md P7A_COMMIT_PLAN.md P7B_SPEC.md _proj_10g/tcl/lint/xvlog.txt
# 提交主题: P7b 笔记与规格: 8 份设计/审查/修复/时序笔记 + 文档订正

# ---- 每层提交前自查 ----
git status --porcelain | grep -v '^??'          # 只应看到本层预期的 M
git diff --cached --stat | tail -3               # 体积/文件数与本方案对账
```
