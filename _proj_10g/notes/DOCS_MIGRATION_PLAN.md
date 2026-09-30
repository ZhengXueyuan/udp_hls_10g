# 根目录文档迁移方案 (`docs/`)

**状态: 方案已定稿, 未执行。** 本文档**只描述**迁移; 执行时机 = **P7b 开发与测试全部完成、push 之前**。

- 目标仓库: `D:\repo\XCKU5PMini\udp_hls_10g` (git 根; `git rev-parse --show-toplevel` 实测确认)
- 基线 commit: **`02d51ed`** (branch `master`), 工作树**脏**: `git status --porcelain` 实测
  `29` 个 ` M` (未暂存修改) + `0` 个已暂存 + `32` 个 `??` 条目 (展开后 `git ls-files --others --exclude-standard` = **259** 个文件)
- **本方案不执行任何 git 写操作 / 不移动任何文件 / 不跑 Vivado / 不烧板。** 本文件自身是唯一新增物。
- 数字口径: 下文所有计数均为**本次实测**, 命令与原始输出附在 §8「度量复现命令」。
  已知外部给过的参考值 "约 101 个已跟踪文件、约 724 处引用" —— 本次独立复测得
  **101 个已跟踪文件 / 732 处引用** (口径差异见 §2.1), **101 这个数逐字吻合**。

---

## 0. 结论摘要 (先读这 10 条)

| # | 结论 | 依据 |
|---|---|---|
| 1 | **只挪文档, 脚本一律不动。** 挪脚本与挪文档是两类风险 | §1.3 论证; 门 bat 是"自定位"的 (`%~dp0..\..`) |
| 2 | 挪 **14** 份, 留 **2** 份 (`README.md` / `CLAUDE.md`) | §1.2 |
| 3 | 目标结构 = **扁平 `docs/`**, 不分子目录 | §1.1 |
| 4 | 全仓引用 = **101 个已跟踪文件 / 732 处** (`.md` 形式 436 处) | §2.1 实测 |
| 5 | **零功能性依赖**: 没有任何脚本 `open`/`type`/`copy`/`findstr` 这些文档 | §2.3 实测为空 |
| 6 | **守卫对根文档的路径依赖 = 0**; `p4gate.py`/`paths.txt`/`run_matrix_p4dfix.bat`/`implicit_gate*.bat` 全是 0 命中 | §3.1 |
| 7 | ⚠️ 但 `p4env.bat` **在 `FINGERPRINT_GLOBS` 里** ⇒ 改它一个字的**注释**会改矩阵 revision DIGEST | §3.2 |
| 8 | `.gitignore` 的 10 处全是**注释**; 且**现在没有任何规则管根 `.md`**; `docs/` 实测**未被忽略** | §3.3 |
| 9 | 迁移**分两个提交**: ①纯移动(可 `-M` 证明 R100) ②引用改写 | §6.2 |
| 10 | 最大风险 = **改写把"历史读数/逐字引文"也改了** ⇒ 伪造证据 | §6.1 R1 |

---

## 1. 目标结构与映射表

### 1.1 要不要分组? —— **不分组, 扁平 `docs/`**

**提议结构:**

```
docs/
├── PORT_NOTES.md              (5177 行, 全项目流水账/教训库)
├── P6B_ACCEPT.md              P6B_CDC_AUDIT.md        P6B_COMMIT_PLAN.md
├── P6B_INTEGRATION_REVIEW.md  P6B_REVIEW.md           P6B_SPEC.md
├── P6B_SUMMARY.md             P6E_OBS.md
├── P7A_COMMIT_PLAN.md         P7A_RESULT.md           P7A_SPEC.md
├── P7B_SPEC.md
└── ISSUE_RX_BYTE_CORRUPTION.md
```

**理由 (逐条):**

1. **前缀已经是分组了。** `P6B_` / `P7A_` / `P7B_` 三个里程碑前缀天然排序、天然可 glob。
   再套 `docs/milestones/` 只增加一层与后缀重复的信息。
2. **三分组会强迫一次有损分类。** 这批文件本身就是跨类的:
   `P6B_ACCEPT.md` 既是验收报告又是判据规格; `P7A_COMMIT_PLAN.md`/`P7B_SPEC.md` 是计划/规格;
   `ISSUE_RX_BYTE_CORRUPTION.md` 是案例记录。**分类是内容判断, 不是迁移判断** ——
   迁移阶段做分类, 等于把"可机械验证的移动"和"需要人判断的归类"绑在一起,
   一旦归错, 回滚代价从"移动"升级成"移动+分类"。
3. **每多一个路径段, 改写正则与检查器的复杂度就乘一次。** 本次实测引用形态是
   **纯裸名、根相对约定**(§2.2), 改写规则因此可以简化成一条无歧义的前缀插入。
   分组会把这条规则变成 14 条分派规则。
4. ⭐ **本工程已有"真空门"事故的教训**: 变哑的门比报错的门危险得多。让移动步骤的
   不变量尽可能少、尽可能可机械判定, 是同一个原则。
5. **分组可以后置**: 等引用全部干净之后, 再单独来一次纯 `git mv` 做纯装饰性的分组 ——
   那时它是一次独立、零风险、又可用 `-M` 验证的操作。**先解耦, 再美化。**

> 可选: `docs/INDEX.md` 作索引。**不建议叫 `docs/README.md`** ——
> 本仓 `README.md` 这个子串已被 6 个**别的** README 占用 (见 §2.2 陷阱表),
> 再造一个同名的只会加重同一类误改写。

### 1.2 逐文件映射表 (14 份)

| # | 旧路径 | 新路径 | 行数 | 根因/备注 |
|---|---|---|---|---|
| 1 | `PORT_NOTES.md` | `docs/PORT_NOTES.md` | 5177 | 被引用最多 (见 §2.1) |
| 2 | `P6B_ACCEPT.md` | `docs/P6B_ACCEPT.md` | 309 | |
| 3 | `P6B_CDC_AUDIT.md` | `docs/P6B_CDC_AUDIT.md` | 259 | 非 git 层唯一引用目标 (§2.4) |
| 4 | `P6B_COMMIT_PLAN.md` | `docs/P6B_COMMIT_PLAN.md` | 626 | |
| 5 | `P6B_INTEGRATION_REVIEW.md` | `docs/P6B_INTEGRATION_REVIEW.md` | 473 | 被 `p4env.bat` 注释引用 (§3.2) |
| 6 | `P6B_REVIEW.md` | `docs/P6B_REVIEW.md` | 598 | |
| 7 | `P6B_SPEC.md` | `docs/P6B_SPEC.md` | 1434 | 被 `wrapper_p4.v` 裸名引用 28 处 |
| 8 | `P6B_SUMMARY.md` | `docs/P6B_SUMMARY.md` | 164 | 接手必读 |
| 9 | `P6E_OBS.md` | `docs/P6E_OBS.md` | 366 | 现役观测通道表 |
| 10 | `P7A_COMMIT_PLAN.md` | `docs/P7A_COMMIT_PLAN.md` | 468 | |
| 11 | `P7A_RESULT.md` | `docs/P7A_RESULT.md` | 474 | |
| 12 | `P7A_SPEC.md` | `docs/P7A_SPEC.md` | 814 | |
| 13 | `P7B_SPEC.md` | `docs/P7B_SPEC.md` | 1002 | `.gitignore` 注释称"11 个文件被 P7B_SPEC.md 逐字引用" |
| 14 | `ISSUE_RX_BYTE_CORRUPTION.md` | `docs/ISSUE_RX_BYTE_CORRUPTION.md` | 2196 | |

(行数为 `wc -l` 实测; 迁移后行号不变 —— 见 §2.5。)

### 1.3 哪些文件**不该挪** —— 2 份, 理由不同性质

| 文件 | 判定 | 理由 |
|---|---|---|
| **`README.md`** | **留根** | ① 惯例: 仓库入口, 人/工具/GitHub 都在根找它; ② 本仓 `README.md` 是**已被承认为根相对约定**的引用目标 (§2.2), 挪它会牵动最多的引用且收益最低; ③ **本文件正在被本阶段改动** (`git status` 显示 ` M README.md`), 挪它会把"移动"与"P7b 内容改动"搅在同一批 diff 里, 直接破坏 §4 的 `-M` 判定。 |
| **`CLAUDE.md`** | **留根 (硬约束, 非惯例)** | **Claude Code 只从仓库根读 `CLAUDE.md` 作为项目指令。** 挪进 `docs/` 会**静默地**让项目指令失效 —— 注意它是**静默**失效: 没有任何报错, 只是从此没人读。这与"变哑的门"同性质, 属于本工程明令要防的一类。 |

> 另: `PktMon*.txt` / `*.etl` / `*.pcapng` / `build_*.log` 等**不是文档**, 是抓包与日志残渣, **不属本方案范围**
> (它们的入库/排除是 `.gitignore` 的既有议题, 本方案不动)。

### 1.4 ⭐ 本方案边界: 只挪文档, 不挪脚本 —— 论证

**必须明确回答"只挪文档还是也挪别的"。答案是: 只挪文档。**

| 假设的"顺手也挪"对象 | 为什么不能挪 |
|---|---|
| `sim/p4gates/*.bat` (门) | **自定位**: `p4env.bat` 用 `for %%I in ("%~dp0..\..")` 反推 `P4_SELF_ROOT`。挪出 `sim/p4gates/` 后 `..\..` 指向别的目录 ⇒ 根推导**直接错**; 且 `p4gate.py guard` 会因 `self_root` 不在 `root` 内而**拒绝运行** (这是设计, 不是 bug) —— 即"门会响", 但整条矩阵直接不可用。 |
| 门的 manifest (`*_src.f`) | 被 `MANIFEST_GLOB=sim\p4gates\*_src.f` 与 runner 的 16 行 `call :gate` **按字面路径**引用; 挪动即 16 行全断 |
| `paths.txt` / `p4gate.py` | `REQUIRED_MARKERS` / `REQUIRED_DIRS` **逐字列出** `sim\p4gates\...` ⇒ 挪动后 `guard` 报 "root is not this checkout" |
| `rtl/` `tb/` `board/` `tools/` | 全部在 `REQUIRED_MARKERS`/manifest/HLS 路径里; 且与本任务无关 |

**结论:** 待挪对象与"路径敏感件"**完全不相交** (14 份根 `.md` 无一出现在 `REQUIRED_MARKERS`、
`REQUIRED_DIRS`、`MANIFEST_GLOB`、`FINGERPRINT_GLOBS`、16 行 `call :gate` 或任何 manifest 里 —— §3.1 逐条实测)。
因此**移动文档的爆炸半径是 0 个构建/门/脚本**。反之挪脚本的爆炸半径是 16 个门 + 根推导 + 指纹。
**两者风险量级不同, 不合并。**

---

## 2. ⭐ 引用清单 (本方案核心)

### 2.1 实测总量

口径: **"指向这 14 份文档的引用"** = 出现 `Name.md` 或裸名 `Name` (后接 `§`) 且
**前面不是路径字符**(`[A-Za-z0-9_./\ -]`) —— 即"根相对裸名"。正则:
`(?<![A-Za-z0-9_./\\-])(NAME1|...|NAME14)(\.md)?(?![A-Za-z0-9_.-])`

**A. 已跟踪文件: 101 个文件 / 732 处**

| 引用者类别 | 处数 | 文件数 | 例 | 处理后是否需同步改 |
|---|---|---|---|---|
| 已跟踪**文档** (`.md`) | **520** | 31 | `P7B_SPEC.md:503` 引 `PORT_NOTES.md:3613` | **要** (但见 §2.2 历史引文例外) |
| 已跟踪**代码** (`.v/.vh/.xdc/.tcl/.sh/.py/.cpp`) | **154** | 62 | `board/wrapper_p4.v` 28 处裸名 `P6B_SPEC` | **要** (纯注释) |
| **守卫目录** `sim/p4gates/` | **28** | 3 | `p4env.bat`(1) + `evidence/sweep_absolute_paths.txt`(26) + `evidence/pre_migration_bats/*_OLD.sh`(1) | 1 要 / **27 不要** (§3.2) |
| 已跟踪**其它** `.txt` | **19** | 2 | `_proj_10g/notes/p7b_implicit_repro/docs_apply_log.txt`(11) | **不要** (历史应用日志) |
| **`.gitignore`** | **10** | 1 | 行 225/443/448/458/479/496/512/517/548/555 | **要** (全是注释) |
| 已跟踪**其它** `.log` | **1** | 1 | `_proj_pcie/smoke_scratch/p6b_accept.log` | **不要** (证据日志) |
| **合计** | **732** | **101** | | |

- 其中**带 `.md` 后缀**的 = **436 处**。差额 296 处是**裸名引用**(如 `P6B_SPEC §7.2`)。
- ⚠️ **只按 `.md` grep 会漏 296 处 (40%)。** 这是本方案最容易漏的一类。

**B. 未跟踪文件: 18 个文件 / 167 处**

| 处数 | 文件 | 处置 |
|---|---|---|
| 28 × 4 = 112 | `_proj_10g/p7b_chain/_f2_scratch{,_eq,_pad}/wrapper_p4.v` + `_mut_rtl/wrapper_p4.v` | **不要改** —— 它们是 `board/wrapper_p4.v` 的**变异/暂存副本**, 改了就与"变异实验"的前提不符 |
| 35 | `_proj_10g/notes/README_REWRITE.md` | 要 (活的指针) |
| 5 | `_proj_10g/notes/P7B_GATE2.md` | 要 |
| 2 + 2 | `_proj_10g/notes/P7B_{F2_CHAIN_ATTRIB,LATENCY}.md` | 要 |
| 3 | `_proj_10g/p7b_chain/{add_f2,patch_f2x,mut_f2_noflush}.py` | 要 (注释) |
| 2 | `_proj_10g/p7b_lat/scripts/analyze_lat.py` | 要 (注释) |
| 1 × 3 | `_proj_10g/p7b_mac/sim/_prefix_rtl/mac_10g_defs.vh`, `board/ku5p_p7b_cdc.xdc`, `board/p7b_pcs_stub.v` | 要 (注释) |
| 1 × 3 | `sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt` | **不要改** —— 快照文件, 改了就不叫快照 |

> 未跟踪文件的处置原则: **代码/笔记 → 改; 快照/证据/变异副本 → 不改。**
> 未跟踪文件不入库, 所以"悬挂"只影响本地阅读; 但 `wrapper_p4.v` 那 112 处**天然会保持"旧样式"** ——
> §5.1 的检查器必须把它们**显式 allowlist**, 否则它会永远报红。

### 2.2 ⭐ 改写规则 (一条, 且必须带 lookbehind)

**规则:** 对命中处, 把 `Name.md` → `docs/Name.md`、`Name §` → `docs/Name §` (裸名也加前缀)。

**为什么必须带 lookbehind —— 实测的 3 类反例, 天真全局 `sed` 会改坏它们:**

| 反例 | 处数 | 位置 | 真相 |
|---|---|---|---|
| `udp_hls_eco/PORT_NOTES.md` | 3 | `board/eco_p6_t8p0.xdc:7`, `eco_p6_t6p4.xdc:7`, `eco_rgmii_phy1.xdc:7` | 指向**兄弟仓/另一目录**的 `PORT_NOTES.md`, **不是本仓根那份** |
| `tools/cpp_peer/README.md` | — | 多处 | 是**另一个** README |
| `_pcie/README.md`, `_proj_pcie/README.md`, `sim/p5close/README.md`, `board/ku5p_probe/*/README.md`, `taxi/README.md`, `example/KCU116/fpga_10g/README.md` | — | 多处 | **都是别的** README (第三方库/子项目) |

> ✅ 上表已验证: 本文 §2.1 的 lookbehind 正则**把这 3 类全部正确排除** (实测
> `git grep -oP '([A-Za-z0-9_./\\-]*)(NAME\.md)'` 过滤含分隔符者 = 只有那 3 处 `udp_hls_eco/`)。
> ⚠️ 但 `README.md` 本方案**不挪**, 所以上表 6 项对本方案是"无害的运气";
> **一旦将来有人挪 `README.md`, 这 6 项就是地雷。**

**第二条规则 —— 不要发明 `../` 相对路径。**
实测:**所有**指向待挪文档的引用都是**根相对裸名**(唯一的 `/` 形式是上表那 3 处外仓引用)。
⇒ 改写必须**只插 `docs/` 前缀**, 不许算 `../../docs/...`。
理由: 现存形态**已经是**"根相对约定" (例如 `_proj_10g/notes/foo.md` 里写 `P6B_SPEC.md`,
而 `_proj_10g/notes/` 下并没有这个文件 —— 它今天就是靠约定解析的)。改成真相对路径是
**语义变更**, 会与全仓 732 处的既有约定冲突, 并让同一文档在不同深度的引用者写出不同字面。

### 2.3 ⭐ 零功能性依赖 (实测为空, 这是本方案最重要的安全垫)

对 `*.bat/*.sh/*.tcl/*.py/*.f` 搜同时含"**读/写动作**"与"文档名"的行:

```
git grep -I -nE "(open|type |copy |findstr|cat |Rewrite|WriteAll|read_text|\.read\()" \
  -- '*.bat' '*.sh' '*.tcl' '*.py' '*.f' | grep -E "<14 个名字>"
⇒ (空输出)
```

**即: 没有任何脚本把这些文档当数据读。** 全部 732 处都是**注释/散文**。
⇒ 迁移**不可能**改变任何构建产物、门判据或仿真行为。这是 §6 风险表的基线。

⚠️ **两个"像功能性依赖但其实不是"的例外, 写在这里免得后人误判:**

- `_proj_10g/notes/p7b_implicit_repro/fix_docs.py` (11 处) 与 `p7b_rollout/fix_docs2.py` (6 处):
  它们是**一次性文档改写器**, 内部有 `REPO = r"D:\repo\XCKU5PMini\udp_hls_10g"` (硬编码绝对路径)
  与 `EDITS` / `DOCS` **以裸文件名为键**的字典 (`"CLAUDE.md"` / `"PORT_NOTES.md"` / `"P7B_SPEC.md"` …)。
  **它们已经跑完, 不会再跑; 但若被重跑, 会因为键名失效而"零命中 + exit 0"** ——
  **这正是"真空门"的形态。** ⇒ 处置见 §3.4 (加 `docs/` 前缀或标注"已作废")。
- `board/wrapper_p4.v` 的 28 处是**注释**(`// ... 见 P6B_SPEC §...`), 不是 `include`。

### 2.4 非 git 层 (改不了 → 必须给处置)

| 层 | 文件 | 实测引用 | 能否版本化 | 处置 |
|---|---|---|---|---|
| **上一层 (非 git)** | `D:\repo\XCKU5PMini\CLAUDE.md` | **1 处**: **行 160** `P6B_CDC_AUDIT.md` | ❌ `git rev-parse` ⇒ `fatal: not a git repository` | 见下 |
| 上一层的邻居 | `D:\repo\XCKU5PMini\AGENTS.md` | **0 处** | ❌ 同上 | 无需动 (实测确认 0) |
| **记忆层 (非 git, 仓库外)** | `~/.claude/projects/D--repo-XCKU5PMini/memory/` **5 个文件 / 11 处** | `xcku5p-mini-10g-board.md`(`P6E_OBS.md:133`/`P6B_ACCEPT.md:154`/`P7A_SPEC.md:187`), `perfv-udp-eco-migration.md`(4), `feedback_agent_workflow.md`(2), `p4b7-p6-freeze-saga.md`(1), `udp-hls-10g-rx-byte-corruption.md`(`ISSUE_RX_BYTE_CORRUPTION.md:31`) | ❌ 仓库外 | ⚠️ **本方案新发现的第二层**, 用户原文只提到第一层 |

⭐ **对"改不了"的准确表述**: `XCKU5PMini\CLAUDE.md` **不是"改不了"而是"改了没有版本控制兜底"** ——
它是磁盘上的普通文件, 编辑当然可编辑; "改不了"指的是**这个编辑无法被 git 记录/回滚**。
两个可选处置, **推荐 A**:

- **处置 A (推荐): 直接就地改 + 把原文副本存进仓里当证据。**
  把 `XCKU5PMini/CLAUDE.md` 行 160 的 `P6B_CDC_AUDIT.md` 改为 `udp_hls_10g/docs/P6B_CDC_AUDIT.md`。
  因为它不在 git 里, **迁移报告必须把"改前 / 改后"两行逐字抄下来, 并同时把改动前的整个文件
  复制一份到 `_proj_10g/notes/evidence/` 入库** —— 这样"这次编辑"本身变成**可回滚的** (库里有一份)。
  这是本工程的既有原则 (「**报告引用的东西必须真的在库里**」) 在非 git 层上的自然延伸。
- **处置 B (若用户禁止触碰该文件): 接受悬挂 + 留 stub。**
  明确登记为**已知、已接受**的悬挂指针 (含精确行号), 并在**被迁文档的头部**加一行注记
  (见 §4 步骤 3) —— 让"知道旧路径的人"能顺藤摸到新位置。
  **不要为它造 14 个根目录 stub 文件**: 那是把根目录重新填满, 与迁移目的相悖。

### 2.5 ⚠️ "路径引用" vs "路径+行号引用" —— 必须分开处理

| 形态 | 实测 | 迁移后 | 本方案怎么动 |
|---|---|---|---|
| **纯路径** | 大部分 | 路径变 | 改路径 |
| **路径 + 行号** (`Name.md:123`) | **82 处 (已跟踪)** | **路径变, 行号不变** (纯移动不改行号) | **只改路径, 行号原样保留** |
| **路径 + 节号** (`Name §7.2`) | **98 处 (裸名)** | 路径变 | 只改路径 |

**⭐ 为什么"行号原样保留"是对的, 且必须写清楚:**

1. 纯移动(`git mv`)是**逐字节零内容变更** ⇒ **行号在物理上不变**。所以迁移**没有**制造新的过期。
2. **但这些行号里有一部分在本方案之前就已经是过期的。** 实测证据:
   - `P6B_REVIEW.md:30`: 「README 2026-09-30 结构性重写**前**为 `README.md:69,155`」
   - `_proj_10g/notes/P7B_COMMIT_PLAN2.md:170`: 「(README 2026-09-30 重写前 :287,308)」
   - 现状: `README.md` 实为 **301 行**, 而 `PORT_NOTES.md` 已 **5177 行** (`wc -l` 实测)
     ⇒ 那些指向 README 旧行号的引用**今天就已失效**。
3. ⇒ **迁移期一律不修行号。** 修行号是**内容订正**, 属于另一个任务:
   - 混在一起做, 会让"§5 负对照"失去判别力 —— 你**无法再区分**"失效是移动造成的还是订正造成的"。
   - 且行号订正**无法机械化**(必须重新定位语义)。
4. **迁移交付物里必须附一张"已知过期行号"清单**, 把上面 2 条**逐字登记**为**迁移前既存**,
   免得后人读到时错怪这次移动。**区分"路径引用"与"路径+行号引用"的全部意义就在这里**:
   前者本方案修, 后者本方案**只修路径、并把行号标为"待另案订正"**。

✅ **一个正确的例子** (本仓已有的好实践, 照抄):
`_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md:74-81` 用表格逐行登记
`PORT_NOTES.md:3357` / `P7B_SPEC.md:627` / `P6B_SPEC.md:1324` 的"旧文 → 新文"。
⇒ 迁移的**行号清单应当复用这张表的格式**。

---

## 3. 守卫与路径敏感件清单 (逐个核过)

### 3.1 逐个文件的实测结果

命令: 对每个文件套 §2.1 的正则计数 (见 §8)。

| 文件 | 是否在 `FINGERPRINT_GLOBS` | 文档引用 | 判定 |
|---|---|---|---|
| `sim/p4gates/p4gate.py` | ✅ (`sim\p4gates\*.py`) | **0** | **不改** |
| `sim/p4gates/paths.txt` | ✅ (`sim\p4gates\*.txt`) | **0** | **不改** |
| `sim/p4gates/run_matrix_p4dfix.bat` | ✅ (`sim\p4gates\*.bat`) | **0** | **不改** |
| `sim/p4gates/implicit_gate.bat` | ✅ | **0** | **不改** |
| `sim/p4gates/implicit_gate_selftest.bat` | ✅ | **0** | **不改** |
| `sim/p4gates/{chain,fifo,retx,uart,vlan}_src.f` | ✅ | **0** | **不改** |
| **`sim/p4gates/p4env.bat`** | ✅ | **1** (注释, 引 `P6B_INTEGRATION_REVIEW.md` §5) | ⚠️ **决策点, 见 §3.2** |
| `sim/p4gates/evidence/sweep_absolute_paths.txt` | ❌ (实测 `*.txt` 不跨目录) | **26** | **不改** (历史审计快照, §3.3) |
| `sim/p4gates/evidence/pre_migration_bats/run_matrix_p4dfix_OLD.sh` | ❌ | **1** | **不改** (迁移前留档) |
| `sim/p4gates/evidence/**` 其余 | ❌ | **0** | 不改 |

> ⭐ **`FINGERPRINT_GLOBS` 的解析结果是 11 个文件, 逐一实测**:
> `paths.txt` + `p4env.bat`/`implicit_gate.bat`/`implicit_gate_selftest.bat`/`run_matrix_p4dfix.bat`
> + `p4gate.py` + `chain_src.f`/`fifo_src.f`/`retx_src.f`/`uart_src.f`/`vlan_src.f`。
> 其中**没有一个是根 `.md`** ⇒ **移动文档不改指纹**(见 §3.2 但书)。
> (附带实测: `sim\p4gates\*.txt` **不匹配** `evidence/sweep_absolute_paths.txt` —— Python `glob` 的 `*` 不跨目录。
> 这条值得记下: 守卫的指纹覆盖面**比"整个目录"小**, 证据文件在**指纹之外**。)

### 3.2 ⚠️ `p4env.bat` 的两难 —— 本方案唯一真正的守卫决策

**事实:** `p4env.bat` 第 19–22 行的注释块写着
「… 见 `P6B_INTEGRATION_REVIEW.md` section 5」; 而该文件**在 `FINGERPRINT_GLOBS` 里**。

**两难:**
- 改它(插 `docs/`) ⇒ 遵守"无悬挂引用", 但**矩阵 revision DIGEST 会变** ⇒ 所有引用该 DIGEST 的历史读数
  与新一轮读数**不可直接比对**。
- 不改 ⇒ DIGEST 稳定, 但守卫文件里留一条死指针。

**推荐: 改, 并用仓里既有的指纹机制把这次变更显式化。**
- 本仓**已经有**这套流程: `sim/p4sim/P4_MATRIX_FINGERPRINT_<ts>_{before,after}.txt` 三件套实测存在
  (`20260929_234840_before` / `235056_before` / `235056_after`) ⇒ **改指纹是既有、被管理的操作**。
- 执行: ① 跑 `p4gate.py fingerprint --out ..._before.txt` → ② 改注释 → ③ 跑 `..._after.txt`
  → ④ 两份 `diff` **必须只差 `p4env.bat` 一行** (证明改动面被钉死) → ⑤ 把这对文件入库。
- ⇒ 结果: 指针不悬挂, 且"DIGEST 变过一次、只因为这一行注释"**有据可查**, 不是静默漂移。
- **备选 (若用户希望指纹零变动)**: 不改 `p4env.bat`, 把这一条列入 §7 未核实/已接受清单。

**验证"守卫还有牙"的负对照 (改动后必跑, 见 §5.2 NC-C/NC-D)** ——
守卫的牙齿**与文档路径无关**, 所以要**直接对守卫本身施加病理输入**。

### 3.3 `.gitignore` —— 三个硬阻塞里的第 3 个, 实测结论: **风险比预期低**

**实测事实:**

1. **现在没有任何规则管根 `.md`。** `grep -nE '^\*\.md|^!/?\*\.md|/README\.md|^docs' .gitignore`
   ⇒ 只有 `172:!sim/p5close/README.md` (**别的** README)。
2. **`docs/` 未被忽略**: `git check-ignore -v docs/ docs/README.md` ⇒ **无输出, exit 1** (未被忽略)。
   新目录会正常入库。
3. **10 处文档引用全在注释里** (行 225/443/448/458/479/496/512/517/548/555)。
   ⇒ **它们不参与匹配**, 改写它们是**纯文字**操作, **不可能**让任何规则反向失效。
4. **`!` 行的顺序陷阱与本次无关**: 实测 119 条 `!` 行, 各自的"最后匹配者胜"关系**只在 `sim/` `_proj_*` 等子树内**,
   且**没有任何一条涉及根 `.md` 或 `docs/`**。根文档今天**根本不被任何规则匹配**(这就是它们能被跟踪的原因)。
5. ⚠️ **但有一条必须写进纪律**: 文件**末尾那节**明写
   「⚠️ 必须放在**文件末尾**的规则 (gitignore = 最后匹配者胜)」, 最后一行是
   `audit_scratch/**/*.backup.log`。**任何编辑都必须留在注释区, 不得增删/重排任何模式行。**

**⇒ 处置 (强约束):**

- **只改注释行** (10 处), 把 `P6B_ACCEPT.md` → `docs/P6B_ACCEPT.md` 等。
- **禁止**: 新增任何 `docs/` 排除/放行规则; 移动任何 `!` 行; 把注释行改写成模式行。
- **验证**: 见 §5.2 NC-E —— `git check-ignore -v` 对一张哨兵清单**前后逐字节一致**。

> 附带风险 (低但真实): `.gitignore` 里 8 处引用是**解释"为什么放行某个文件"的论据**
> (例: `451:!p6b_accept_final/*.log` 的注释说 "P6B_ACCEPT.md §7.1 逐条登记了";
> `548` 段说 "11 个文件被 P7B_SPEC.md / notes 逐字引用")。
> 注释改错**不会**改变匹配, 但会让后人**看不懂为什么有这么一条 `!`** ⇒ 下次有人整理 `.gitignore`
> 就可能删掉它 ⇒ 几百 MB 产物入库或该入库的读数被挡掉。
> ✅ **这正是用户担心的第 3 号后果的真实触发路径**: 不是"规则反转", 而是"**理由失效 ⇒ 规则被后人误删**"。

### 3.4 "真空门"形态的路径敏感件 (必须一并处置)

| 文件 | 形态 | 处置 |
|---|---|---|
| `_proj_10g/notes/p7b_implicit_repro/fix_docs.py` | `REPO=` 硬编码绝对路径 + `EDITS` 以**裸文件名为键** (11 处) | 在文件头加一行 `⚠️ 已作废(P7b 前一次性); 若重跑, 注意 2026-09-30 后文档已迁入 docs/`。**不再修键** —— 修了反而诱导人重跑 |
| `_proj_10g/notes/p7b_rollout/fix_docs2.py` | 同上 (6 处) | 同上 |
| `_proj_10g/notes/p7b_implicit_repro/docs_apply_log.txt` | **应用日志**(11 处, 记录"对哪个文件的哪一行做了什么") | **不改** —— 是历史记录; 入 allowlist |
| `_proj_10g/notes/p7b_rollout/logs/fix_docs2_log.txt` | 日志 | **不改**; allowlist |
| `sim/p4gates/evidence/sweep_absolute_paths.txt` | **审计快照**(26 处) | **不改**; allowlist |
| `sim/p4gates/evidence/pre_migration_bats/run_matrix_p4dfix_OLD.sh` | 迁移前留档 (1 处) | **不改**; allowlist |
| `_proj_pcie/smoke_scratch/p6b_accept.log` | 证据日志 (1 处) | **不改**; allowlist |
| `sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt` (未跟踪) | 指纹快照 | **不改** |
| `_proj_10g/p7b_chain/_f2_scratch*/wrapper_p4.v` ×4 (未跟踪) | 变异副本 (112 处) | **不改** |

⇒ ⭐ **allowlist 是本方案的必要组件, 不是补丁。** 一个"零悬挂"检查器如果不懂
"**历史引文/证据快照/变异副本**"这第三类站点, 它就会**永远报红** ⇒ 然后就会被人**关掉** ⇒
又一个真空门。**检查器必须自带 allowlist, 且 allowlist 本身要有条目计数断言**(§5.1)。

---

## 4. 执行顺序 (可回滚的分步)

> 前置: **P7b 已完成并提交**; 工作树干净 (`git status --porcelain` 为空)。
> 基线记为 `${BASE}` (预期 `02d51ed` 的后继)。
> ⚠️ **当前工作树是脏的 (29 个 ` M` + 32 个 `??`) —— 不许在脏树上做本方案**, 否则移动提交会裹进 P7b 的功能改动,
> §4 步骤 2 的 `-M` 判定直接失效。

| 步 | 动作 | 不变量 (怎么验证) | 回滚 |
|---|---|---|---|
| **0** | **准备**: 记 `${BASE}`; 跑 `p4gate.py fingerprint --out sim/p4sim/P4_MATRIX_FINGERPRINT_<ts>_before.txt`; 记录根文档 `md5sum` 全表 | 指纹 before 文件生成 | 删掉该文件 |
| **1** | **纯移动**: `git mv <14 份> docs/` (先 `mkdir docs`)。**一个字节都不改** | ⭐ **`git diff --cached -M --stat` / `--name-status \| grep '^R100'` 恰好 14 行 `R100`, 且 `--numstat` 全是 `0 0`** (见 §4.1) | `git reset --hard ${BASE}` (移动**尚未 commit** 时) 或 `git reset --hard <move-commit>^` |
| **2** | **提交 ①「纯移动」** | 提交后 `git diff -M --name-status ${BASE}..HEAD` 只输出 14 行 `R100` | `git revert <move-commit>` (rename 可干净回滚) |
| **3** | **给被迁文档加头部注记** (可选但推荐): 每份文档头 1–3 行注明「2026-09-30 起本文件位于 `docs/<name>`; 旧路径 `udp_hls_10g/<name>` 已不存在」。⭐ 这条同时是**非 git 层 (§2.4) 悬挂指针的兜底** —— 按旧路径找的人若被告知, 就不会空手 | `grep -c '^> .*docs/' docs/*.md` = 14 | `git reset --hard <move-commit>` |
| **4** | **引用改写**: 用 §2.2 的正则批量改写; 分两批 (a) 已跟踪 `.md`/代码 (b) 未跟踪笔记。**跳过 §3.4 的 allowlist 清单** | 改写脚本必须**先 dry-run 出 diff**, 逐条人工过目后才 `--apply` (照抄本仓 `fix_docs.py` 的 `--apply` 惯例) | `git checkout -- <paths>` / `git reset --hard <commit3>` |
| **5** | **`.gitignore` 注释更新** (10 处) | 只动注释; `git check-ignore` 哨兵清单前后一致 (NC-E) | `git checkout -- .gitignore` |
| **6** | **守卫注释更新** (`p4env.bat`, 1 处) + 指纹 after | `diff before/after` **只差这一行** (§3.2) | `git checkout -- sim/p4gates/p4env.bat` |
| **7** | **非 git 层** (§2.4 处置 A): 备份 `XCKU5PMini/CLAUDE.md` 入库 → 改行 160 | 备份文件在库里; 改动前后两行抄进迁移报告 | 从库里的备份还原 |
| **8** | **提交 ②「引用改写 + 守卫/注释 + 非git层证据」** | 见 §5.3 | `git revert` |
| **9** | **最终验证**: §5 全套 (检查器 + 负对照 + 16 门矩阵) | 全部 PASS | 见 §6.3 |
| **10** | **push** | 推后核对 (`git log --oneline origin/master -1` 与本地一致) | — |

### 4.1 ⭐ 移动那一步的具体判据 (本方案要求的可验证不变量)

```bash
# 步骤 1 之后、提交之前 (14 份已 `git mv` 并 `git add -A -- docs *.md` 之外按需 add):
git diff --cached -M --name-status --diff-filter=R
#   期望输出: 恰好 14 行, 每行以 R100 开头, 形如
#     R100    P6B_SPEC.md    docs/P6B_SPEC.md

git diff --cached -M --numstat
#   期望: 14 行, 每行形如 "0       0       {P6B_SPEC.md => docs/P6B_SPEC.md}"

# 步骤 2 提交之后:
git diff -M --stat ${BASE}..HEAD
#   期望: 只有 rename 行; 增删行数合计 0

# 反证 (必须为空 —— 若不为空说明移动不纯):
git diff --cached -M --diff-filter=AMD
#   期望: 空输出
```

**判据解读**:
- `R100` = 相似度 100% = **零内容变更**。这是"纯移动"的**机械证明**, 不需要人读 diff。
- `--numstat` 的 `0 0` 是**冗余的第二道**: 即使 rename 检测失败退化成 `D`+`A`, `0 0` 也还在。
- ⚠️ **必须在干净树上做**: `-M` 的相似度是按内容算的, 若同一提交里夹带内容改动, 相似度会掉到 100% 以下,
  于是**"移动"与"改内容"就再也分不开了** —— 这就是 §6.2 坚持分两个提交的硬理由。

---

## 5. ⭐ 验证与负对照 (不能省)

### 5.1 怎么证明"没有引用悬空"

**本工程的硬规矩是「报告引用的东西必须真的在库里」。本次把它机械化:**

**新增检查器 `tools/check_docrefs.py`** (位置理由: `tools/` 内只有
`gen_stim_p4_chain.py` / `gen_stim_tcp_p4_chain.py` 两文件在 `FINGERPRINT_GLOBS` 里,
**新增第三个 `.py` 不进入指纹** ⇒ 不扰动 §3.2 的 DIGEST)。

**它必须做 4 件事 (缺一不可):**

1. **枚举** 全仓 (tracked + untracked, 排除 `.git/` `xsim.dir/` 与二进制) 中所有形如
   `<NAME>(\.md)?` 的**根相对裸名**引用 (用 §2.2 的 lookbehind 正则, 复用同一张 14 名表)。
2. **分类**每个命中站点: `LIVE` (活指针) / `HISTORICAL` (历史引文/证据快照/变异副本) / `FOREIGN` (外仓, 如 `udp_hls_eco/PORT_NOTES.md`)。
3. **解析** `LIVE` 站点: 该路径**必须存在**于工作树。不存在 ⇒ **非零退出 + 打印文件名:行号 + 那个裸名**。
   `FOREIGN` 站点 ⇒ 必须仍**带**路径前缀 (防止有人把外仓引用"归一化"成本仓引用)。
4. ⭐ **自检断言 (反真空门)**: 打印并断言
   - 扫过的文件数 ≥ 某阈值 (防止"扫了 0 个文件, 于是 0 个悬挂, exit 0");
   - 解析到的 `LIVE` 引用数 ≥ 某阈值 (期望量级: 数百);
   - `HISTORICAL` allowlist 条目数与**硬编码**清单**逐条对账** (allowlist 不许静默长大 ——
     它是本检查器**唯一**的自证盲区, 必须钉死)。

**验收判据 (迁移后):**

| 指标 | 期望 |
|---|---|
| `LIVE` 悬空数 | **0** |
| `HISTORICAL` 条目数 | = 硬编码清单条数 (逐条相等, 不是"≤") |
| 非 git 层悬挂 | **1 条, 且与 §2.4 登记的行号逐字一致** (若走处置 A 则为 **0**) |
| 扫过文件数 / `LIVE` 引用数 | **必须打印出来**, 并与迁移前的基线**同量级** |

### 5.2 ⭐ 负对照 (每一道牙都要被证明还会咬)

**原则: 负对照必须是"能把检查器/守卫弄响的病理输入", 且必须在同一轮里看到它响。**

| NC | 做法 | 必须观察到 | 复原 |
|---|---|---|---|
| **NC-A 悬挂引用 (主判据)** | 造一个**真的**悬挂: 临时把 `docs/P6B_SUMMARY.md` 改名成 `docs/P6B_SUMMARY.md.bak`, 跑检查器 | 检查器**非零退出**, 且输出**点名 `docs/P6B_SUMMARY.md` + 至少一个引用它的文件:行号** —— 只报 "found dangling refs" 而**不点名**的, 判为**不合格**(无法定位) | 改回 |
| **NC-A2 假引用** | 在某个笔记里临时写一行 `见 P6B_SPEC_MISSING.md` | 检查器非零退出 (证明它是**真的去查文件系统**, 而不是"照着一张预置名单比对") | 删该行 |
| **NC-B 检查器不空跑** | 对**空目录** 跑检查器 (或用 `--root` 指向空目录) | 因 §5.1(4) 的自检断言而**失败** (而不是"0 个对象 ⇒ 通过") | — |
| **NC-C 守卫根推导** | `set P4_REPO_ROOT=D:\repo\ECO\udp_hls_10g` 后跑 `p4env.bat` | `[P4GUARD FAIL] REFUSING to run: ... 该 root 不包含本脚本所在 checkout` + **exit 1** | 取消该环境变量 |
| **NC-D 守卫 manifest 漂移** | 临时往 `sim/p4gates/chain_src.f` 追加一行注释/假文件 | `p4gate.py manifestcheck` **FAIL** | `git checkout -- sim/p4gates/chain_src.f` |
| **NC-E `.gitignore` 语义未变** | 迁移**前**对一张哨兵清单逐条 `git check-ignore -v` 存档; 迁移**后**对**同一清单**再跑 | 两份输出**逐字节相同**。哨兵须含: ①**本应被忽略**者 (如一个 `*.backup.log`、`*.dcp`); ②**本应放行**者 (如 `_p7a_probe/*_stdout.txt`、`p6b_accept_final/*.log`、`sim/p4sim/matrix_p4dfix.log`); ③`docs/` 及其内容 (**应输出空 = 未忽略**) | — |
| **NC-F 指纹改动面** | §3.2 的 `before`/`after` 两份指纹 | `diff` **只差 `p4env.bat` 那一行** | — |

> ⚠️ **NC-A 的替代做法 (若不愿碰库)**: 在一个 `_scratch/` 副本里做全套。但**不推荐** ——
> 本工程的"真空门"事故恰恰是"在**副本**上跑得很好、在**真库**上悄无声息"。
> **负对照必须在真库上做, 且做完必须复原并 `git status` 确认零残留。**

### 5.3 迁移后要重跑的门

| # | 命令 | 退出码约定 | 期望 |
|---|---|---|---|
| 1 | `cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'` | `0` 全过 / `1` 有失败 / `2` 源码漂移 / `97` 前置拒绝 | **`0`** |
| 2 | `p4gate.py checkpaths` / `manifestcheck` / `scanlog` / `fingerprint` | 非零 = 失败 | 全 OK |
| 3 | `tools/check_docrefs.py` | 非零 = 有悬挂 | **0** |

⚠️ **跑门 ≠ 判门 (实测确认, 不是听说):** `sim/retxsim/run_retx_tb.bat` 与
`sim/retxsim2/run_tb_frame_fifo.bat` 的**最后一条语句**分别是 `type xsim.log` / `type xsim_ff.log`,
**之后没有 `exit /b N`** ⇒ 批处理**自然落空到 0**。
它们对**编译/xelab 失败**和**隐式网**是有牙的 (`|| exit /b 1` + `findstr ... IMPLICIT-DECL-FAIL`),
但**xsim 断言失败不会传播到退出码**。
⇒ **`unit_retx` / `unit_fifo` 两门必须读日志尾**(`xsim.log` / `xsim_ff.log` 里的 PASS/FAIL 与断言计数),
**不得只看退出码**。这是"跑了很久 ≠ 跑对了"在本仓的具体形态。

---

## 6. 风险与回滚

### 6.1 风险表

| # | 风险 | 等级 | 缓解 | 回滚 |
|---|---|---|---|---|
| **R1** | ⭐ **改写把"历史读数/逐字引文"一并改了 ⇒ 伪造证据。** 本仓大量引用是"**当时读到的值**"(例: `P6B_REVIEW.md:30` 记 README 旧行号; `PORT_NOTES.md:4677-4686`「原 README.md:1-5」逐字保留; `sweep_absolute_paths.txt` 是审计快照)。改这些**不是修引用, 是篡改记录** | **高** | §3.4 的 allowlist + §5.1 检查器**分类**而非盲目替换; 改写脚本 **dry-run 必须先人工过目** | `git reset --hard <commit3>` |
| **R2** | 改写正则少了 lookbehind ⇒ **改坏外仓/别的 README** (`udp_hls_eco/PORT_NOTES.md` ×3 等) | 中 | §2.2 规则; 改写脚本**内置反例自测** (跑之前先断言这 3 + 6 个站点**不被命中**) | `git checkout --` 受影响文件 |
| **R3** | ⚠️ **漏掉裸名引用 (296 处, 占 40%)** | **高** | 正则必须**同时**匹配 `.md` 与裸名 (§2.1); 交付物给出"436 (`\.md`) + 296 (裸名) = 732"的**两层计数对账** | 补跑 |
| **R4** | ⚠️ **`.gitignore` 注释改了但理由链断了 ⇒ 后人误删 `!` 行 ⇒ 几百 MB 产物入库 / 读数被挡** | 中 | §3.3: 只改注释; NC-E 哨兵清单; 注释里保留"为什么"的全句, 只把文件名加 `docs/` 前缀 | `git checkout -- .gitignore` |
| **R5** | `p4env.bat` 注释一改 ⇒ 指纹 DIGEST 变 ⇒ 与历史读数不可比 | 低 | §3.2: before/after 三件套 + 入库 | `git checkout --` |
| **R6** | **非 git 层 (`XCKU5PMini/CLAUDE.md`) 悬挂** | 低 | §2.4 处置 A (就地改 + 备份入库) | 从库内备份还原 |
| **R7** | **记忆层 (`~/.claude/.../memory/`) 悬挂** — 5 文件 11 处 | 低 | 记忆层是**跨会话指令**, 不属仓库交付物 ⇒ 登记为已知, 由**用户**决定是否更新 (本方案不动它) | — |
| **R8** | **在脏树上执行** ⇒ 移动提交裹进 P7b 功能改动 ⇒ `-M` 判定失效 | 中 | §4 前置: 树必须干净 | 拆提交 |
| **R9** | 检查器**自己**变成真空门 (扫 0 个文件 / allowlist 无限长) | 中 | §5.1(4) 自检断言 + NC-B | — |
| **R10** | `docs/` 里新建的索引/注记被既有宽规则误挡 (或误放行) | 低 | 已实测 `git check-ignore -v docs/` = 未忽略; NC-E 哨兵含 `docs/` | — |

### 6.2 ⭐ 提交策略: 「纯移动」与「本阶段功能改动」必须分成两个提交

**理由 (三条, 都是可机械验证的):**

1. **`-M` 只在纯提交上有判别力。** rename 检测按内容相似度算 —— 混入任何内容改动, 相似度掉下 100%,
   于是**"这是移动"与"这是改动"就永久不可分离**。分两个提交 ⇒ 移动那个提交可以被**独立**证明为 `R100`。
2. **回滚粒度不同。** 移动出问题 ⇒ 只想撤移动 (14 个 rename), 不想撤 P7b 的功能修复 (RTL/门/TB)。
   混在一起 ⇒ 只能整批撤。
3. ⭐ **本仓的分裂状态正是这个风险本身**: `git status` 实测 **29 个 ` M`** 全是 P7b 的功能改动
   (`rtl/rx_classify.v`、`board/wrapper_p4.v`、`sim/p4gates/...` 等), 而 `board/wrapper_p4.v`
   **同时**是文档引用最多的代码文件 (28 处)。⇒ 若不分两个提交, "wrapper_p4.v 的文档注释改写" 与
   "wrapper_p4.v 的 P7b 逻辑改动"**必然同批**, `-M` 判据当场作废。

**命令 (执行时):**

```bash
# 提交 ①  纯移动
git add -A -- docs
git add -A -- ':(glob)*.md'          # 14 份删除侧; 用显式 pathspec, 绝不 `git add -A`
git commit -m "文档迁移① 纯移动: 14 份根文档 -> docs/ (零内容变更)"
git diff -M --name-status HEAD^..HEAD      # 期望: 14 行 R100, 无 A/M/D

# 提交 ②  引用改写 + 守卫注释 + 非 git 层证据
git commit -m "文档迁移② 引用改写: 732 处 -> docs/ + .gitignore 注释 + p4env.bat 注释 + 非git层备份"

# 推后核对
git log --oneline -1 && git log --oneline origin/master -1
```

> ⚠️ 纪律 (本仓既有): **绝不 `git add -A`** 无 pathspec; git 身份用 `-c` 指定、**绝不改 config**;
> 显式 refspec + 推后核对。

### 6.3 回滚总闸

| 阶段 | 回滚 |
|---|---|
| 改动未提交 | `git reset --hard ${BASE}` (注意: 会丢 P7b 未提交改动 ⇒ 所以 §4 要求先提交 P7b) |
| 提交①后 | `git revert <c1>` (rename 干净可逆) 或 `git reset --hard ${BASE}` |
| 提交②后 | `git revert <c2>`; 非 git 层从库内备份还原 |
| 已 push | `git revert` 两次 + 重跑 §5 全套 (不要 `push --force`) |

---

## 7. 未核实清单

| # | 未核实项 | 为什么没核 | 怎么核 |
|---|---|---|---|
| U1 | `XCKU5PMini/CLAUDE.md` 行 160 之外是否还有**间接**引用 (如"见 udp_hls_10g 下的 P6B_CDC_AUDIT") | 只 grep 了 14 个精确名; 未做语义扫描 | 人工通读该文件 |
| U2 | **记忆层 5 文件 11 处**是否要改 | 不属仓库交付物; 需用户决定 | 用户裁决 |
| U3 | **未跟踪文件里是否有二进制/大文件**含文档名 (我按 `\0` 前 8 KB 判二进制而跳过) | 跳过是保守的, 可能漏 | 对全部 259 个未跟踪文件逐个 `file` |
| U4 | `sim/p4gates/evidence/sweep_absolute_paths.txt` 的 26 处是否**每一处**都是历史记录 (我抽查了头部, 判全体为审计快照) | 2209 行未逐行读 | 逐行过目 |
| U5 | `HISTORICAL` allowlist 的**完整**条目清单 (本方案给了类别与已知文件, 未给逐条行号) | 属执行期产物 | 执行期由 dry-run 生成, 人工过目 |
| U6 | 69 处**"裸名+§"**是否全部是"根相对约定"而非某种别的东西 | 抽验了代表性样本 | 执行期 dry-run 全量过目 |
| U7 | 那些**已过期行号**的完整清单 (本方案只钉死 3 条 README 相关) | 需逐条重定位 | 另案 |
| U8 | `docs/` 建好后 **Windows 路径长度 / 大小写** 是否引入新问题 | 未测 | 移动后 `git status` 确认 |
| U9 | `int_scratch/negbase/axi_regs.v` 与 `neg5/axi_regs.v` (各 2 处) 是"负对照副本", 改不改 | 分类判断 | **建议不改** (它们是病理输入的留档), 但需确认 |
| U10 | `p6b_final_verify/cdc_parsed.txt` (1 处) 是生成物还是输入 | 未读其生成脚本 | 读 `cdc_parse.py` 确认能否再生 |

---

## 8. 度量复现命令 (全部只读, 本次即用这些)

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g

# 待挪清单 (16 份根 .md, 去掉 README/CLAUDE = 14)
git ls-files -- '*.md' | grep '^[^/]*$'

# 总量 (14 名, 含 .md 与裸名; lookbehind 排除路径前缀)
MOVED='PORT_NOTES|P6B_ACCEPT|P6B_CDC_AUDIT|P6B_COMMIT_PLAN|P6B_INTEGRATION_REVIEW|P6B_REVIEW|P6B_SPEC|P6B_SUMMARY|P6E_OBS|P7A_COMMIT_PLAN|P7A_RESULT|P7A_SPEC|P7B_SPEC|ISSUE_RX_BYTE_CORRUPTION'
git grep -I -o -P "(?<![A-Za-z0-9_./\\\\-])($MOVED)(\.md)?(?![A-Za-z0-9_.-])" | wc -l   # 732
git grep -I -o -P "(?<![A-Za-z0-9_./\\\\-])($MOVED)\.md"          | wc -l   # 436 (.md 形式)
# 带 :行号 的
git grep -I -oP "($MOVED)\.md:[0-9]+" | wc -l                     # 82

# 守卫逐文件
for f in sim/p4gates/p4gate.py sim/p4gates/paths.txt sim/p4gates/run_matrix_p4dfix.bat \
         sim/p4gates/p4env.bat sim/p4gates/implicit_gate.bat \
         sim/p4gates/evidence/sweep_absolute_paths.txt; do
  echo "$f: $(grep -IocP "(?<![A-Za-z0-9_./-])($MOVED)(\.md)?" "$f")"
done

# FINGERPRINT_GLOBS 实际解析出的文件 (必须复现 "11 个, 无根 .md")
"C:/Users/zhxue/anaconda3/python.exe" -c "
import glob,os
r=r'D:\repo\XCKU5PMini\udp_hls_10g'
for g in ['sim\\\\p4gates\\\\*.txt','sim\\\\p4gates\\\\*.bat','sim\\\\p4gates\\\\*.py','sim\\\\p4gates\\\\*.f']:
    print(g,[os.path.relpath(p,r) for p in sorted(glob.glob(os.path.join(r,g)))])

# docs/ 未被忽略 (期望: 无输出, exit 1)
git check-ignore -v docs/ docs/README.md

# 非 git 层
grep -noP "(?<![A-Za-z0-9_./-])($MOVED)(\.md)?" /d/repo/XCKU5PMini/CLAUDE.md     # 只有 1 处
grep -rnoP "(?<![A-Za-z0-9_./-])($MOVED)(\.md)?" \
  "/c/Users/zhxue/.claude/projects/D--repo-XCKU5PMini/memory/"                   # 11 处 / 5 文件

# 零功能性依赖 (期望空)
git grep -I -nE "(open|type |copy |findstr|cat |Rewrite|read_text|\.read\()" \
  -- '*.bat' '*.sh' '*.tcl' '*.py' '*.f' | grep -E "$MOVED"
```

---

## 附: 待用户裁决的 4 个决策点

1. **非 git 层走处置 A (就地改 + 备份入库) 还是 B (接受悬挂 + 头部注记)?** —— 推荐 **A**。
2. **`p4env.bat` 那 1 处注释改不改?** (改 ⇒ 指纹 DIGEST 变一次) —— 推荐 **改 + 指纹三件套入库**。
3. **`int_scratch/neg*` 副本与 `p7b_chain/_f2_scratch*/wrapper_p4.v` 是否放行?** —— 推荐 **放行 (不改)**。
4. **索引文件要不要?** (`docs/INDEX.md`) —— 推荐 **要**, 但**不叫** `docs/README.md`。
