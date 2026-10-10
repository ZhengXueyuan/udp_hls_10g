# aliasgate 轮（2026-10-10）：五行方向修复 + `p5_wrapper` 登记矩阵(#19) + 别名方向常驻门

> ⚠️ **本件由 TL 代落盘**（子 agent 写 `.md` 被 harness 拒绝）；正文按子 agent 最终回复整理，**未改一字数字/行号**。
> **一句话**：① `board/wrapper_p4.v` 那五行**已修**（`git diff --stat` = 1 file, **7 insertions / 5 deletions**，只有这一个文件）；
> ② `p5_wrapper` **已登记**进常驻矩阵（**第 17 门**，全跑 **17/17 EXIT=0**）；③ **别名方向自校验**已是**常驻门**
> （落点 `sim/aliasgate/`，接进现役 lint 入口 `_proj_10g/tcl/run_lint_p7a.bat`；两配置命中数 + 负对照红/正控绿 + **假阳性 0**）。
> ⚠️ 全程**未启动 Vivado / 未烧板 / 未 ssh 对端**；只跑 xsim（矩阵门）与纯文本工具。

---

## §1 五行结论

| # | 项 | 结论 |
|---|---|---|
| 1 | 那五行改了吗 | ✅ **改了**，`git diff --stat` = `board/wrapper_p4.v \| 12 +++++++-----`，**1 file changed, 7 insertions(+), 5 deletions(-)**（5 行换向 + 2 行注释；其余零改动，§3-①） |
| 2 | 新门登记后的矩阵结果 | ✅ **全 17 门 17/17 全 `EXIT=0`**（含 `p5_wrapper`）· `gates failed: 0` · **`VERDICT: FROZEN`（257 文件位级不变）** · `MATRIX DONE 12:00:01`；子集轮 `-only p5_wrapper+chain+unit_vlan` 亦绿 |
| 3 | 方向自校验门 | 落点 = **`sim/aliasgate/`**（5 个新文件），接进 **`_proj_10g/tcl/run_lint_p7a.bat:25-33`**；修前 **A=5 / G=0**、修后 **0 / 0**；**负对照红**（rc=1、**逐行指名那 5 行、5 个不同行号**）· **正控绿**（rc=0、selftest **11/11**）；**假阳性 = 0** |
| 4 | 覆盖面一句话 | 见 §5：**只在 `APP_MODE`-only 配置下、经真 wrapper 实例的一次全链功能门**；两文件**首次进矩阵指纹编译集**；**不覆盖**板配置与 `*_OVL` |
| 5 | 未做到 | 见 §6 |

---

## §2 逐条改动

### ① `board/wrapper_p4.v`（**唯一允许的 RTL 改动**）

**改前**（HEAD，工作树行号 2771-2775；git blob `70b24b4`）： ⛔ **2026-10-11 订正（行号）**：`2771-2775` = 改前（修复前）当时值；**现行引用真值 = `:2784-2788`**（五行 `assign`）/ **`:2782-2783`**（两行订正注释）—— 2026-10-11 现读工作树（带另一支构建 agent 未提交改动 +5、落 `:2141` 一带）；位移链 = 修复前 2771-2775 → 本改（`faee172`）2773-2777 → `fd671b6`（2026-10-10 20:46）2779-2783 → 现工作树再 +5。本件下文各处 `2771-2775`/`2773-2777` 同此订正。
```verilog
`else
    assign txsrc_tdata = m_tx_tdata;        // 单域: 纯线名别名 (逐位不变)
    assign txsrc_tkeep = m_tx_tkeep;
    assign txsrc_tlast = m_tx_tlast;
    assign txsrc_tvalid= m_tx_tvalid;
    assign m_tx_tready = txsrc_tready;
```
**改后**（工作树 **2773-2777**；git blob `85bc658`；工作文件 sha256 `e80acda9b55c1d19f1f22c0edf25f76f5467084bb6cc92fffac2e7e2d75c49be`； ⛔ 2026-10-11 订正（行号）：`2773-2777` = 本改落地时值；**现行 = `:2784-2788`**（链见 §2-① 首处订正）；
UTF-8 / **纯 CRLF 4378/4378、0 bare LF**）：
```verilog
`else
    // P7b 2026-10-10: 五行方向原写反 (tx_arb.m_axis 在 txsrc_*, mac_tx_64.s_axis 在 m_tx_*) ⇒
    //   m_tx_tvalid / txsrc_tready 无驱动 (Z), 本配置 TX 全死; 仅 ifndef DP_156MHZ 分支, 板构建不编译。
    assign m_tx_tdata   = txsrc_tdata;      // 单域: 纯线名别名 (逐位不变)
    assign m_tx_tkeep   = txsrc_tkeep;
    assign m_tx_tlast   = txsrc_tlast;
    assign m_tx_tvalid  = txsrc_tvalid;
    assign txsrc_tready = m_tx_tready;
```
- **方向现核**：`tx_arb.m_axis_*` 输出接 `txsrc_*`（`:2746-2750`，`.m_axis_tready(txsrc_tready)` 是**输入**）；
  `mac_tx_64.s_axis_*` 接 `m_tx_*`（`:2810-2814`，`.s_axis_tready(m_tx_tready)` 是**输出**）。正确写法对照 = 同文件 `:2768-2769`（DP 支）。 ⛔ 2026-10-11 订正（行号）：三处现核 = **`:2757-2761`** / **`:2823-2827`** / **`:2779-2780`** —— 原写 2746-2750 / 2810-2814 / 2768-2769 = 本改落地后旧值（其后 `fd671b6` +6、现工作树未提交 +5）。
- ⭐ **与已有 xsim 证据的关系（机械证明）**：`compare_fix_to_Earm.py` ⇒
  `alias lines only: live=5 E-arm=5` / `live == E-arm (token-normalised): True` / `mutant == reversed(live): True`
  ⇒ **落地修复与上一轮 E 臂逐词相同（只差空白与新增注释）⇒ E/F/H 三门（`p5_wrapper` / `p5e_t2_wrapper` / `p5e_udp_wrapper`）的 xsim 绿证据可迁移**。
- **对板构建无影响（现核）**：`board/build_p7b_ku5p.tcl:153`
  `verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1}` ⇒ **`DP_156MHZ=1` 在位** ⇒ `ifndef DP_156MHZ` 块**不参与编译**。
  带 `DP_156MHZ` 的构建脚本共 **4 个**（`build_p7b_ku5p.tcl` / `build_p6e_ku5p.tcl` / `build_p6b_ku5p.tcl` / `build_p6b_final_ku5p.tcl`）
  ⇒ **板位流不受影响**；受影响者 = 只定义 `APP_MODE` 的构建（如 `board/build_p5.tcl`）与非 DP 仿真门。

### ② 矩阵登记（`p5_wrapper`，第 17 门）

| 文件 | 改动 |
|---|---|
| `sim/p4gates/p5wrapper_src.f` | **新建**：31 件（27 rtl + 3 board + 1 tb），头部写明 **配置 = `APP_MODE`-only** 与"**不能顶替板配置 wrapper 门**"（r6 `ack_seen` 不在其中） |
| `sim/p4gates/run_matrix_p4dfix.bat` | **只加**：**第 211 行** `call :gate p5_wrapper sim\p5sim\run_tb_p5_wrapper.bat p5wrapper_src.f - -`（+10 行注释说明覆盖面）+ 门计数 `16` **改成派生值** `GATE_TOTAL`。**既有 16 行 `call :gate` 一字未动** |
| `sim/p4gates/paths.txt` | `FINGERPRINT_GLOBS` 追加 `tools\gen_stim_p5_app.py`（本门判据）与 `sim\p5sim\run_tb_*.bat` |
| `sim/p5sim/run_tb_p5_wrapper.bat` | ① 头部 bespoke pathguard → `call "%~dp0..\p4gates\p4env.bat"` + `p4gate.py selfcheck`（**必须**，§3-②）；② `cd /d %~dp0` 后加 `P4_WORKDIR` **私有目录**（坑 7）+ `checkpaths --manifest`（行 33-34）；③ 判据读 **`%CD%`** 而非 `%SIM%`（否则矩阵下会读 `sim\p5sim` 的**陈旧 memh**，行 69）；④ 删掉已无用的 `set SIM=` |
| `sim/p4sim/run_matrix_p4dfix.sh` | **仅注释**里"16 gates"改成"门表 = `call :gate` 行"（无功能改动） |

### ③ 别名方向常驻门

**落点选择与理由**：两个现役 lint 入口的 key（**逐字抄**）：`board/run_lint_p6e.bat:26,39` 与 `_proj_10g/tcl/run_lint_p7a.bat:45,58` 是**同一组 5 键**
（`Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared`）
+ 裸 `10-3091` + `ERROR` + 活性正证据 `Built simulation snapshot`。**这 5 键逐条都抓不到"网无驱动"**
（上一轮实测：p6e 入口的宏**恰好编的就是坏分支**却 `LINT-OK`/EXIT=0）⇒ 本门是**补一个新面**，不是改 key。
- **为什么落在 `run_lint_p7a.bat`**：`board/` 在本轮写边界里**只有那 5 行** ⇒ `run_lint_p6e.bat` **动不了**。
  ⚠️ **建议下一步**（需另授权）：把同一行 `call "%~dp0..\..\sim\aliasgate\run_aliasgate.bat" || exit /b 1` 加进 `board/run_lint_p6e.bat`。
- **为什么放在入口最前**：p7a 入口自己有一段前置拒绝逻辑 ⇒ 面放在后面会**结构性不可达**。（⚠️ 原先据"`p7a_prj` 不在盘上"推断它必然 97 拒绝 —— **实测推翻**，见 §7-①。）

**判据（精确、故意收窄）**：对活跃 `` `ifdef `` 分支里的纯别名 `assign X = Y;`（两侧均为单个标识符）——
`X` 被**某个被例化模块的 output 端口**驱动、且 `Y` **无任何驱动**（不是实例 output、不是 `wire Y = ...` 声明即驱动、不是别的 assign 的 LHS、
不是拼接 LHS 成员、不是 reg、不是**本模块 input/inout 端口**）⇒ **REVERSED（红）**；两端都有驱动 ⇒ **MULTI-DRIVER（也红）**；
其余判 `ok` 或 `UNRESOLVED`（**打印计数**、不置红）。
**仪器自证**：每次运行重跑 **18 条手核端口方向自校验**，任一不符 = **硬失败**；行尾先归一化 ⇒ CRLF 与 LF 都能读。

**两配置命中数（`--file board/wrapper_p4.v`）**

| 时点 | `A_appmode_only`（macros = `APP_MODE`） | `G_appmode_dp156`（`APP_MODE,DP_156MHZ`） | 退出码 |
|---|---|---|---|
| **修前** | 纯别名 30 / ok 25 / **REVERSED 5** / unresolved 0 | 纯别名 17 / ok 17 / **REVERSED 0** | **1** |
| **修后** | 纯别名 30 / **ok 30** / REVERSED 0 | 纯别名 17 / **ok 17** / REVERSED 0 | **0** |

（修前 5 行逐条指名 `board/wrapper_p4.v:2771-2775`，X 驱动者 = `u_tx_arb.m_axis_{tdata,tkeep,tlast,tvalid}` 与 `u_mac_tx.s_axis_tready`，Y 驱动者全空。） ⛔ 2026-10-11 订正（行号）：该 5 行现核 = **`:2784-2788`**（2771-2775 = 修复前旧号）。

**负对照（有牙）**：`run_aliasgate_selftest.bat` 在**临时副本**上把五行改回错误方向
（`selftest_mutate.py`，**刻意不读 git HEAD** —— 那样会在修复被提交后静默退化成"零突变"），
mutant 落在 `sim/aliasgate/_selftest/`，**仓内文件一字节未动**。结果 = **11/11**：
```
[OK ] NEG exit code == 1                        [OK ] NEG config G rev=0
[OK ] NEG has exactly 5 REVERSED rows           [OK ] NEG parser selfcheck 18/18
[OK ] NEG rows name 5 distinct line numbers     [OK ] POS exit code == 0
[OK ] NEG rows name the 5 nets                  [OK ] POS config A rev=0
[OK ] NEG config A rev=5 multi=0                [OK ] POS config G rev=0
                                                [OK ] POS has no REVERSED rows
CONTROLS: 11/11 as expected → ALIASGATE SELFTEST PASS
```

**门级红对照（"这条门不是哑门"的直接证据）**：把注册门 bat **逐字节复制**、只改 **2 行**（`p4env` 调用多一级 `..`；编译表里的 `%BD%\wrapper_p4.v` → mutant 副本）⇒
```
wrapper GMII: 0 帧 (conn0 数据 0 / 其它 0 / 坏 FCS 0)
MISMATCH: wrapper 只出了 0 个 conn0 数据帧 (<2) — APP_MODE 通路没通
P5 WRAPPER FAIL (1 项)          ← rc=1
```
⇒ 与上一轮 diag 的 A 臂签名一致 ⇒ **登记的门在坏树上真的红，且判据走到退出码**。
（⚠️ 前两次尝试是**假红**：路径没配对 ⇒ `系统找不到指定的路径。` / `[XSIM 43-4316] Can not find file`。**读输出**才发现 —— 只信退出码会把"工具级错"当"判据红"。）

**入口级红传播**：`make_entry_negctl.py` 把 `_proj_10g/tcl/run_lint_p7a.bat` 逐字节复制、**只改一行**（alias 调用指向 mutant），`diff` = `33c33`；跑它 ⇒ 前 15 行就是别名门红输出 + `ALIASGATE FAIL rc=1` + **入口 rc=1**（且不继续跑 p7a body）⇒ 位置在前、红能穿透。

### ④ 新增文件清单
```
sim/aliasgate/alias_dir_check.py          ← 门本体（静态方向追踪 + 18 条自检 + 行尾归一化 + --scan-all）
sim/aliasgate/run_aliasgate.bat           ← 门入口（自定位 + p4gate.py selfcheck + 可选 %1 目标 + target 回显）
sim/aliasgate/run_aliasgate_selftest.bat  ← 负/正对照
sim/aliasgate/selftest_mutate.py          ← 造 mutant（恰好 5 处换向，否则拒绝出件）
sim/aliasgate/selftest_assert.py          ← 对照断言（11 项）
sim/p4gates/p5wrapper_src.f               ← 新门清单
_proj_10g/notes/p7b_aliasgate_20261010/   ← 本报告 + 全部原始输出
```

---

## §3 原始输出（关键三条）

### ① `git diff --stat`（RTL 改动全貌）
```
$ git --no-pager diff --stat
 board/wrapper_p4.v | 12 +++++++-----
 1 file changed, 7 insertions(+), 5 deletions(-)
```

### ② 为什么必须改 gate 头（`manifestcheck` 实测）
```
$ python sim/p4gates/p4gate.py manifestcheck --manifest sim/p4gates/p5wrapper_src.f \
      --bat sim/p5sim/run_tb_p5_wrapper.bat          # 旧头
[P4GUARD FAIL] manifest/bat file-list drift ...: manifest declares 31, bat carries 0
RC=1
$ ...   # 改头之后
[P4GUARD OK] manifestcheck run_tb_p5_wrapper.bat: 31 files == manifest sim/p4gates/p5wrapper_src.f
[PATHGUARD OK] selfcheck: 2 path token(s), 0 outside the repo
```
根因：旧头用 `for %%I in (...) do set "REPO_ROOT=%%~fI"` 自赋 `REPO_ROOT`，`bat_file_list` 把它读回成**未解析的字面量** ⇒ 每个 `%REPO_ROOT%\*.v` token 都落不了地 ⇒ "bat carries 0"。

### ③ 矩阵（原始日志）
```
GATE chain EXIT=0      GATE burst200 EXIT=0    GATE trunc50 EXIT=0    GATE trunc100 EXIT=0
GATE halfdrop EXIT=0   GATE txdrop50 EXIT=0    GATE gate4096 EXIT=0   GATE dupstorm EXIT=0
GATE pcackoob EXIT=0   GATE vlanchain EXIT=0   GATE vlanburst EXIT=0  GATE stallgate EXIT=0
GATE unit_retx EXIT=0  GATE unit_fifo EXIT=0   GATE unit_vlan EXIT=0  GATE unit_uart EXIT=0
GATE p5_wrapper EXIT=0                      ← 新门
--- summary ---
gate filter : (none -- all 17)      gates run   : 17 / 17      gates failed: 0
VERDICT: FROZEN -- all 257 hashed files byte-identical across the run;
MATRIX DONE 2026/10/10 12:00:01.16   （11:34:47 起，≈25 min）
```
`p5_wrapper` 门内判据（矩阵日志）：`| wrapper GMII: 3 帧 (conn0 数据 3 / 其它 0 / 坏 FCS 0)` / `| P5 WRAPPER OK (wrapper APP_MODE app-TX 通路端到端逐字节正确)`
⚠️ 第一次全跑**中途死掉**（`MATRIX-RC=255`，无 `EXIT=`）：根因 = 我写的一条**注释**里有 `%~fI`（cmd 对 REM 行**也做百分号替换**，非法 `%~X` **致命**）⇒ 证据 `matrix_only3_ABORTED_rem_token.log` + `probe_rem_tokens.bat`。删掉后全跑收口。

**指纹集变化（现核，两份 `P4_MATRIX_FINGERPRINT_*_before.txt` 逐条对差）**：
`FILES_COMPILE 201 → 212`（**+11 = board/wrapper_p4.v, board/util_gmii_to_rgmii.v, rtl/app_ctrl.v, rtl/app_pattern.v, rtl/app_status_uart.v, rtl/app_udp_pattern.v, rtl/udp_rx.v, rtl/udp_split.v, rtl/udp_tx_cfg.v, rtl/udp_tx_frame.v, tb/tb_p5_wrapper.v**）、
`FILES_ALL 237 → 257`（+20 = 上述 11 + `sim/p4gates/p5wrapper_src.f` + 7 个 `sim\p5sim\run_tb_*.bat` + `tools/gen_stim_p5_app.py`）、**REMOVED 0**。
⇒ ⭐ 本工程"**矩阵指纹看不见 `wrapper_p4.v` / `app_pattern.v`**"那条盲区被这次登记补上（**有前后对差为证**）。

### ④ 别名门 正/负/入口级
```
run_aliasgate.bat（活件）                 → ALIASGATE OK              rc=0
run_aliasgate.bat <mutant>                → ALIASGATE FAIL rc=1       rc=1
run_aliasgate_selftest.bat                → ALIASGATE SELFTEST PASS   rc=0（11/11）
run_lint_p7a.bat（真实入口）              → 首段 ALIASGATE OK；随后 p7a lint 跑满 → LINT-OK，rc=0
entry_negctl_run_lint_p7a.bat（改 1 行）  → 首段 ALIASGATE FAIL rc=1，入口 rc=1
run_tb_p5_wrapper.bat（standalone）       → P5 WRAPPER OK，rc=0（未回归）
```

### ⑤ 假阳性普查（全仓 wrapper 类文件 = **50 个**）
- **结果**：**21 条真反向**（全是旧修订/突变件/归档副本里真的带着这 5 行）+ **29 个正确干净**（其中 13 个是 pre-P6b 血统 —— 根本没有 `txsrc_*` 这层别名）+ **假阳性 = 0**。
- ⭐ 交叉校验：上一轮 diag 的三个**已修副本**（`work/{E,F,H}/wrapper_p4.v`）被判 **0 反向** ⇒ 两个独立检查器互证。
- ⭐ **一条值得上报的真阳性**：`vivado_prj/p7b_ku5p_prj.srcs/sources_1/imports/board/wrapper_p4.v`（**就是 CLAUDE.md 警告的"GUI 重编永久禁发陷阱"那份旧 import**）**仍带这 5 行反向别名** ⇒ 与"它还是 BID 0xA 旧版"警告方向一致；**未修**（写边界外）。同类还有 `p6b_ku5p` / `p6b_final_ku5p` / `p7b_lat`。

### ⑥ 行尾现核
```
board/wrapper_p4.v        4376 行 / CR=4376（纯 CRLF；改后 4378/4378）
rtl/tcp_rx.v              911 行 / CR=911（纯 CRLF）
rtl/tcb.v                 158 行 / CR=0（纯 LF）
run_matrix_p4dfix.bat     289 行 / CR=289；run_tb_p5_wrapper.bat 62 行 / CR=62（改后 70/70）
tools/gen_stim_p5_app.py 1454 行 / CR=0（纯 LF）；sim/p4gates/paths.txt 纯 LF
```
门本体**先归一化再匹配**；新建/改动的 `.bat` 全部 CRLF（复验 `bareLF=0`）。

---

## §4 仪器面 / 工具面：本轮新发现（都带实测）

1. ⭐ **`%~fI` 写在 REM 注释里 = 致命**。隔离实验（`probe_rem_tokens.bat`，三种变体各一行）：
   `%~dp0` 注释无害 · `%%I` 注释无害 · **`%~fI` 注释 ⇒ C-after 永不打印、RC=255**
   （`处理参数替换中的路径对符号的下列用法无效` + `命令语法不正确`）。在矩阵里它把**整轮**打断（`call` 出去的 bat 致命 ⇒ 连累 runner）。
   **教训：cmd 的注释不是惰性的。**
2. ⭐ **`find` 在本机 Git Bash 环境被 MSYS 抢走**（`where find` ⇒ `C:\Program Files\Git\usr\bin\find.exe` **先于** `System32\find.exe`）
   ⇒ bat 里 `find /c ...` 会跑 **Unix find**、把 `/c` 当路径**递归遍历 C:**（实测输出 = **41.9 MB 的 C: 全盘清单**）⇒ **脚本挂死**。
   ⇒ **门与自检一律不用 `find`**；`findstr` 无 MSYS 对应物，安全。
3. ⭐ **`findstr /n` 给的是"文件行号"不是"序号"**，且**裸的多词 pattern 按空格 OR 拆开**。
   `findstr /n "^call :gate "` 数门数 ⇒ **309**（最后一行的行号），打出 `gates run : 1 / 309` —— 自造读数 bug，改成
   `for /f … ('findstr /b /c:"call :gate " …') do set /a GATE_TOTAL+=1` 后 = **17** ✓。（不影响退出码 ⇒ 只能靠"跑一次并读 log"发现。）
4. （自伤，已自愈）"独立分类"脚本里名字拼错（`'txsrc_t'+'tdata'` = `txsrc_ttdata`）⇒ 一度把 21 条真阳性全判成未分类；靠对一条已知真值跑一遍当场定位。

---

## §5 覆盖面一句话（只读结论）

1. **编译/仿真面**：只有 `p5_wrapper` 一门编这两个文件，宏 = **`-d APP_MODE` 单宏**（不编 `DP_156MHZ`/`PCIE_OBS`/`DEV_USP`/`P7B_10G`/`UDP_TX_OVL`/`TCP_TX_OVL`）
   ⇒ 跑的是 wrapper 的**单域（legacy）分支** + `tcp_tx_frame` 的 **legacy 分支**（⇒ **r6 `ack_seen` 启动门不在其中**）。
   **既有 16 门一个都不编这两个文件**（`chain_src.f` 20 件里没有；`grep -l "app_pattern\|wrapper_p4" sim/p4gates/*.f` 只命中新清单）。
2. **指纹面**：这两个文件**首次进入编译集** ⇒ "矩阵绿但指纹没含被改文件"这类盲区对这两个文件**不再成立**。
3. ⛔ **不覆盖**（写死）：`DP_156MHZ` 板配置下的 wrapper 分支（`u_txcdc`/`fifo_async`/`:2768-2769`〔⛔ 2026-10-11 订正（行号）：该"正确写法对照"两行现核 = `:2779-2780`〕、`mac_tx_10g`+`P7B_10G` 前端、`PCIE_OBS` 快照段、两个 `*_OVL` 乒乓帧器），以及任何只在那些宏里存在的缺陷。
   **"矩阵全绿"绝不能读成"板配置被验过"。**
   ⭐ 补一句：**静态别名门**两配置都跑（含 `DP_156MHZ`）⇒ 就"别名方向"这一个面，板配置那一支**有静态覆盖**。

---

## §6 未做到 / 未判定（不掩饰）

1. **入口级红传播**用的是**逐字节副本 + 只改一行**（`entry_negctl_run_lint_p7a.bat`，`diff` = `33c33`），**不是**改仓内入口/仓内 RTL 造真红（纪律不许）。真实入口那一次绿是**真跑**的。
2. **本轮没有 xsim 直接复验"修后 `APP_MODE`-only 的 TX 真的活了"**：靠上一轮 E 臂三门 xsim 绿 + §2-① 的**逐词等价证明**；文本级等价是机械证明的，"再跑一遍 xsim"**没做**。
3. **别名门覆盖边界**：只覆盖**纯别名 + X 被实例 output 驱动**的形态；上一轮登记的"浮空表 194/198 残留"**未纳入**；反向但 X 非端口驱动的形态**只进 `UNRESOLVED` 计数、不置红**。门只保证**本族必红**。
4. **别名门不是矩阵行**：`manifestcheck` 语义 = "清单 == bat 里交给 xvlog 的文件表"，而本门**没有 xvlog 调用** ⇒ 硬塞会得"bat carries 0"的假红 ⇒ 常驻形态 = **lint 入口 + 独立 bat**。要矩阵可见性需改 runner 语义（**未做**）。
5. **`board/run_lint_p6e.bat` 没加这一行**（写边界）。
6. **`DP_156MHZ` 不带 `PCIE_OBS`** 的隐式网（上一轮登记）**未复现、未修**。
7. `sim/aliasgate/_selftest/` 会留下自检工件（mutant ≈265 KB + 跑动日志/wdb/xsim.dir + negctl 副本）；**不是参考件**，可删、可 ignore（删了自检仍能重建）。
8. ⚠️ **两份指纹互差的 4 个 rtl 文件不是我改的**：`rtl/{retx_ram,tcb,tcp_rx,tcp_tx_frame}.v` 在 11:31 与 05:35 两份指纹之间内容不同，对应提交 `15defaf → fa52438` 之间的 `dcf2bb6`/`34fb68b`；`git status` 显示它们**当前未改**。

---

## §7 ⚠️ 现核到与派单描述不符 / 需要订正的地方

1. **`p7a` lint 入口不会 97 拒绝**：派单推断"该入口自己的前置拒绝 ⇒ 位置靠后的面会不可达"。
   **现核：`p7a_prj` 在 `_proj_10g/vivado_prj/p7a_prj.gen/`（一开始查的是仓根 `vivado_prj/`，查错了）⇒ 入口今天跑满、`LINT-OK`、RC=0。**
   结论方向不变（仍放最前），但"今天必然 97"是错的。
2. **`run_tb_p5_wrapper.bat` 不能"只登记一行"**：旧头会让 `manifestcheck` 结构性看到 **0 个文件**（§3-② 实测），且它 `cd /d %~dp0` 会**绕过矩阵私有工作目录**（坑 7）、判据会去读 `sim\p5sim` 的**陈旧 memh**。
3. **那五行的"逐字"文本**：派单贴的样例与源码**不完全逐字**（`:2774` 是 `assign txsrc_tvalid= m_tx_tvalid;`，等号前无空格；缩进空格数也不同）。**语义完全一致**，按源码现状改。 ⛔ 2026-10-11 订正（行号）：`:2774` = 修复前旧号（该行修复后现核 = `:2787`）。
4. ⚠️ **行号变了**：加注释后那 5 行 → **2773-2777**。凡引用 `wrapper_p4.v:2771-2775` 的件（含 CLAUDE.md 置顶块、`P7B_OPEN_ITEMS.md`、上一轮 `REPORT.md`）**都需要一次行号订正**。 ⛔ **2026-10-11 订正（本行自身）**：`2773-2777` **也已过时** —— 其后 `fd671b6`（2026-10-10 20:46）+6 ⇒ `2779-2783`；现工作树（带另一支构建 agent 未提交 +5）再位移 ⇒ **现行真值 = `:2784-2788`**（两行订正注释 = `:2782-2783`）。
5. **"矩阵 16 门（`:163-178`）"**：修前 16 行确在 **163-178** ✓；现状 = **17 行**、新行在 **211**。
6. **census2.py "两配置假阳性 0"**：✅ 复现。做成门时**额外**加了"Y 是本模块 input/inout 端口 ⇒ 视为被驱动"（census2 无），并把"多驱动"单列；全仓 50 文件下**假阳性仍 0**。
7. **"接进 `board/run_lint_p6e.bat` 与/或 p7a"**：按写边界只能做**后者**；**如实登记为受边界所限**，不是遗漏。
8. **未被派单但必须报**：`p5_wrapper` 的判据行只有 `wrapper GMII: 3 帧`（TB 注释说"抓 ~7 帧"，上一轮也登记过）⇒ **未动 TB/判据**（写边界外），登记为既存事实。

---

## §8 证据文件清单（本目录）

```
REPORT.md（本报告）                    git_diff_wrapper_p4.txt / git_diff_stat.txt
wrapper_p4_HEAD_before_fix.v           fix_equiv_Earm.txt（落地修复 == E 臂，5/5 token）
sweep_all_wrappers.txt                 sweep_classify.txt / classify_sweep.py
run_aliasgate_green.txt                run_aliasgate_red_on_mutant.txt
run_lint_p7a_real.txt                  run_lint_p7a_entry_negctl.txt / entry_negctl_run_lint_p7a.bat
make_entry_negctl.py                   make_gate_negctl.py
gate_red_on_mutant_STDOUT.txt（门级红对照：0 帧 + FAIL + rc=1）
matrix_full17_console.txt / matrix_full17.log    matrix_p4dfix_prereg_archive.log（登记前 16/16 FROZEN）
matrix_only3_console.txt / matrix_only3_ABORTED_rem_token.log / matrix_only_p5wrapper_console.txt
p4gate_table_17gates.txt               probe_rem_tokens.bat
run_p5wrapper_STANDALONE.txt           selftest_final.txt
```

## §9 下一步建议（供 TL / 用户裁定）

1. **订正引用**：`wrapper_p4.v:2771-2775` → **2773-2777**。 ⛔ 2026-10-11 订正：本建议的**目标值也已过时** —— 现行真值 = **`:2784-2788`**（链见 §2-① 首处订正）。
2. **`board/run_lint_p6e.bat` 加同一行**（那正是编坏分支的入口）—— 需授权。
3. **`vivado_prj/*/imports/board/wrapper_p4.v` 四份仍带反向别名**（含 `p7b_ku5p_prj` 那份"GUI 陷阱"）⇒ 要么并入既有警告句，要么下次构建搭车同步（**未做**）。
4. **别名门扩到浮空表不建议**在没有豁免清单时做（上一轮已测 194/198 残留 ⇒ 会变噪声）。
5. `sim/aliasgate/_selftest/` 可 ignore 或删除（自检工件）。
