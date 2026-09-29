# P7A_COMMIT_PLAN — P7a 归档：**提交方案**（本文件只出方案，**未执行任何 git 操作**）

> 归档 agent 于 2026-09-29 写。**没有 `add` / `commit` / `push`**（TL 统一提交）。
> 所有清单都是**现算的**（`git status --porcelain -uall` + `git check-ignore -v` 逐条核实），
> 不是从别处抄的。基线：`HEAD = 8e92a56`（`master`，与 `origin/master` 同步）。

## 0. 铁律与前置（**先读**）

1. **绝不 `git add -A` / `git add .`** —— 本工程铁律。**逐条列路径**（本文所有清单都可直接粘）。
2. **提交身份用 `-c` 指定，绝不改 config**（本工程铁律）：
   `git -c user.name=zhxue -c user.email=zhxue@localhost commit ...`
3. **提交信息用中文**，末尾带 `Co-Authored-By: Claude Code <noreply@anthropic.com>`（与本仓近三条一致）。
4. **顺序不可换：C0(.gitignore) 必须先于 C1/C2**。
   ⚠️ 本轮有个具体后果：`_proj_10g/reports/*.log`、`board_scratch/logs/*.log`、`ctrl_scratch/logs/*.log`
   都在**全局 `*.log`** 规则下 —— 本方案**不放行它们**（理由见 §4.3），但如果 TL 决定放行，
   那条 `!` 规则必须在 `git add` **之前**就位；否则 `git add` 对忽略路径**静默不加**，
   提交会缺文件而不报错（"空门"家族的又一形态）。
5. **不 push**（本文不含 push 步骤；TL 决定何时推）。
6. ⚠️ **`_tmp_*.py`（11 个）不是本轮的**：`P6B_COMMIT_PLAN.md` §4.2 已裁决"不提交（留盘）"，
   **本轮沿用**，别顺手带上（清单见 §5.1）。

## 1. 变更全貌（本轮 P7a 只新增 + 改三份文档）

```
$ git status --porcelain -unormal | grep -v '^?? _proj_10g/\|^?? _p7a_probe/'
 M PORT_NOTES.md          <- 本轮追加 "2026-09-29 P7a" 一节
 M README.md              <- 本轮: 状态块一句 + 里程碑表 P7a 行 + 归档索引两行
?? P7A_RESULT.md          <- 本轮新增（板级验收原件）
?? P7A_SPEC.md            <- P7a 施工规格（既有，本轮未改一字）
?? _proj_10g/             <- 本轮新增（设计/门/脚本/原始读数；125 MB，其中 ~123 MB 是产物）
?? _p7a_probe/            <- 本轮新增（工具核实探针工程；17 MB，其中 ~16.7 MB 是产物）
?? _tmp_*.py  (11 个)     <- **不是本轮的**，见 §0.6
```

`_proj_10g/` 的体积构成（`du -sh`）与去向：

| 子目录 | 体积 | 去向 |
|---|---|---|
| `vivado_prj/` | 60 M | ❌ 已被全局 `vivado_prj/` 规则排除（位流/`.ltx`/`.dcp`/构建日志都在里面） |
| `lic_deny_ctrl_prj/` | 38 M | ❌ 新增规则排除（license 负对照的 Vivado 工程，含厂商生成的 IP HDL） |
| `ctrl_scratch/` | 16 M | ⚠️ 其中 **15.4 M 是 iBERT 对照件 `.bit`**（已被全局 `*.bit` 排除）；**文本部分入 C1/C2** |
| `reports/` | 6.7 M | ⚠️ 其中 **3.6 M 是 `p7a_post_route_netlist.v`**（建议排除，见 §4.4）；其余入 C2 |
| `lic_deny_prj/` | 3.8 M | ❌ 新增规则排除（同上） |
| `sim/` | 653 K | ⚠️ 绝大部分是 `xsim.dir/`（全局排除）；5 个文本文件入 C1 |
| `board_scratch/` | 531 K | ✅ 脚本入 C1、读数入 C2 |
| `tcl/` `rtl/` `xdc/` `obs/` | 350 K | ✅ 入 C1（`probe_xdc_prj/` 与 `lint/files.f` 除外） |

**净入库量 ≈ 2 MB**（不含 `p7a_post_route_netlist.v`）。

## 2. 切分总览（**3 条提交**）

| # | 主题 | 文件数（现有清单） | 依赖 |
|---|---|---|---|
| **C0** | `.gitignore`：P7a 的排除规则 + `_p7a_probe` 的 4 条放行 | 1 | 必须最先（放行规则先于 `add`） |
| **C1** | `_proj_10g/` 的**设计 + 门 + 脚本 + 规格**（+ 单元门读数 + `_p7a_probe` 工具核实读数） | 67 | 需 C0 先落地（`_p7a_probe/*` 否则被 `add` 静默忽略） |
| **C2** | **板级证据 + 文档**（全部原始读数 + `P7A_RESULT.md` + README + PORT_NOTES + 本文件） | 36 | 需 C1（读数要引用设计文件） |

**为什么不是 2 条**：证据批里 `_proj_10g/reports/` 与 `*_scratch/logs/` 是"跨阶段汇总"，
与"设计/门"分开后 `git log` 一眼能看出"哪些是设计、哪些是量出来的"；
且本仓既有做法里 P6b 也是把证据单独切了一条（C7 证据归档批）。
**为什么不切更多**：本轮只有一次验收、一个位流，再细切会让"P7a = 一个里程碑"这件事在历史里碎掉。

## 3. 逐条提交：显式清单 + 提交信息

### C0 — `.gitignore`

```bash
git add -- .gitignore
```

**改动内容**（**纯排除，无 `!` 放行** —— 见 §4 的核实结论）：

```gitignore
# ============================================================================
# P7a (2026-09-29): 10G PCS/PMA 板级验收 —— `_proj_10g/` 入库, 只排除"工程/生成物"
#
# 实测体积: `_proj_10g/` 125 MB 里 ~123 MB 是产物 (60M 构建工程 + 42M 两个 license
#   负对照工程 + 15.4M iBERT 对照件位流[已被全局 *.bit 覆盖] + 3.6M 网表转储);
#   **设计(RTL/XDC/脚本) + 门 + 全部原始读数 ≈ 2 MB, 全部入库**(本工程靠文本证据存档)。
# `_p7a_probe/` 17 MB 同理: 只留 P7A_SPEC §1 逐字引用的那批文本读数 (324 KB)。
# ============================================================================

# ---- license 负对照的两个 Vivado 工程 (可重建: _proj_10g/tcl/lic_deny_p7a.tcl;
#      且含厂商生成的 IP HDL, 不宜入库。*读数*在 reports/p7a_lic_deny_stdout.txt) ----
_proj_10g/lic_deny_prj/
_proj_10g/lic_deny_ctrl_prj/

# ---- XDC 子集缺陷的最小复现工程 (可重建: tcl/xdc_cmd_support_probe.tcl;
#      证据 = 它自己的 stdout: reports/p7a_xdc_probe_stdout.txt) ----
_proj_10g/tcl/probe_xdc_prj/

# ---- lint 工作目录: 只留读数 xvlog.txt (P7A 门 summary §[B] 的原始出处) ----
#      (*.log / *.pb / xsim.dir/ 已被更早的全局规则覆盖 ⇒ 这里只需挡 files.f)
_proj_10g/tcl/lint/files.f

# ---- 探针描述文件 (.ltx): 本工程不跟踪位流, 而 .ltx 只是某个位流的探针表 ⇒ 一并排除。
#      实测现库中 0 个已跟踪 .ltx; 位流/探针的身份以 sha256 记在 P7A_RESULT.md §6.1 ----
*.ltx

# ---- 布局后网表转储 (3.6 MB, readback tcl 的副产物): 判据读数已逐字归档在
#      reports/p7a_readback.txt §[1]/§[1c]。若 TL 要连 netlist 留档, 加 `!` 放行 ----
_proj_10g/reports/p7a_post_route_netlist.v

# ---- P7a 工具核实的一次性探针工程: 三个 Vivado 工程 + 两个网表转储 = 17 MB 的主体 ----
_p7a_probe/.Xil/
_p7a_probe/pj_fin/
_p7a_probe/rb_pos/
_p7a_probe/rb_raw/
_p7a_probe/nl_pos.v
_p7a_probe/nl_raw.v
_p7a_probe/*.log
_p7a_probe/*.jou
#   ⭐ 放行 P7A_SPEC §1.1/§1.2/§1.3/§10 逐字引用的**文本读数**(合计 324 KB):
#      *_stdout.txt      = 每轮探针的 stdout (已核实 §1 的每一条引用都能在其中找到:
#                          p1_stdout.txt:160 = TX_PROTOCOL 不存在; p2_stdout.txt:253 = 12-4371;
#                          p1_stdout.txt 6 处 IPDEF/USED_LICENSE_KEYS; p5_stdout.txt 2 处)
#      *.tcl / run_p*.bat= 探针脚本本身 (可复跑)
#      clockInfo.txt     = 时钟读数
#   ⚠️ 这一条与 P7A_SPEC §10 的 "不进 git" 有冲突 —— 见本文 §6.2 (建议一并改 §10 一句话)
!_p7a_probe/*_stdout.txt
!_p7a_probe/*.tcl
!_p7a_probe/run_p*.bat
!_p7a_probe/clockInfo.txt
```

**提交信息**：

```
gitignore: P7a 归档的排除规则 (license 负对照工程 / 探针工程 / *.ltx / 网表转储)

本轮 P7a 归档新增两块工作区:
- `_proj_10g/` 125 MB (设计 + 门 + 脚本 + 全部原始读数; ~123 MB 是产物)
- `_p7a_probe/` 17 MB (工具核实探针: 三个 Vivado 工程 + 两个网表转储)

本提交只加**排除**规则, 一条 `!` 放行都没有 —— 原因是**已核实**(`git check-ignore -v`
逐条跑过)要入库的每一份文本读数**当前都不被任何规则挡住**, 所以不需要放行;
真正需要挡的是上面那几类**工程目录/生成物**。

⚠️ 两条与既有策略一致的取舍 (都写在规则注释里):
- `*.ltx`: 本工程不跟踪位流, 而 .ltx 只是某个位流的探针表 ⇒ 一并排除
  (实测现库中 0 个已跟踪 .ltx)。位流与探针的身份以 sha256 记在 P7A_RESULT.md §6.1。
- `_proj_10g/reports/p7a_post_route_netlist.v` (3.6 MB): readback tcl 的副产物,
  判据读数已逐字归档在 reports/p7a_readback.txt §[1]/§[1c] ⇒ 不重复入库。

Co-Authored-By: Claude Code <noreply@anthropic.com>
```

### C1 — `_proj_10g/` 的设计 + 门 + 脚本 + 规格

```bash
git add -- P7A_SPEC.md \
  _proj_10g/rtl/clk_gen_p6b.v \
  _proj_10g/rtl/gt_10gbr_example_checking_64b66b_async.v \
  _proj_10g/rtl/gt_10gbr_example_reset_sync.v \
  _proj_10g/rtl/gt_10gbr_example_stimulus_64b66b_async.v \
  _proj_10g/rtl/gt_10gbr_prbs_any.v \
  _proj_10g/rtl/p7a_bit_sync.v \
  _proj_10g/rtl/p7a_counters.v \
  _proj_10g/rtl/p7a_ref_bucket.v \
  _proj_10g/rtl/p7a_tgl_sync.v \
  _proj_10g/rtl/p7a_top.v \
  _proj_10g/rtl/p7a_vio_ctrl.v \
  _proj_10g/xdc/ku5p_p7a.xdc \
  _proj_10g/xdc/ku5p_p7a_impl.xdc \
  _proj_10g/tcl/build_p7a.tcl \
  _proj_10g/tcl/readback_p7a.tcl \
  _proj_10g/tcl/lic_deny_p7a.tcl \
  _proj_10g/tcl/xdc_cmd_support_probe.tcl \
  _proj_10g/tcl/run_build_p7a.bat \
  _proj_10g/tcl/run_readback_p7a.bat \
  _proj_10g/tcl/run_lint_p7a.bat \
  _proj_10g/tcl/run_lic_deny_p7a.bat \
  _proj_10g/tcl/run_xdc_probe.bat \
  _proj_10g/tcl/lint/xvlog.txt \
  _proj_10g/sim/tb_p7a_counters.v \
  _proj_10g/sim/run_tb_p7a_counters.bat \
  _proj_10g/sim/xvlog.txt \
  _proj_10g/sim/xelab.txt \
  _proj_10g/sim/xsim_run.txt \
  _proj_10g/obs/probe_p7a.tcl \
  _proj_10g/obs/run_probe_p7a.bat \
  _proj_10g/board_scratch/probe_p7a_board.tcl \
  _proj_10g/board_scratch/read_state_only.tcl \
  _proj_10g/board_scratch/diag_slip.tcl \
  _proj_10g/board_scratch/dryrun_stub.tcl \
  _proj_10g/board_scratch/run_probe_p7a_board.bat \
  _proj_10g/board_scratch/run_read_state_only.bat \
  _proj_10g/board_scratch/run_diag_slip.bat \
  _proj_10g/ctrl_scratch/ctrl_ibert_v3.tcl \
  _proj_10g/ctrl_scratch/extra_gate_diag.tcl \
  _proj_10g/ctrl_scratch/reflash_p7a.tcl \
  _proj_10g/ctrl_scratch/m8_v3_confirm.tcl.ref \
  _proj_10g/ctrl_scratch/run_ctrl_ibert_v3.bat \
  _proj_10g/ctrl_scratch/run_extra_gate_diag.bat \
  _proj_10g/ctrl_scratch/run_reflash_p7a.bat \
  _p7a_probe/clockInfo.txt \
  _p7a_probe/p1_stdout.txt \
  _p7a_probe/p2_stdout.txt \
  _p7a_probe/p3_stdout.txt \
  _p7a_probe/p4_stdout.txt \
  _p7a_probe/p5_stdout.txt \
  _p7a_probe/p6_stdout.txt \
  _p7a_probe/p7_stdout.txt \
  _p7a_probe/p1_wizard.tcl \
  _p7a_probe/p2_wizard.tcl \
  _p7a_probe/p3_wizard.tcl \
  _p7a_probe/p4_matrix.tcl \
  _p7a_probe/p5_final.tcl \
  _p7a_probe/p6_readback.tcl \
  _p7a_probe/p7_readback2.tcl \
  _p7a_probe/run_p1.bat \
  _p7a_probe/run_p2.bat \
  _p7a_probe/run_p3.bat \
  _p7a_probe/run_p4.bat \
  _p7a_probe/run_p5.bat \
  _p7a_probe/run_p6.bat \
  _p7a_probe/run_p7.bat
```

> ⚠️ **最后那 22 个 `_p7a_probe/*` 文件必须显式列出**：C0 的 `!` 放行只是"解除忽略"，
> **不会**把它们加进索引 —— 不列就是"放行了但没人加"，`P7A_SPEC.md` §1.1/§1.2/§1.3 的引用照样悬空
> （这正是本工程反复踩的"静默不生效"家族）。

**提交信息**：

```
P7a: 10G PCS/PMA (含 64b/66b gearbox) 的设计 + 门 + 施工规格 (KU5P quad225 X0Y4/X0Y5)

P7a 的目标是补上 09-27 iBERT 轮留下的最大空白: 那一轮 `TXGEARBOX_EN=FALSE`、GT 跑 raw
⇒ **PCS/gearbox 一层没有任何证据**。本轮用 gtwizard(10GBASE-R, 64-bit, 2ch) + 自写外壳,
在 SFP A↔SFP B 的 AOC 外部环回上把这一层做成可判的。

设计 (rtl/):
- `p7a_top.v`: 两通道 10GBASE-R (64B66B_ASYNC / 10.3125 GBd / QPLL0 / 156.25MHz refclk),
  PRBS31 自发自收; 观测时钟 = 核心板 Y1 100MHz 经 MMCM → 156.25MHz (与 GT 配置**无关**),
  专为"gearbox 比率判据"服务; SFP TX_DIS 按**实测**引脚(C11/D9)恒低。
- `p7a_counters.v`: 自写 BER 计数器 + **原子快照**。不用 example 的 `link_status_out`
  —— 它是漏桶(一次错只扣 34/67 ⇒ 容忍孤立错误, "看着干净"≠零误码);
  计数语义可复算: `err_word_cnt`/`bits_cnt`/`hdrs_cnt`/`hdre_cnt`, 只在 `acq` 后计数
  ⇒ `bits_cnt>0` 自带正对照, "0 错"不会是真空 0。
- `p7a_vio_ctrl.v` / `p7a_bit_sync.v` / `p7a_tgl_sync.v` / `p7a_ref_bucket.v`: VIO 窗口、
  跨域同步与自由运行参考桶; `clk_gen_p6b.v` 复用 P6b 的 MMCM 封装。
- `gt_10gbr_*`: wizard `generate_target example` 出的 PRBS31 三件套(当零件用)。

门与判据 (tcl/ sim/ board_scratch/ obs/ ctrl_scratch/):
- `sim/tb_p7a_counters.v` 单元门: **437 checks / 0 failures**, 含
  撕裂负对照 200 违例 / 比率判据双向(156.25→1.000000, 161.1328125→1.031252)
  ⇒ 判据本身有判别力; 读数 `sim/xsim_run.txt`。
- `tcl/run_lint_p7a.bat`: elaboration 级 lint(隐式网签名 `Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989` / 位宽 / ERROR 硬失败; **2026-09-29 追加 xelab 面** (p7a_top 的端口连接形式 xvlog 全静默; 用 gt_10gbr 的 synth+hdl 源 + vio_p7a_stub.v, `-L unisims_ver -L secureip`, ~24 s; IP 未生成时 exit 97))。
  ⚠️ **2026-09-29 订正 (P7B 实测)**: Vivado 2025.2 **不再打印 `implicitly declared`** (实测全部日志命中 0) ⇒ 旧关键字是**哑门**。Vivado 2025.2 的真实签名分两种形态、**两个不同检测点**: ① 端口连接形式 (静默截断) —— **xvlog 一个字都不打印** (exit 0、日志全空, `-sv` 也一样), 只有 `xelab` 报 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`, 或 `synth_design` 报 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`; ② 表达式形式 —— `xvlog` 报 `ERROR: [VRFC 10-2989] '<name>' is not declared` (synth 用 `8-36`)。⇒ **只 grep xvlog 日志的门结构性地拓不到本坑 —— 换任何关键字都不行, 必须补 `xelab`/`synth_design` 这一面** (现役两处 lint 入口 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat` 已补, 各 +12 s / +24 s)。 **推荐键表 (5 键, OR 语义)**: `Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared` (末者只为 2025.2 之前的工具保留, 在 2025.2 下恒 0)。 ⚠️ **`10-3091` 必须带上 `] actual bit length 1 differs from formal bit length`**: 裸 `VRFC 10-3091` 会命中 `board/util_gmii_to_rgmii.v` 的 **14 处良性 unsized 字面量** (`.CE(1)`/`.D1(1)`/`.D2(0)`/`.R(0)`/`.S(0)`, 报 `actual bit length 32 differs from formal bit length 1`) —— 默认 (K7) 配置每次 xelab 都报, 当硬失败就是天天误伤。隐式网**必然是 1 位** ⇒ "actual = 1" 就是本坑的精确签名 (收窄后仍抓住病理件 A1)。 **刻意排除的键 (都有实测假阳性)**: `8-7129`/`unconnected or has no load` (命中干净件的**合法未用端口**)、`8-6014`/`8-3917` (纯优化提示)、`VRFC 10-3645`/`remains unconnected` (xelab 侧对偶 —— 干净的真实 P6e 设计一跑就 **20 条**)。 ⚠️ **裸 `findstr /C:"10-3091"` 那一族"位宽不符"判定结构性常哑**: 语料实测 `10-3091` 在 **869 份 xvlog 日志中 0 命中**、452 份 xelab 日志中 173 份命中 ⇒ **凡 grep `xvlog_*.log` 的裸 `10-3091` 判定永远不会触发**。 ⚠️ **历史事实**: `IMPLICIT-DECL-FAIL` / `BITWIDTH-MISMATCH-FAIL` 在**全仓留存日志里 0 命中** ⇒ 无任何证据表明这两条门**曾经**响过 (严格措辞: "没有留存日志含这些标记" ≠ "从未失败")。 规范检测器 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` 九项对照)；取证 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` (修复) + `_proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md` (铺开 + 语料级假阳性验证)。
- `tcl/readback_p7a.tcl`: 布局后回读原语属性 + 工具计算的时钟周期 + 时序/资源
  ⇒ gearbox 三条腿里的前两条(静态)。
- `board_scratch/probe_p7a_board.tcl`: 上板全套(安全闸 → 探针自检 → 短窗 → 负对照 A
  (`rxgearboxslip` 必须掉链重锁) → 600s 正式窗); 内含两条用血换来的护栏:
  **大数只用字符串插值(32-bit Tcl 的 `format %d` 会静默输出 0)** 与
  **取数前必发快照请求并等 ack(否则读到冻结值 ⇒ delta 恒 0)**。
- `board_scratch/dryrun_stub.tcl`: 无板干跑台架 —— 上面那两条护栏就是它抓出来的。
- `ctrl_scratch/ctrl_ibert_v3.tcl` + `extra_gate_diag.tcl`: 对照件恢复与归因诊断。
- `P7A_SPEC.md`: 闸 0 施工规格(工具事实核实 / 判据设计 / 风险表 / 未确证清单)。
- `_p7a_probe/*`(22 个文本文件, 324 KB): §1 逐字引用的工具原始输出(IP 存在性/器件支持/
  license 读数/TX_PROTOCOL 不存在/预设文件加密 等)与探针脚本。
  ⚠️ 该目录的**Vivado 工程与网表转储(17 MB 里的绝大部分)不入库**(见 .gitignore 那一条);
  P7A_SPEC §10 原本写"不进 git", 与 §1 的引用冲突 ⇒ **建议在本提交里把 §10 补一句话**
  (措辞见 P7A_COMMIT_PLAN §6.2), 否则文档自相矛盾。

原始读数在下一个提交 (证据批)。板级结论: 双向各 600 s / 6.003e12 bit 零错, BER 上界 4.997e-13。

Co-Authored-By: Claude Code <noreply@anthropic.com>
```

### C2 — 板级证据 + 文档

```bash
git add -- P7A_RESULT.md P7A_COMMIT_PLAN.md README.md PORT_NOTES.md \
  _proj_10g/reports/p7a_bitstream_sha256.txt \
  _proj_10g/reports/p7a_gate_summary.txt \
  _proj_10g/reports/p7a_ip_config.txt \
  _proj_10g/reports/p7a_readback.txt \
  _proj_10g/reports/p7a_readback_stdout.txt \
  _proj_10g/reports/p7a_build_stdout.txt \
  _proj_10g/reports/p7a_timing_summary.rpt \
  _proj_10g/reports/p7a_utilization.rpt \
  _proj_10g/reports/p7a_utilization_hier.rpt \
  _proj_10g/reports/p7a_clock_interaction.rpt \
  _proj_10g/reports/p7a_drc.rpt \
  _proj_10g/reports/p7a_lic_deny_stdout.txt \
  _proj_10g/reports/p7a_lic_deny_state.txt \
  _proj_10g/reports/p7a_xdc_probe_stdout.txt \
  _proj_10g/board_scratch/logs/hashes.txt \
  _proj_10g/board_scratch/logs/p7a_board_stdout.txt \
  _proj_10g/board_scratch/logs/p7a_board_run3_console.txt \
  _proj_10g/board_scratch/logs/p7a_board_run2_console.txt \
  _proj_10g/board_scratch/logs/prev_run1_failed_p7a_board_stdout.txt \
  _proj_10g/board_scratch/logs/prev_run1_failed_board_run_console.txt \
  _proj_10g/board_scratch/logs/prev_run2_stopsnap_p7a_board_stdout.txt \
  _proj_10g/board_scratch/logs/board_run_console.txt \
  _proj_10g/board_scratch/logs/diag_slip_stdout.txt \
  _proj_10g/board_scratch/logs/dryrun_stdout.txt \
  _proj_10g/board_scratch/logs/p7a_readstate_stdout.txt \
  _proj_10g/board_scratch/logs/readstate_console.txt \
  _proj_10g/ctrl_scratch/ctrl_console.txt \
  _proj_10g/ctrl_scratch/ctrl_console_run2.txt \
  _proj_10g/ctrl_scratch/ctrl_console_v4.txt \
  _proj_10g/ctrl_scratch/ctrl_console_xdiag.txt \
  _proj_10g/ctrl_scratch/reflash_console.txt \
  _proj_10g/ctrl_scratch/logs/m8_vivado.log.ref
```

**提交信息**：

```
P7a 板级证据 + 文档: 10G PCS/PMA 实测达标 (双向各 600s / 6.003e12 bit 零错, BER 上界 4.997e-13)

验收原件 = 新增的 **P7A_RESULT.md**(仿 P6B_ACCEPT.md 体例): 两阶段判据表(含"期望来源"栏)、
gearbox 三条腿、BER/速率正证据(逐字读数 + 文件行号)、中途两次停下的归因、未覆盖清单。

关键读数(每一份都能指到本提交里的原始读数文件 + 行号):
- **BER**: 每向 6,003,265,225,472 bit / 0 错字 / 0 头错 ⇒ **95% 置信上界 4.997e-13**
  (严于 10GBASE-R 的 1e-12); `hdrs_cnt == bits_cnt/64` 逐位成立 ⇒ "0 错"不是真空 0。
  `board_scratch/logs/p7a_board_stdout.txt:707-726`
- **速率**: 1.000025e10 bit/s(+0.0025%); 整窗比率 0.999995(59 个子窗同值)
  ⇒ 与 `10.3125 GBd × 64/66` 差 2.5e-5 ⇒ **gearbox 比率被实测钉死**(raw 会读 1.031250)。
- **阶段 1 对照件**: LOS 0/0 + LINK 10.312/10.313 Gbps 双向立起 + 60s 差分 6.27e11 bit 零错
  `ctrl_scratch/ctrl_console_v4.txt:336,359,376`。
- **负对照 A**: `rxgearboxslip` 脉冲 ⇒ Δerr 16640/16628 + 掉链 latch(00→11) + 零错重锁
  ⇒ 动态证明 gearbox 边界真的存在(同一份 stdout)。
- **静态判据**: `GEARBOX_MODE=5'b10001` / `TX|RXGEARBOX_EN=TRUE` / `TX_DATA_WIDTH=64`;
  fabric 侧 156.25MHz vs GTY 的 161.13MHz("raw 才会用"的那个时钟)
  ⇒ `reports/p7a_readback.txt` §[1]/§[2]; WNS +3.178 / WHS +0.018 / 0 失败端点 §[3]。
- **license 负对照**: 把 `Xilinx.lic` 改名后 gtwizard 仍 `IS_LOCKED=0 / USED_LICENSE_KEYS=<>`,
  同轮 `xxv_ethernet` 对照 `IS_LOCKED=1` ⇒ 读数有区分能力 `reports/p7a_lic_deny_*.txt`。
- **XDC 缺陷(本轮新发现)**: `if`/`foreach`/`puts` 不被 XDC 接受 ⇒ 整段约束**静默跳过**,
  构建照样 exit 0 / 位流照样出 ⇒ 最小复现与证据 `reports/p7a_xdc_probe_stdout.txt`。

文档改动:
- **PORT_NOTES.md**: 追加 "2026-09-29 P7a" 里程碑一节, 含**四条新教训**
  (① 问物理装配要问"线两头分别插在哪" ② Vivado 2025.2 的 Tcl 是 32 位的 ⇒ `format %d/%X`
  对 >2^31 静默输出 0 ⇒ 6e12 会伪装成"零误码" ③ XDC 只接受 Tcl 子集 ⇒ 约束被静默跳过
  ④ 测量台架缺陷会伪装成被测对象的缺陷) + 两条事实更正(模块是 **SFP+ 10G** 不是 SFP28;
  板子当前载 P7a 位流)。
- **README.md**: 状态块一句 P7a 结论 + 里程碑表 P7a 行 + 归档索引两行。
- **P7A_RESULT.md**: 新增(见上)。
- **P7A_COMMIT_PLAN.md**: 新增(本文件) —— 与 `P6B_COMMIT_PLAN.md` 的既有做法一致(该文件已入库)。
  ⚠️ 提交时它里面写的"未执行任何 git 操作"仍然为真: 归档 agent 只写方案, 提交由 TL 做。

⚠️ 未覆盖项已在 P7A_RESULT.md §7 明列(>10 分钟长期稳定性 / SFP I2C 未引出 / 手册 12GHz 边界
未触及 / X0Y6 的 inf 未深究 / 6-bit rxheader 只判稳定)。

Co-Authored-By: Claude Code <noreply@anthropic.com>
```

## 4. `.gitignore` 该补什么（**逐条核实过**，含"为什么不需要放行"）

### 4.1 已有全局规则覆盖（**核实过，不用补**）

| 规则（行号） | 覆盖了什么 | 核实方式 |
|---|---|---|
| `vivado_prj/`（`:32`） | `_proj_10g/vivado_prj/` 整个 60 MB（位流 / `.ltx` / `.dcp` / 构建日志） | `git check-ignore -v _proj_10g/vivado_prj/.../p7a_top.ltx` → 命中 |
| `*.bit`（`:36`） | `ctrl_scratch/ibert_top_v3_corrected_map.bit`（15.4 MB） | 命中 |
| `*.log` / `*.jou`（`:35`/`:34`） | 三处 `logs/` 下的 Vivado 日志与 journal | 命中 |
| `xsim.dir/` `*.wdb` `*.pb` `*.dcp` `*.Xil/` `dfx_runtime.txt` `*_prj.runs/` | 各工作目录里的产物 | 命中（`_proj_10g/sim/xsim.dir/`、`_proj_10g/dfx_runtime.txt` 实测） |

### 4.2 需要**新增**的排除（= C0 的内容）

`_proj_10g/lic_deny_prj/` · `_proj_10g/lic_deny_ctrl_prj/` · `_proj_10g/tcl/probe_xdc_prj/` ·
`_proj_10g/tcl/lint/files.f` · `*.ltx` · `_proj_10g/reports/p7a_post_route_netlist.v` ·
`_p7a_probe/` 的工程与网表（+ 尾部四条 `!` 放行，见 §6.2）。

### 4.3 ⭐ 需要**放行**吗？—— **本方案结论：一条都不需要**（除 `_p7a_probe` 的文本读数）

`P6b` 那轮给 `p6b_accept_final/*.log`、`board/p6b_verify/*.log`、`_proj_pcie/{smoke,soak}_scratch/*.log`
加了窄口径放行，理由是"报告逐字引用了那些 `.log`"。**本轮的形态不同，逐条核实过**：

| 候选 | 核实结论 | 处置 |
|---|---|---|
| `_proj_10g/reports/*.log`（`p7a_build.log` / `p7a_readback.log` / `p7a_lic_deny.log` / `p7a_xdc_probe.log`） | 同目录的 `*_stdout.txt` 是**同一批读数的捕获**（`p7a_gate_summary.txt` 逐条引用的就是 `.txt`） | **不放行**（避免同一读数两份） |
| `_proj_10g/board_scratch/logs/*.log`（含 `prev_*` 的两份 `.log`） | `*_console.txt` / `*_stdout.txt` 已把每轮读数完整captured（14 份 `.txt` 全部不入忽略） | **不放行** |
| `_proj_10g/ctrl_scratch/logs/*.log` | `ctrl_console{,_run2,_v4,_xdiag}.txt` + `reflash_console.txt` 是同一批读数的捕获（实测 `ctrl_console_v4.txt:336,359,376` 与 `ctrl_ibert_v3.log:350,373,390` 逐字同值）⇒ **`P7A_RESULT.md` 的引用已全部按入库的 `.txt` 捕获给行号**（并在它 §9 写明"行号口径"）⇒ 不放行也不会留下悬空引用 | **不放行** |
| `_proj_10g/tcl/lint/xvlog.txt` | **当前不被任何规则挡** | 无需放行（已入 C1） |
| `_proj_10g/ctrl_scratch/logs/m8_vivado.log.ref` | 扩展名 `.log.ref`，`*.log` 不匹配 | 无需放行（已入 C2） |
| `_p7a_probe/*_stdout.txt` / `*.tcl` / `run_p*.bat` / `clockInfo.txt` | **被 C0 新规则挡住 ⇒ 必须放行**（`P7A_SPEC.md` §1.1/§1.2/§1.3/§10 逐字引用它们） | **C0 尾部四条 `!`** |

### 4.4 三条**取舍**（默认按推荐做，TL 可改）

1. **`_proj_10g/reports/p7a_post_route_netlist.v`（3.6 MB）**：
   推荐**排除**（它是 readback tcl 的转储，判据读数已逐字进 `p7a_readback.txt` §[1]/§[1c]）。
   若要留档 ⇒ 在 C0 里加 `!_proj_10g/reports/p7a_post_route_netlist.v`。
2. **`*.ltx` 用全局规则还是窄规则**：推荐全局（实测现库 0 个已跟踪 `.ltx`；位流本身也不跟踪）。
   若想更保守 ⇒ 改成 `_proj_10g/**/*.ltx` + `_p7a_probe/**/*.ltx`。
3. **那批 `.log` 到底放不放行**：本方案选"不放行"（读数已在 `.txt` 捕获里，且引用已改造到 `.txt`）。
   ⚠️ 但要知道**"不放行"不是本仓的唯一先例**：现库里有 **265 个已跟踪的 `*.log`**
   （历史遗留 + 显式 `add -f`；gitignore 不作用于已跟踪文件）。
   若 TL 更想直接放行 ⇒ 只需在 C0 里补
   `!_proj_10g/ctrl_scratch/logs/*.log` 与 `!_proj_10g/board_scratch/logs/*.log`
   （可选再补 `!_proj_10g/reports/*.log`）；**不必改 `P7A_RESULT.md`**（它引的是 `.txt`，
   行号口径已在它 §9 写明）。两条路都自洽，**不要两条都做**（同一读数两份）。

## 5. **不该提交**的东西（及理由）

### 5.1 与本轮无关但会被顺手带上（**最重要的一条**）

| 路径 | 数量 | 理由 |
|---|---|---|
| `_tmp_fix_trailing_bs.py` `_tmp_gate_md5.py` `_tmp_inventory.py` `_tmp_p4_bats_finalize.py` `_tmp_p4_gates_harden.py` `_tmp_p4_negctl.py` `_tmp_p4_sweep.py` `_tmp_p4_sweep_sum.py` `_tmp_path_fix.py` `_tmp_pgtest.py` `_tmp_tripwire.py` | 11 | `P6B_COMMIT_PLAN.md` §4.2 已裁决"**不提交（留盘）**"（一次性脚本、多数含未修的 ECO 路径）⇒ 本轮沿用。**它们与 P7a 无关**，别顺手 `git add` |

### 5.2 本轮的产物/工程（**已被 C0 排除**，列出来是为了"看到它们没进库"时不必怀疑）

| 路径 | 体积 | 为什么不该进 |
|---|---|---|
| `_proj_10g/vivado_prj/` | 60 M | Vitro 工程 + 位流（`p7a_top.bit` 15.4 MB）+ routed `.dcp`；位流身份以 sha256 记档 |
| `_proj_10g/lic_deny_{prj,ctrl_prj}/` | 42 M | license 负对照的工程（含厂商生成的 IP HDL；读数已归档） |
| `_proj_10g/ctrl_scratch/ibert_top_v3_corrected_map.bit` | 15.4 M | 对照件位流（全局 `*.bit` 挡住） |
| `_proj_10g/tcl/probe_xdc_prj/` | 7 文件 | XDC 缺陷的最小复现工程（脚本可重建，stdout 已归档） |
| `_proj_10g/reports/p7a_post_route_netlist.v` | 3.6 M | 网表转储（见 §4.4） |
| `_p7a_probe/{pj_fin,rb_pos,rb_raw}/` + `nl_{pos,raw}.v` + `.Xil/` | ~16.7 M | 三个探针 Vivado 工程 + 两个网表转储 |
| `*/xsim.dir/` `*.wdb` `*.pb` `*.log` `*.jou` | — | 仿真/工具产物（全局规则） |
| `_p7a_probe/*_vivado.log`（7 个） | ~270 K | 与 `*_stdout.txt` 近乎重复（实测：`p2_stdout.txt:253` 已有引用的 12-4371 报错；`p1_stdout.txt:160` 已有 TX_PROTOCOL 报错） |

### 5.3 一条**顺序**约束（同 P6b §4.3 的同族）

**C2 里的 `P7A_RESULT.md` 索引的每一份读数都在同一个提交里**（这点已逐条核过：§0/§3/§4/§5 引用的
14 份文件全在 C2 清单里；`_proj_10g/rtl/*.v` 与 `P7A_SPEC.md` 在 C1）。若 TL 把 `P7A_RESULT.md`
挪到 C1 ⇒ 它的引用会短暂悬空（`_proj_10g/reports/*` 还没入库）⇒ **不要把 C2 拆到 C1 前面**。

## 6. 我没做/需要 TL 拍板的两点（**诚实列出**）

### 6.1 我没有做的事

- 没有 `git add` / `commit` / `push`；没有改 `user.name`/`user.email`；没有动 `.git/config`。
- 没有修改 `P7A_SPEC.md` 一个字节（含 §10 那句"不进 git"）—— 见 §6.2。
- 没有跑 Vivado / 没有烧板 / 没有碰 `192.168.0.38` 的服务。
- **只读**目录 `_ibert/`、`_proj_mdio/` 未改动；`D:\repo\perfv` 未碰。

### 6.2 ⚠️ 需要拍板：`P7A_SPEC.md` §10 与"放行 `_p7a_probe` 文本读数"冲突

`P7A_SPEC.md` §10 写的是"本阶段产生的文件（都在 `udp_hls_10g/_p7a_probe/`，工具核实用，**不进 git**）"，
而同一份文件的 §1.1/§1.2/§1.3 又逐字引用 `_p7a_probe/p{1,2,5}_stdout.txt` 作为原始输出。
两条不能同时为真。**本方案选的是"放行那 324 KB 文本读数"**（与 `.gitignore` 里既有的
"报告引用的东西真的在库里"原则一致）。若 TL 采纳 ⇒ **建议在 C1 里给 §10 补一句话**：

```
> ⚠️ 2026-09-29 更正: `_p7a_probe/` 的**Vivado 工程与网表转储**不入库 (17 MB 里的绝大部分),
> 但本文件 §1.1/§1.2/§1.3 **逐字引用**的那批**文本读数** (`*_stdout.txt` / 探针 `*.tcl` /
> `run_p*.bat` / `clockInfo.txt`, 合计 324 KB) **已入库** —— 否则本文件的引用悬空。
```

若不采纳（整目录排除）⇒ §1.1/§1.2/§1.3 的引用要改成"路径记录"并注明"原件未入库"。
**两条路我都没走**（越权改了 P7A_SPEC）；这一条留给 TL。

## 7. 提交后自检（建议逐条做）

```bash
# ① 工作区应只剩"不提交"的那两类 + 产物
git status --porcelain                      # 期望: 只剩 _tmp_*.py (11) 与 _p7a_probe/ 被忽略的工程

# ② 证据齐全性: P7A_RESULT.md 引用的 14 份读数是否都在库里
git ls-files _proj_10g/reports _proj_10g/board_scratch/logs _proj_10g/ctrl_scratch | wc -l

# ③ 位流/工程确实没进库
git ls-files | grep -Ei '\.(bit|ltx|dcp)$'   # 期望: 0 行
git ls-files _proj_10g | grep -c '^_proj_10g/vivado_prj'   # 期望: 0

# ④ 提交信息里的 sha256 与实际位流一致(位流在盘上)
sha256sum _proj_10g/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit

# ⑤ 文档四处都带上了 (含本文件)
git show --stat HEAD~0 | grep -E 'P7A_RESULT|P7A_COMMIT_PLAN|README|PORT_NOTES'
```
