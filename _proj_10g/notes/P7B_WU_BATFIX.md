# P7B_WU_BATFIX —— 门驱动 bat 的编码/行尾修复（本会话回归抓到的真缺陷）

- 日期：2026-10-07 02:2x–02:4x（本会话）
- 范围：**只改 bat 注释编码与行尾**，零 RTL / 零 TB / 零脚本逻辑改动；**未提交 git**；未碰板子。
- 结论：主门 bat + 两个同源 probe bat 已修为 **纯 ASCII + 全 CRLF**；门重跑 **EXIT=0**、判据逐行不变、
  多出的那行乱码报错消失（修前/修后对照见 §2）。

---

## 1. 缺陷事实（修前）

`sim/p5wu/run_tb_app_wu.bat`（本会话新建，已随 09d2189 入库；工作区 2738 B）：

| 项 | 修前实测 |
|---|---|
| 非 ASCII 字节 | **368 B**，集中在第 21–27、44 行（8 行中文 `REM`） |
| 行尾 | CR=52 / LF=52 ⇒ **已是全 CRLF**（行尾本来就合规；违规只在编码） |
| 症状（该门 stdout 第 1–2 行） | GBK `'TB' 不是内部或外部命令，也不是可运行的程序` / `或批处理文件。` |
| 退出码 | **0**（判据全过：`P7B WU GATE OK` + `P7B WU GATE PASS`，PASS 38 / FAIL 0） |

⇒ 与移交描述一致：**输出面污染，不影响退出码与判据**。原件 `before_stdout.txt`（3488 B，含 52 个非 ASCII 字节）。

### 1.1 机理：最小复现 + 双向负对照（本报告新做，实测）

三个 UTF-8+CRLF 的样本 bat（`exp*.bat.utf8demo`，把扩展名改回 `.bat` 即可复跑）：

| 样本 | 内容差异 | 实测 stdout | 结论 |
|---|---|---|---|
| `exp1_trail_cjk` | `REM …是句号。`（行尾 = U+3002） | `A-OK` / `'…' 不是内部或外部命令…` / `B-OK`，**rc=0** | **复现** |
| `exp2_trail_ascii` | 同上，句号换 ASCII `.` | `A-OK` / `B-OK`，rc=0 | 干净（负对照） |
| `exp3_cjk_midline` | CJK 在**行中**（`句号在行中 。 xyz`） | `A-OK` / `B-OK`，rc=0 | 干净（负对照） |

⇒ **触发条件 = 行尾多字节字符**（在 `chcp`=936 的 GBK 控制台下，cmd 的行解析错位）。
真文件里错位形态是"下一行的 `REM ` 前缀被吃掉、其尾段 `TB …` 被当命令执行"；复现件里是被当命令的是一个
乱码双字节序列 —— 两种形态同源。
⚠️ **精确的字节级配对细节未解剖**（只做到"条件 + 排除"的实测界定）；两条负对照足以证明"ASCII 化即根除"。
⚠️ 该症状 **rc 恒 0**（复现件与真门都是 0）—— 这也是为什么它只在回归轮的 stdout 复查里被抓到。

## 2. 修复与验证

### 2.1 修法（外科式，只动注释）

`_proj_10g/notes/p7b_wu_batfix/fix_bat.py`：**按行号替换那 8 行 `REM`**（语义等值英文翻译，不删信息），
逐行断言**其余行逐字节不变**；行尾统一 CRLF；结果断言纯 ASCII。原始件备份 `run_tb_app_wu.bat.orig`。

### 2.2 逐字节验证（要求的命令与输出）

```
$ grep -Pn '[^\x00-\x7F]' sim/p5wu/run_tb_app_wu.bat ; echo rc=$?
rc=1                      # 0 命中
$ file sim/p5wu/run_tb_app_wu.bat
sim/p5wu/run_tb_app_wu.bat: DOS batch file, ASCII text, with very long lines (411), with CRLF line terminators
# 字节核（python，逐字节）：bytes=2845  nonascii=0  CR=52 LF=52  allCRLF=True  endsCRLF=True  maxbyte=126
$ git diff --numstat -- sim/p5wu/run_tb_app_wu.bat
8       8       sim/p5wu/run_tb_app_wu.bat      # 纯注释，8 增 8 删，diff 全文见 fix.diff
```

⚠️ **工具坑（我自己先踩了一次）**：本机 Git-Bash 的 `grep`/`sed` 是**文本模式**（读文件时吃 CR）——
`grep -c $'\r$'` 会谎报 0、`sed -n 25p | od -c` 看不到 `\r`。**判 CRLF 必须用 python / `od`**，别用 grep/sed。
⚠️ 仓库侧：`core.autocrlf=true` ⇒ **git blob 里存的是 LF**（`git show` 看不到 CR 属正常），CRLF 只在工作区。

### 2.3 修前/修后对照（全局 #48：两个方向都给）

| 判据 | 修前 | 修后 |
|---|---|---|
| stdout 大小 / 非 ASCII 字节 | 3488 B / **52** | 3426 B / **0** |
| 首 2 行 | `'TB' 不是内部或外部命令…` + `或批处理文件。` | `#-----…`（xsim 头，直接开始） |
| `P7B WU GATE OK` | 有（第 77 行） | 有（第 77 行） |
| `P7B WU GATE PASS` | 有（第 81 行） | 有（第 81 行） |
| PASS / FAIL 计数 | 38 / 0 | 38 / 0 |
| exit code | 0 | 0 |
| 过滤易变行后的 before↔after diff | —— | **仅 1 个 hunk = 上面那 2 行消失**，其余逐行相同 |

- 命令：`cmd //c 'sim\p5wu\run_tb_app_wu.bat'`；原件 `before_stdout.txt` / `after_stdout.txt`（+ `*_exit.txt`）。
- "过滤易变行" = 去掉 xsim 版本头（`#` 开头）与 `INFO: … Exiting xsim at …` 时间戳行；
  关键判据行（含 `$finish called at time : 743884 ns`）**两次运行逐字相同** ⇒ 仿真确定性未受影响。
- ⚠️ 这条门的"修好了"判据 = **那行 `'TB' …` 消失**（上表第 2 行），且判据行逐字不变 —— 两个方向都有对照。

## 3. 本会话 bat 普查（ASCII + CRLF）

范围 = `find . -name '*.bat' -newermt '2026-10-07 00:00'`（全仓 14 个）＋ `git log --since=2026-10-07 --name-only`
里今天 4 个提交涉及的 bat（补出 2 个 10-06 深夜的）＋ `git status` 的未跟踪目录（`sim/p5wu_regress/`、`sim/p5wu_review/`）。
逐字节读数（`nonascii` = >0x7F 字节数；`LFonly` = 行尾不是 CRLF 的行数）：

| 文件 | mtime | 读数 | 结论 |
|---|---|---|---|
| `sim/p5wu/run_tb_app_wu.bat` | 10-07 01:19→02:31 | 修前 368/0 → **修后 0/0** | ✅ 已修 |
| `sim/p5wu_regress/probe_head.bat` | 10-07 01:45→02:32 | 修前 **305 / 3** → **修后 0/0** | ✅ 已修 |
| `sim/p5wu_regress/probe_trace.bat` | 10-07 01:45→02:32 | 修前 **305 / 2** → **修后 0/0** | ✅ 已修 |
| `sim/p5wu_review/run_author_wu.bat` | 10-07 01:45 | 0 / 0 | ✅ 已核通过 |
| `sim/p5wu_regress/run_wrap_head.bat` | 10-07 01:50 | 0 / 0 | ✅ 已核通过 |
| `sim/p5wu_regress/run_wrap_new.bat` | 10-07 01:50 | 0 / 0 | ✅ 已核通过 |
| `sim/p5wu_review/run_tb_wu_review.bat` | 10-07 02:06 | 0 / 0 | ✅ 已核通过 |
| `sim/p5wu_regress/rerun_dupstorm.bat` | 10-07 02:10 | 0 / 0 | ✅ 已核通过 |
| `sim/p5wu_regress/scan_logs.bat` | 10-07 02:14 | 0 / 0 | ✅ 已核通过 |
| `_proj_10g/notes/p7b_wu_loop/run_program_wu.bat` | 10-07 02:29 | 0 / 0 | ✅ 已核通过（**板级测量 agent 的文件，只读检查**） |
| `vivado_prj/p7b_ku5p_prj.runs/{synth_1,pcs64_synth_1,xdma_0_synth_1,impl_1}/runme.bat` | 10-07 01:52–02:01 | 0 / 0 ×4 | ✅ 已核通过（Vivado 自动生成产物，非手写） |
| `_proj_10g/notes/p7b_biz_s2/run_program_s2.bat` | 10-06 22:43（今天 ff78247 入库） | 0 / 0 | ✅ 已核通过 |
| `_proj_10g/notes/p7b_biz_tcpreg/run_program_tcpreg.bat` | 10-06 23:28（今天 ff78247 入库） | 0 / **4（纯 LF）** | ⛔ **未动**，见下 |

### 3.1 未动的一项与理由（重要）

`_proj_10g/notes/p7b_biz_tcpreg/run_program_tcpreg.bat`：ASCII 但**纯 LF** ⇒ 违反 CRLF 纪律，
**识别到但刻意未改**，理由 = **该文件正被并发 agent 使用中**：
- 该目录 `tcpreg_program_stdout.txt` 的 mtime = **02:32**（我普查时刚被写过）；
- 现场进程表里有板级测量 agent 的 `python peer_ssh.py … bash /tmp/p7b_biz/tcpreg_j6.sh …`（J6 阶梯正在跑，
  每档可能重烧位流）。**改一个正在被 cmd 读取执行的 bat 有真实的执行期破坏风险**，且它属于"别碰它们的文件"的范围。
- ⇒ 建议：等板级测量轮结束后由**其所有者**或下一轮顺手改（同样流程：ASCII 已满足，只需 LF→CRLF；
  本报告 §2.1 的脚本可直接用）。

### 3.2 另两个新违规 bat 的修法（与主件同源）

`probe_head.bat` / `probe_trace.bat` 是主门 bat 的克隆（第 21–27 行同一批中文注释；另外行尾混用 CRLF/LF）。

`_proj_10g/notes/p7b_wu_batfix/fix_bat2.py`（按**字节精确匹配**查表替换，非行号）：

- `probe_head.bat`：替换 21–27 行；`LFonly 35,36,37` → CRLF；**其余 30 行逐字节不变**；修后 1764 B / 非 ASCII 0 / CR=LF=37。
- `probe_trace.bat`：替换 21–27 行；`LFonly 1,35` → CRLF；**其余 28 行逐字节不变**；修后 1709 B / 非 ASCII 0 / CR=LF=35。
- 冒烟（修后实跑，均 **EXIT=0**）：`probe_head` 打出 `PROBE-TB/RTL/SIM=[…]`；`probe_trace` 打出 `PROBE-END`。
- ⚠️ 两个 probe 的第 21 行原本就写着 `REM run_tb_app_wu.bat -- …`（克隆自门的复制粘贴残留，**内容本身就错**）——
  按"语义等值翻译、不删信息"原则**原样保留**，只做了 ASCII 化；如需改名请由所有者决定。

### 3.3 既存不合规（只列清单，未动）

全仓 739 个 bat 中，**723 个是既存件**（mtime < 2026-10-06），其中 **126 个不合规**
（109 个含非 ASCII / 18 个含 LF-only 行，有 1 个两者兼有）。完整清单 = `old_bats_census.txt`
（例：`board/run_build.bat`、`hls/run_hls.bat`、`sim/p4sim/run_tb_*.bat`、`sim/p5sim/run_tb_p5_*.bat`、
`_proj_10g/notes/p7b_rate*/…`、`_proj_10g/notes/p7b_lat/…`、`sim/advrun*/…` 等）。
**按纪律只列清单、未修改** —— 它们不属于本会话新增/改动。

## 4. 复跑证据（原件）

| 文件 | 内容 |
|---|---|
| `p7b_wu_batfix/before_stdout.txt` / `before_exit.txt` | 修前 stdout（首 2 行 = 乱码报错）/ `EXIT=0` |
| `p7b_wu_batfix/after_stdout.txt` / `after_exit.txt` | 修后 stdout（无乱码行）/ `EXIT=0` |
| `p7b_wu_batfix/fix.diff` | `git diff` 全文（8/8，纯注释） |
| `p7b_wu_batfix/*.bat.orig` ×3 | 三个被修文件的修前字节备份 |
| `p7b_wu_batfix/fix_bat.py` / `fix_bat2.py` | 修复脚本（带逐行不变断言） |
| `p7b_wu_batfix/exp{1,2,3}_*.bat.utf8demo` + `.out` | 机理最小复现 + 两个负对照（改回 `.bat` 可复跑） |
| `p7b_wu_batfix/old_bats_census.txt` | 既存不合规 bat 全清单 |

**收口复跑（本次任务全部改动落盘后，02:4x 再跑一次）**：`EXIT=0`、stdout 非 ASCII 字节 = 0、
与 `after_stdout.txt` 过滤易变行后 **diff 为空**、`P7B WU GATE OK` 在、乱码行不在 —— 原件 `final_stdout.txt` / `final_exit.txt`。
跑前钉住的编译面修订（md5）：`rtl/fifo_sync.v` `d0d133ede…` · `rtl/app_ctrl.v` `c8e000671…` ·
`tb/tb_app_wu.v` `766e5445e…` · `run_tb_app_wu.bat` `2f39db67e…` · `p4gate.py` `0de30a6c1…`。

修后 sha256：`run_tb_app_wu.bat` = `5ce29340bbeb15266f71f2d3f809af767cd164953d5256cf8872673f48562d84`；
`probe_head.bat` = `16faf441d4d6ddfaf4ffe9180d540cead60d6c6efcf9dd2c40338c03c7da8fcb`；
`probe_trace.bat` = `c7d19ec80a34b87986f7551268e17effd38efa2cb2f65a1c81a224e317401c77`。

## 5. 边界与未做

- **未提交 git**（工作区改动：`M sim/p5wu/run_tb_app_wu.bat`；未跟踪新增 `sim/p5wu_regress/`、`sim/p5wu_review/`
  下的两处 probe 修改与 `_proj_10g/notes/p7b_wu_batfix/`）。
- 未改任何 RTL / TB / 脚本逻辑；三个被修 bat 的**逻辑行逐字节不变**（脚本内已断言，§2.1/§3.2）。
- 未碰板子、未烧录、未运行任何 Vivado 构建；门只在 `sim/p5wu/run` 独立工作目录内跑。
- 未结项：`run_program_tcpreg.bat` 的 LF-only（§3.1，等并发测量轮结束）；
  既有 126 个不合规 bat（§3.3，非本会话范围）。
