# P7B_IGNORE_STAGEC —— Stage C 构建归档的 `.gitignore` 收口（2026-10-07）

> 对应构建支报告 `P7B_BUILD_STAGEC.md` §1.2 / §9-8 的两笔账（归档目录未被 `.gitignore` 覆盖）。
> 本文件只记录**证据与判据**；实际改动只有两处：`.gitignore`（末尾 +26 行）与本报告。
> **未碰** RTL / board / sim / tb / README / 其它 notes；**未起 xsim**；**未烧板**；**未写 `0x08`**；
> **未 `git add` / 未 `commit`**。

---

## 0. 一句话

盘上真名 = **`_proj_10g/notes/p7b_build_archive/<yyyyMMdd_HHmmss>/`**（**不是**根级 `p7b_build_archive/`），
每次构建 19 件（~148 MB 含 dcp/bit），其中 **14 件 / 13.31 MB 此前一直漏进 `git status`**；
同类 `_proj_10g/notes/p7b_build_stageC/baseline_archive/` 同病（**14 件 / 13.94 MB 漏**）。
已在 `.gitignore` **末尾**（L745–754，节含 `!` 行、位置敏感）加 **7 条规则**：整目录排除、**只放行两份 `SHA256SUMS.txt`**（文本证据）。
`git check-ignore -q` 逐件实测 **19/19 + 19/19**；合成"未来 stamp"路径 5/5；负对照 10/10。
全仓未跟踪（git 会看见的口径）**63.6 MB / 1108 件 → 37.0 MB / 1082 件**（−26.6 MB / −26 件）。

---

## 1. 盘上真名与结构（先核实，未照抄派单）

| 目录 | 来源 | 结构 | 体积 | 件数 |
|---|---|---|---|---|
| `_proj_10g/notes/p7b_build_archive/` | **本轮新增**：`board/run_build_p7b_ku5p.bat` 的 pre-build archive 块自动写（`P7B_BUILD_STAGEC.md` §1.2） | 两级：`<stamp>/` 下**平铺** 19 件（18 产物 + `SHA256SUMS.txt`）；现只有 1 个 stamp = `20261007_163651/` | 148 MB（含 59+65 MB dcp、15 MB bit） | 19 |
| `_proj_10g/notes/p7b_build_stageC/baseline_archive/` | 本轮新增：开工前**手工**归档（Build 2 产物） | 一级：平铺 19 件 | ~150 MB（含 59+65 MB dcp、15 MB bit） | 19 |

⚠️ 派单里说"可能是 `p7b_build_archive/`（根级）或 `_proj_10g/notes/p7b_build_archive/`"——**去盘上找的结果**：
根级那个**不存在**；真名是 `_proj_10g/notes/p7b_build_archive/`（`find` 全仓 depth≤3 只有 `_proj_10g/notes/p7b_build_archive` 这一处）。

**改前全径对账**（逐件 `check-ignore`，改前）：
- 全局既有规则挡掉的大件 = `*.bit`(L36) / `*.dcp`(L322) / `*.log`(L35) ⇒ 每目录 **5 件**（`wrapper_p4*.bit` + 2×`.dcp` + `runme_{impl,synth}_1.log`）。
- **漏的 = 14 件 / 每目录 ≈13.3 MB**（全部 `.rpt` 与 `.txt`，含 8.52 MB `wrapper_p4_timing_summary_routed.rpt`、3.87 MB `wrapper_p4_control_sets_placed.rpt`、0.59 MB `p7b_ku5p_timing.rpt`、0.52 MB `p7b_ku5p_stdout.txt` …）。
- ⇒ 派单的"`*.dcp` 已有全局规则？"答案是 **有**（L322，2026-09-30 加的那条）；漏网的是 `.rpt/.txt`。

---

## 2. 改动（只有 `udp_hls_10g/.gitignore` 末尾 +26 行）

| 项 | 值 |
|---|---|
| 改前 sha256 | `26848616b7cf691044bec7d34728a7b3ec51dcf4d2ded62b5bc99003a70e587d`（= `git show HEAD:.gitignore`；开工时 `git status` 无 `M .gitignore` ⇒ 工作副本与之逐字相同） |
| 改后 sha256 | `25e7c7a09479757ab11a9f9c8839b8f9a94e5024c1d0c271902c907c3c35ff85` |
| `git diff --stat` | **`.gitignore | 26 ++++++++++++++++++++++++++` → +26 / −0** |
| 行尾 | 全文件 **LF**（改前/改后 `grep -c $'\r'` 均 = 0；`file` 判 UTF-8）—— 与工作副本原状一致（git 的 `LF will be replaced by CRLF` 警告是 core.autocrlf 既有现象，与本次无关） |
| 新规则行号 | **L745–748**（archive）+ **L752–754**（baseline_archive），节在**文件末尾** |

---

## 3. 逐条规则（改前 → 改后 / 理由）

| # | 规则（行号） | 改前 | 改后 | 理由 |
|---|---|---|---|---|
| 1 | `_proj_10g/notes/p7b_build_archive/*`（L745） | 档内 14 件可见 | 深度 1 全排 | 目录 = 构建产物（**~150 MB/次、会持续增长**，§9-8"长期增长未处理"）；且任务口径 = 只留清单 |
| 2 | `!_proj_10g/notes/p7b_build_archive/*/`（L746） | — | stamp 目录**本身**可见（允许 git 下降） | ⚠️ **整目录排除时 git 根本不下降 ⇒ 后面任何 `!` 静默无效**（先例：`_proj_10g/p7b_mac_synth/baseline` L93–95 / `sim/p5c_t3/rev` 三步法） |
| 3 | `_proj_10g/notes/p7b_build_archive/*/*`（L747） | — | stamp 内 18 件产物全排 | 大件 `.bit/.dcp/.log` 靠全局规则也够；`.rpt/.txt`（13.31 MB）此前无规则可挡 |
| 4 | `!_proj_10g/notes/p7b_build_archive/*/SHA256SUMS.txt`（L748） | 漏 | **放行** | **清单是文本证据**：记录该次构建 18 件产物的 sha256，重建产物**换不出同值**（§1.1"归档保真自证"引它；已交叉验证：清单里的 bit 行 `1ccbd9cd…` 与盘上 `wrapper_p4.bit` 实测逐字相同） |
| 5 | `!_proj_10g/notes/p7b_build_stageC/baseline_archive/`（L752） | — | 目录可见（下降） | 排除**该目录本身**的规则靠上并不存在（实测），此行 = 纵深防御（先例同 `p7b_mac_synth/baseline`） |
| 6 | `_proj_10g/notes/p7b_build_stageC/baseline_archive/*`（L753） | 14 件可见（13.94 MB；125 MB dcp 已被全局 `*.dcp` 挡住） | 全排 | 同 #1 口径（手工归档 = 同类构建产物） |
| 7 | `!_proj_10g/notes/p7b_build_stageC/baseline_archive/SHA256SUMS.txt`（L754） | 漏 | **放行** | 同 #4（同一份 Build 2 产物的清单；bit 行哈希同样 `1ccbd9cd…` 实测对上） |

**一句话口径**：大件/报告 = 可重建 ⇒ 排除；`SHA256SUMS.txt` = 唯一不可重建的文本证据 ⇒ 放行。

---

## 4. 验证（`git check-ignore -q` 实测；⚠️ 按本工程纪律**只用 `-q` 定判定**，`-v` 仅用于显示命中规则）

### 4.1 逐件（改后，全量；`rc=0` = 被忽略，`rc=1` = 可见）

`p7b_build_archive`（19/19）：

```
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/p7b_ku5p_clkinteract.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/p7b_ku5p_drc.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/p7b_ku5p_stdout.txt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/p7b_ku5p_timing.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/p7b_ku5p_util.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/runme_impl_1.log
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/runme_synth_1.log
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4.bit
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_clock_utilization_routed.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_control_sets_placed.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_drc_routed.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_power_routed.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_route_status.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_routed.dcp
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_synth.dcp
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_timing_summary_routed.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_utilization_placed.rpt
rc=0 (want 0)  _proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4_utilization_synth.rpt
**rc=1 (want 1)  _proj_10g/notes/p7b_build_archive/20261007_163651/SHA256SUMS.txt**   ← 唯一放行件
=== PASS=19 FAIL=0 ===
```

`p7b_build_stageC/baseline_archive`（19/19，同构）：

```
rc=0 (want 0)  …/baseline_archive/{p7b_ku5p_clkinteract.rpt, p7b_ku5p_drc.rpt, p7b_ku5p_stdout.txt,
                p7b_ku5p_timing.rpt, p7b_ku5p_util.rpt, runme_impl_1.log, runme_synth_1.log,
                wrapper_p4_Build2.bit, wrapper_p4_clock_utilization_routed.rpt,
                wrapper_p4_control_sets_placed.rpt, wrapper_p4_drc_routed.rpt, wrapper_p4_power_routed.rpt,
                wrapper_p4_route_status.rpt, wrapper_p4_routed_Build2.dcp, wrapper_p4_synth_Build2.dcp,
                wrapper_p4_timing_summary_routed.rpt, wrapper_p4_utilization_placed.rpt,
                wrapper_p4_utilization_synth.rpt}                        ← 18 件 rc=0
**rc=1 (want 1)  …/baseline_archive/SHA256SUMS.txt**                  ← 唯一放行件
=== PASS=19 FAIL=0 ===
```

### 4.2 合成"未来构建"路径（防下次又漏；路径当前不存在，纯模式匹配）

```
rc=0 IGNORED  _proj_10g/notes/p7b_build_archive/20991231_235959/wrapper_p4_timing_summary_routed.rpt
rc=0 IGNORED  _proj_10g/notes/p7b_build_archive/20991231_235959/wrapper_p4.bit
rc=0 IGNORED  _proj_10g/notes/p7b_build_archive/20991231_235959/wrapper_p4_routed.dcp
rc=0 IGNORED  _proj_10g/notes/p7b_build_archive/20991231_235959/sub/nested.txt     ← 三层也挡下
rc=1 visible  _proj_10g/notes/p7b_build_archive/20991231_235959/SHA256SUMS.txt      ← 未来清单照放行
rc=0 IGNORED  _proj_10g/notes/p7b_build_archive/stray.txt                          ← 散在根上的文件也挡
```

### 4.3 目录下降（`!dir/` 是否奏效 —— 整目录排除会让 `!` 静默失效，这一步专门验它）

```
rc=1 dir visible  _proj_10g/notes/p7b_build_archive/20261007_163651
rc=1 dir visible  _proj_10g/notes/p7b_build_stageC/baseline_archive
```
（`rc=1` = 目录**未被**忽略 ⇒ git 会下降进去 ⇒ §4.1 的清单放行才可能生效。）

### 4.4 负对照（**不该**被新规则波及的 10 条；实测全 `rc=1` = 仍可见）

```
rc=1  _proj_10g/notes/p7b_build_stageC/stageC_p7b_ku5p_timing.rpt              （根证据，判定=该进库）
rc=1  _proj_10g/notes/p7b_build_stageC/bat_stdout.txt
rc=1  _proj_10g/notes/p7b_build_stageC/gatecheck_out.txt
rc=1  _proj_10g/notes/p7b_build_stageC/stageC_wrapper_p4_timing_summary_routed.rpt
rc=1  _proj_10g/notes/P7B_BUILD_STAGEC.md                                       （本轮笔记）
rc=1  board/p7b_ku5p_timing.rpt                                                 （现役读数）
rc=1  _proj_10g/notes/p7b_build_stageA/BASE_p7b_ku5p_timing.rpt                 （已入库先例，不受影响）
rc=1  sim/p7b_stagec_tx_regress/mirror/CLAUDE.md                                （sim 面未被本轮改动波及）
rc=1  sim/p7b_stagec_a2/gate_out.txt
rc=1  tb/tb_tcp_tx_ovl.v
```
⇒ **10/10 全部 `rc=1`**：新规则**只**约束 `p7b_build_archive/` 与 `baseline_archive/` 两个目录。

### 4.5 `git status` 面（改前 → 改后）

- 改前：`?? _proj_10g/notes/p7b_build_archive/`、`?? _proj_10g/notes/p7b_build_stageC/`（整目录）。
- 改后（`git status --porcelain -uall`，`p7b_build*` 只剩 12 条）：**2 份 `SHA256SUMS.txt` + stageC 根 10 件证据**（后者判定"该进库"，见 §5，保持可见未动）。
- 全仓未跟踪总量：**63.6 MB / 1108 件 → 37.0 MB / 1082 件**（−26.6 MB / −26 件）。

---

## 5. 全域未跟踪扫描（`git ls-files --others --exclude-standard` 口径）与判定

⚠️ 单文件 >10 MB 的未跟踪件 = **0**（最大 = 8.53 MB 的 timing_summary ×3 份；15 MB `.bit` 与 59–65 MB `.dcp` 已被全局规则挡）。
按目录聚合，**>10 MB 的 3 条**逐个判定如下（其余列入下下表）：

| 条目（改前，MB/件数） | 判定 | 依据 |
|---|---|---|
| `_proj_10g/notes/p7b_build_archive/`（**13.31 / 14**） | ❌ 不该进库 ⇒ **已排除**（留清单 1.7 KB） | 本轮自动归档；~150 MB/次且增长 |
| `_proj_10g/notes/p7b_build_stageC/` 内 `baseline_archive/`（**13.94 / 14**） | ❌ 不该进库 ⇒ **已排除**（留清单 1.7 KB） | 手工归档；125 MB dcp 原本就被全局规则挡 |
| `sim/p7b_stagec_tx_regress/`（**20.80 / 773**） | ⚠️ **混合——本轮未动手**（越出授权；配方见 §6.1） | `mirror/`(412 件/11.87 MB，仓库树副本、无 `.git`)、`head_root/`(219 件/4.20 MB，HEAD 快照，`head_root/board/wrapper_p4.v` md5≠工作副本)、`head_rtl/`(33 件/0.77 MB，**先例 `.gitignore:723` 字面排除同名目录**) ⇒ 这三块"不该进库"证据充分；但同目录还有**被本轮笔记逐字引用**的件（`setup_arm.py` / `arm_M0..M3.log` / `author_gate_stdout.txt` / `frozen/…`），不能一刀切 |

其余未跟踪条目（<10 MB，逐条判定）：

| 条目 | 体积/件数 | 判定 | 依据 |
|---|---|---|---|
| `_proj_10g/notes/p7b_build_stageC/` 根 10 件 | 9.37 MB | ✅ 该进库（**未动**，保持可见） | 现役读数原件（§10 列名）；stageA/B 先例（`BASE_*.rpt`/`bat_stdout.txt`/`gatecheck_out.txt` 均已入库）；8.5 MB 级 rpt 是本仓**既有尺度**（`p7b_biz_tcpreg/rate_rebuild/wrapper_p4_timing_summary_routed.rpt` 8.54 MB **已在库**） |
| `sim/p7b_stagec_a2/` | 4.87 MB / 236 | ⚠️ 见 §6.1（引用了 `run_a2_gate.bat`/`apply_a2.py`/`gate_out.txt`/`r_all.txt`…） | 同上族 |
| `sim/p7b_stagec_tx/` | 1.42 MB / 27 | ⚠️ 见 §6.1（引用了 `runB/xs.log`、`mut/`…） | 同上族 |
| `sim/p7b_stagec_tx_review/` | 0.06 MB / 10 | ⚠️ 见 §6.1（顶层全是 .py/.v/.bat 驱动 + runA..D） | 同上族 |
| `tb/tb_{app_a2_equiv,integ_app_tx,tcp_tx_ovl}.v` | 0.16 MB / 3 | ✅ 该进库 | 本轮回归轮 TB 源码；无规则挡（实测 rc=1） |
| `sim/p4sim/P4_MATRIX_FINGERPRINT_*` ×4 | 0.15 MB / 4 | ✅ 该进库 | `.gitignore:396` 已放行该族（修订指纹证据对） |
| `_proj_10g/notes/{P7B_BUILD_STAGEC,P7B_OUTER_CLAUDE_STAGEB,P7B_STAGEC_A2,P7B_STAGEC_TX,P7B_STAGEC_TX_REGRESSION,P7B_STAGEC_TX_REVIEW}.md` | ~0.13 MB / 6 | ✅ 该进库 | 本轮 6 份笔记 |
| `_tmp_*.py` ×11（仓库根） | ~0.04 MB / 11 | ⚪ **非本轮**（mtime 09-29，早于 Stage C）⇒ 不在本轮判定范围 | — |

---

## 6. 没能判定的 / 未动手的（如实登记）

### 6.1 `sim/p7b_stagec_*` 四目录的 ignore 规则 —— **没写**（需所有者知识；且纪律禁碰 sim/）

- **为什么不能照抄 stageB 配方**：stageB 一族（`.gitignore:686–700`）的口径是 `/*` + 只放行 `*.bat/*.sh/*.v/*.py`
  —— 直接套到 stageC 会把**被本轮笔记逐字引用**的 `.txt/.log/.pre_a2` 一并挡掉 ⇒ **结论悬空**。已抓到的最小反例：
  `p7b_stagec_a2/gate_out.txt`、`p7b_stagec_tx_regress/arm_M0..M3.log`、`p7b_stagec_tx/runB/xs.log`、
  `p7b_stagec_a2/app_pattern.v.pre_a2`（后缀 `pre_a2` 连 `*.v` 都不匹配）。
- **已核实的"确定不该进"子集**（有先例支撑，若要动手建议只先动这三块）：
  `sim/p7b_stagec_tx_regress/{mirror,head_root,head_rtl}/`（仓库树/HEAD 快照副本；`head_rtl/` 的先例就在 `.gitignore:723`）。
- **未判定的是"该留件"清单**：谁知道哪些是本轮该入库的对照/读数件（对应 stageA/B 的 `BASE_*`/`stageB_*`），
  只有该轮回归/审查 agent / 所有者知道 —— 派单里 `sim/` 在本任务禁碰面内，故**只报不动**。

### 6.2 `baseline_archive` 的 `.rpt` 要不要按 `p7b_mac_synth/baseline` 先例放行（**没放**）

- 事实：`p7b_mac_synth/baseline`（L93–95）按"被文档引用"的既定口径**放行了 `*.rpt`**；
  本次派单口径写的是"**只放行清单、排除大件**"⇒ 按派单执行（`.rpt` 全排）。
- 代价（如实登记）：`P7B_BUILD_STAGEC.md` §4（`baseline_archive/p7b_ku5p_timing.rpt:156`）与 §5
  （`baseline_archive/wrapper_p4_timing_summary_routed.rpt`）两处引用在新克隆里**取不到原件**
  （哈希面仍在 `SHA256SUMS.txt`，报告内文仍可读）。
- 一行扩权（**未加**，供裁定）：若想留 4 份小 rpt（589K/66K/51K/14K），在 L754 后加
  `!_proj_10g/notes/p7b_build_stageC/baseline_archive/p7b_ku5p_*.rpt` 即可。

### 6.3 其它

- **三层结构的理论缺口**：archive 未来若在 stamp 里再套子目录，`*/*` 会把该子目录整体挡下（目录被排除 ⇒ 不下降），
  唯一缺口 = 出现在**三层深处**的第二份 `SHA256SUMS.txt`（现脚本写的是平铺 19 件，不会发生；结构已核，§1）。
- **长期增长未根治**：本任务只做 ignore；"150 MB/次一直占盘"的保留策略/清理**未做**（也不在授权内）。

---

## 7. 纪律声明

- 只改 **`.gitignore`**（+ 本报告）。未碰 `rtl/` `board/` `sim/` `tb/` `README.md` 与其它 notes；未起 xsim；未烧板；未写 `0x08`。
- 未 `git add`、未 `git add -A`、未 `commit`。
- 本文件中所有验证输出均为实际命令输出；判定只以 `git check-ignore -q` 的退出码为准（`rc=0` 被忽略 / `rc=1` 可见），
  `-v` 仅用于显示命中的规则行。
