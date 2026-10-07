# Stage B / R1（`rtl/app_pattern.v` RX 8 路）—— **独立回归报告**

- 日期：**2026-10-07**　角色：**回归测试 agent**（独立于实现 agent）
- 基线：HEAD = **`e9a4d23`**，工作区**唯一** tracked 改动 = `rtl/app_pattern.v`（`git diff --stat` **+199 / −0**，
  sha256 **`da7a2c7c6876000b…`**，全程未变）+ 新 TB `tb/tb_app_rx8_equiv.v`（`fa66c451bee63803…`）
- 我做了什么：**全仓 16 门 P4 矩阵**（作者未跑）+ **作者未跑的追加门**（`p5_status`/`p5_pattern`/`p5d_multi`
  四档 + `p5_wrapper` 复核）+ **每一个红的 HEAD 双臂归属** + ⭐ **本轮头号任务：「两种盲」的裁定与可复算证据**
  （含一组**镜像树上的破坏实验**）+ **两条真 `P7B_10G` 门在真树上的重跑**
- 纪律：⛔ 不烧板 / 未写 `0x08` / 未碰板子；⛔ **未改任何既存源文件·TB·bat**（所有副本在 `sim/p7b_stageb_rx8_regress/`，
  破坏实验**只在镜像副本**上做）；⛔ 未提交 git、未 `git add -A`。**零位流、零板级读数。**
- ⭐ **收尾核账**：`rtl/app_pattern.v` = `da7a2c7c…99e1`、`tb/tb_app_rx8_equiv.v` = `fa66c451…`、
  `sim/p7b_stageb_rx8/app_pattern.v.orig` = `b6a9fa0e…` —— **与开工时逐字相同**；
  `git status` 的 tracked 改动仍只有 `M rtl/app_pattern.v`（+ 矩阵 runner 自己的产物 `sim/p4sim/matrix_p4dfix.log`，
  上一轮已登记为"runner 自己的输出路径"）。

---

## 0. 一页结论

| # | 问题 | 结论 |
|---|---|---|
| ① | 16 门 P4 矩阵 | **16/16 EXIT=0**，`gates failed: 0`，**`VERDICT: FROZEN`**（237 文件逐字不变）；逐门都有**真判据行**（不是只有 banner）；16 个 console 的 `grep -i fail` **全 0 命中** |
| ② | ⭐ **"16 门全绿"对本改动有没有判别力** | **没有 —— 两种盲同时成立，且各自都有可复算证据**（§3）。**机制 (a)**：`app_pattern.v` **不在任何一份清单/编译集里**（5 份 manifest、18 份 p4sim bat、runner、守卫、指纹**逐份 grep = 0 命中**）；**机制 (b)**：**16 门里没有一门带 `P7B_10G`/`APP_MODE`**（逐 bat 核过 xvlog 行：12 门 chain_src 族里 `chain`/`vlanchain` **无任何 `-d`**，`burst`/`burst_vlan`/`stall` 只带 `-d RTOLIM_FAST`/`-d RTOLIM_STALL`；4 个 unit 门无 `-d`），而被改的 199 行**全部包在 `P7B_10G` 内** ⇒ 即使把文件塞进清单，门**照样看不见**（M2 实测：文件确实进了 xvlog，仍 `P4 CHAIN OK`） |
| ③ | ⭐ **可复算证据**（镜像树，不碰真树） | 把 `app_pattern.v` **真改坏一个字节**（删掉 `xs_next8[63]` 行的 `;`，落在 `P7B_10G` 块内）放进**镜像树的 `rtl/`**：<br>**M1**（不进清单）`EXIT=0` / `P4 CHAIN OK` / **与真跑逐行相同**；<br>**M2**（加进 manifest **和** bat 的 xvlog 表）**仍然** `EXIT=0` / `P4 CHAIN OK`（xvlog 日志证明**文件确实被编译了**）；<br>**M2p**（M2 再加 `-d P7B_10G`）**`EXIT=1`** + `VRFC 10-4982 syntax error near 'xs_next8' … app_pattern.v:97`。<br>⇒ **矩阵要看见这行代码，需要同时补两样（进清单 + 开宏），少一样都看得见"绿"而看不见代码** |
| ④ | 本仓哪条门真的用 `P7B_10G` 构建 | **全仓清单见 §3.4**（去全域找过）。其中**编译 `app_pattern.v` 且开宏**的只有 `_proj_10g/p7b_chain`（+ ratefrm 副本）、`_proj_10g/p7b_appsplit`、作者新门 `sim/p7b_stageb_rx8`。**三条里只有作者新门真正驱动 app 的 RX 路径**（chain/appsplit 的 TB 连 "tcp" 一词都不出现）⇒ **R1 的可覆盖性全部押在那一条新门上** |
| ⑤ | 作者未跑的追加门（6 次执行） | `p5_status` **绿** · `p5_pattern` **红（既存，且对本改动 5 路零敏感）** · `p5d_multi` 三个负对照 **红得正确**（`neg_wq` 24 FAIL / `neg_mgn` 7 FAIL / `neg_mgn0` 4 FAIL，组成与上一轮逐条相同）· `known_idle_fifo` **绿** · `p5_wrapper` **红（既存，5 路逐字节相同）** |
| ⑥ | 每一个红的归属 | **全部 6 个红都有双跑对照**（§5）：`p5_wrapper`/`p5_pattern`/`p5d` 三红的**工作区臂 vs HEAD 臂整份日志 md5 相同**（`known_idle_fifo` 是绿臂，也做了双臂、md5 相同）；`p7b_chain` 的 HEAD 臂 105 PASS + 同一条 FAIL、**过滤后 diff 0 行**。**没有一个新红。** |
| ⑦ | 超出派单的追加 | ⭐ **真 `P7B_10G` 门重跑**：`p7b_appsplit` = **`26 checks, 0 fail` / EXIT=0**（复现作者的 26/0）；`p7b_chain` = **105 PASS + 1 FAIL（`0xEC` 陈旧判据）**；⭐ **作者那条 RX8 门我独立重跑 = `RX8-GATE: PASS` / EXIT=0**，六臂全部按声明表现、读数与作者 §3 表**逐字相同** |

---

## 1. 环境与并发（读数归属的前提）

| 项 | 值 |
|---|---|
| 仓库 | `D:\repo\XCKU5PMini\udp_hls_10g`，`git rev-parse HEAD` = **`e9a4d23`** |
| 我的独占工作目录 | **`sim/p7b_stageb_rx8_regress/`**（矩阵入口、镜像树、HEAD 臂、变异件、日志全在这里） |
| 我改过的**已跟踪**文件 | **无**（`M sim/p4sim/matrix_p4dfix.log` 是 runner 自己的产物路径，同上一轮登记） |
| 矩阵运行窗口 | **11:55:15 → 12:23:15**（≈28 min，16 门） |
| 我自己造成的重叠 | **无**（追加门/镜像臂/HEAD 臂/真 `P7B_10G` 门全部**串行**跑） |
| 同机并发（实测） | `tasklist` 三点取样：**11:55:07 零** / **11:58:02 零**（门外间隙）/ **12:03:02 2 个**（= 我自己那串；12:23:33 追加门开跑前**零**）。⚠️ **但另一个 agent 确实在我的窗口内跑过仿真**：`sim/p7b_stageb_rx8_review/**`（对抗审查 agent 跑同一条 RX8 门的 `runA..runF`）在我窗口内有新写 ⇒ **不能宣称"全程只有我一个 sim"**；能宣称的是：16 门**全绿且每门都有真判据行**、**没有一个"孤零零一条红"**、而所有呈现的红**都在第二次执行里逐字节复现** ⇒ 按全局 #50/#48 口径**无需隔离复跑** |

---

## 2. 全仓 16 门 P4 矩阵（作者未跑 · 我跑了）

**逐字命令**（自定位 runner；git bash 经 `cmd //c` 调 .bat）：
```bash
# 我的唯一入口（3 行 bat：cd 到仓根 → 调 runner → 记退出码）
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p7b_stageb_rx8_regress\run_matrix_here.bat'   # 退出码 0
# 两列取数器
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stageb_rx8_regress/collect_matrix.py \
    sim/p4gates/work_20261007_115515 sim/p7b_stageb_rx8_regress/matrix_p4dfix.log
```

**总结行（逐字）**：`gates run : 16 / 16` · `gates failed: 0` · `MATRIX_BAT_EXITCODE=0` ·
`VERDICT: FROZEN -- all 237 hashed files byte-identical across the run` ·
`DIGEST_COMPILE=1dc184324e64374e…` · `DIGEST_ALL=eeda6b6a62efb39a…` · `GIT_HEAD=e9a4d23`

### 2.1 逐门表（**两列都抓**；A 列 = 矩阵日志里的判据行，B 列 = 门自己 work 目录的 console）

| # | 门 | EXIT | A/B 列关键判据行 |
|---|---|---|---|
| 1 | `chain` | 0 | `frames RX=9 TX=11 (fast=6 slow=5)  STRIPPED=0` → **`P4 CHAIN OK`** |
| 2 | `burst200` | 0 | `TRUNCS (0,0) ECOMAX 182` · `STATS_MAC (411,0,0)` → **`BURST OK`** |
| 3 | `trunc50` | 0 | `BURST OK`（判据行同上） |
| 4 | `trunc100` | 0 | `BURST OK` |
| 5 | `halfdrop` | 0 | `BURST OK` |
| 6 | `txdrop50` | 0 | `BURST OK`（`STATS_MAC (416,0,0)`） |
| 7 | `gate4096` | 0 | `BURST OK`（`TCBF (…,4096,…)`） |
| 8 | `dupstorm` | 0 | `BURST OK`（`STATS_MAC (455,0,0)`） |
| 9 | `pcackoob` | 0 | `BURST OK` |
| 10 | `vlanchain` | 0 | `STRIPPED=2 (期望 2, VLAN ON)` → **`P4 CHAIN OK`** |
| 11 | `vlanburst` | 0 | `STRIPPED 202 (期望 202, VLAN ON)` → **`BURST OK`** |
| 12 | `stallgate` | 0 | `PCSTALL 停摆拍=… 水位=…` → **`PCSTALL OK (burst=200, echo 帧 240)`** |
| 13 | `unit_retx` | 0 | ⚠️ 该门 bat 以 `type xsim.log` 收尾（**exit 0 无条件**）⇒ 读 B 列：`GRP C..G : PASS` + **`ALL 7 GROUPS PASS`** |
| 14 | `unit_fifo` | 0 | ⚠️ 同上无条件 exit ⇒ B 列：**`PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700`** |
| 15 | `unit_vlan` | 0 | **`VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)`** |
| 16 | `unit_uart` | 0 | **`ALL_OK`** + **`UART-GATE-OK`** |

**附加硬扫描**：16 个 `_gate_console.log` 里 `grep -i fail` **命中数全部为 0**；每门 `scanlog` 报 `0 outside the repo`。

---

## 3. ⭐ 头号任务：两种"盲"的裁定 + 可复算证据

### 3.1 机制 (a)：**清单里根本没有这个文件**（逐份 grep，0 命中）

| 检查对象 | 命令 | 命中 |
|---|---|---|
| 5 份 manifest | `grep -n app_pattern sim/p4gates/*.f` | **0** |
| 18 份 p4sim 门 bat | `grep -rn app_pattern sim/p4sim/*.bat` | **0** |
| runner / 守卫 / 配置 | `grep -n app_pattern sim/p4gates/{run_matrix_p4dfix.bat,p4gate.py,paths.txt,p4env.bat}` | **0** |
| 矩阵**修订指纹**（237 文件） | `grep -c app_pattern sim/p4sim/P4_MATRIX_FINGERPRINT_20261007_115515_before.txt` | **0** |

⭐ 而且 **runner 自己的指纹头**逐字写着：

```
#   compile set: 201 files (manifests: chain_src.f, retx_src.f, fifo_src.f, vlan_src.f, uart_src.f)
#   extra      : 36 files (generators/bats/criteria)
#   total      : 237 files hashed
# MODIFIED vs HEAD (tracked, inside the hashed set): none
```

——**同一时刻 `git status` 明明有 `M rtl/app_pattern.v`**。"指纹里没有你"这件事被 runner 亲口说出来。

⭐ **跨 revision 的指纹同一性**（最便宜、最硬的一刀）：把**我这一轮**的 237 条 `(path, sha256)` 表
与**上一轮**（`P4_MATRIX_FINGERPRINT_20261007_084942_before.txt`，`GIT_HEAD=95c9485` —— **上一轮跑的时候 R1 还不存在**）
逐行 diff：**`diff` 输出 0 行**；两轮的 `DIGEST_ALL` 都是 `eeda6b6a…299d`。

### 3.2 机制 (b)：**清单里有、但宏关构建选中的是别的代码**

- **16 门里没有一门打开 `P7B_10G`（也没有 `APP_MODE`）**：`sim/p4sim/run_tb_p4_chain.bat` 的 xvlog 行逐字
  **没有任何 `-d` 开关**；`run_tb_p4_burst.bat` / `_burst_vlan` / `_chain_stall` 只带 `-d RTOLIM_FAST` /
  `-d RTOLIM_STALL`（TB 侧 RTO 缩放的**测试专用**宏，与 app 无关）；4 个 unit 门无 `-d`。
  R1 的 **+199 行全部包在 `ifdef P7B_10G` 内** ⇒ 预处理器**原样吐回**原语句。
- **独立复核（我自己的极简预处理器，不是作者的工具）**：无宏时预处理结果 **逐字节相同**（32698 B / 32698 B）；
  带 `P7B_10G` 时 748 行 vs 557 行；diff **+199 / −0**。⇒ 宏关下**源级等价**（不是"我没看出来差别"）。
- **p5 一族（唯一"单独编译 `app_pattern.v`"的门族）全是宏关**：
  `sim/p5sim/run_tb_p5_{app,flow,pattern,wrapper}.bat` 的编译行分别只带 `-d APP_MODE` / `-d P5_FLOW` /
  `-d P5_CLOSE -d APP_MODE`（`p5_pattern` 与 `p5_app` 默认档**连 `-d` 都没有**），
  **一个 `P7B_10G` 都没有**；`sim/p5d_multi`（`-d P5D_NEG_MGN*`）、`sim/p6e_pcie`
  （`-d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ`，**无 `P7B_10G`**）同。
- ⭐ **xvlog 直接量**（我自己跑的，2 秒一轮）：

  | 变异件 | 宏关 | 宏开 |
  |---|---|---|
  | `mutB`（语义：`xs_word8[63] = s[31]` → `s[21]`，**恰好 1 字节差**） | RC **0** | RC **0** |
  | `mutS`（语法：`xs_next8[63]` 行尾 `;` 删掉，**1 字节**） | RC **0** | RC **1**（`VRFC 10-4982 syntax error near 'xs_next8'` @ **:97**） |

  ⇒ **宏关构建对 `P7B_10G` 块内的任何内容（连语法错误）结构性全盲。**
- ⭐ **门级 5 路同一性**（`p5_pattern`，全仓唯一单独编译该文件的既有门）：
  工作区(R1) / HEAD / `mutB` / `mutS` / **上一轮（R1 之前）的基线日志**
  五份输出 **md5 全部 = `6e9c6f45cc363fc72437f26f682ad47d`**，EXIT 全 0。

### 3.3 ⭐ 镜像树破坏实验（**可复算**；真树一个字节没动）

**做法**：把门机制 + `rtl/`+`tb/`+`tools/`+`hls`（+指纹所需的 7 个文件）**复制**到 `sim/p7b_stageb_rx8_regress/mirror/`
（runner 自定位 ⇒ 该树的 `REPO_ROOT` = 镜像根，**编译的是镜像里的源**）；破坏件 = **`mutS`（删 1 个字节）**。
状态脚本 = `setup_arm.py`（每次重置 bat/manifest，可反复复算）。

| 臂 | 镜像 `rtl/app_pattern.v` | 清单/bat | 宏 | 结果（逐字） |
|---|---|---|---|---|
| **M1** | **mutS（坏）** | 不动 | 关 | **`EXIT=0`** · **`P4 CHAIN OK`** · `frames RX=9 TX=11 (fast=6 slow=5) STRIPPED=0` —— **与真树 chain 门 console 逐行相同**（仅守卫行的 root 路径不同） |
| **M2** | **mutS（坏）** | **加进 `chain_src.f` + bat 的 xvlog 表** | 关 | **`EXIT=0`** · `P4 CHAIN OK`；xvlog 日志里确有 `Analyzing Verilog file ".../mirror/rtl/app_pattern.v"` ⇒ **文件真被编译了，照样全绿** |
| **M2p** | **mutS（坏）** | 同 M2 | **开（`-d P7B_10G`）** | **`EXIT=1`** + `ERROR: [VRFC 10-4982] syntax error near 'xs_next8' […/mirror/rtl/app_pattern.v:97]` |

**附**：镜像树自己跑一次指纹（文件坏着）⇒ `FILES_ALL=237`、**`DIGEST_ALL = eeda6b6a…299d`**，
与真树、与上一轮**逐位相同**（我用独立脚本从两份表重算 digest，也逐位相同；
唯一差异是镜像那份打印的 `DIGEST_COMPILE` 不同 —— 属该工具的**路径归一化派生物**，
237 条 `(path, sha256)` 集合经集合比对**完全相同**，不影响任何结论）。

**⇒ 判决**：
> **"16 门全绿"对本改动零判别力。** 要让它有判别力，**必须同时**做到：① 把 `app_pattern.v` 加进某份 manifest/bat 的编译表；
> ② 该门用 `-d P7B_10G` 构建。**两件都做了，一个字节的语法错误就会响亮变红**（M2p）。

### 3.4 全仓 `P7B_10G` 门清单（去全域找过）

| 门/入口 | 用 `P7B_10G` | 编译 `app_pattern.v` | 是否驱动 app 的 **RX 路径** | 我是否重跑 |
|---|---|---|---|---|
| `_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat`（+ `notes/p7b_ratefrm/run_chain_gate{,_ovl}.bat` 是同一门的副本） | ✅ | ✅（`dir /b /s %ROOT%\rtl\*.v`） | ❌（TB 里 **"tcp" 出现 0 次**；它是 MAC/XGMII 链级门） | ✅ **105 PASS + 1 FAIL**，见 §5.5 |
| `_proj_10g/p7b_appsplit/sim/run_tb_p7b_appsplit.bat` | ✅ | ✅（同上 glob） | ❌（它驱动的是 **UDP** split 路径） | ✅ **`26 checks, 0 fail` / EXIT=0** |
| `sim/p7b_stageb_rx8/run_rx8_gate.bat`（**作者新门，单元级**） | ✅ | ✅（直接喂该文件） | ✅ **唯一一条** | ✅ **`RX8-GATE: PASS` / EXIT=0** |
| `sim/p5e_rate/run_tb_rate.bat`（`p7b1472` 档） | ✅ | ❌（编的是 **`app_udp_pattern.v`**，UDP 版） | ❌ | 未跑（作者未派单；与 R1 无交集） |
| `sim/p5wu_p1p2/run_xvlog_wrapper63.bat` / `notes/p7b_biz_win/run_xvlog_wrapper.bat` | ✅ | ❌（**只编 `wrapper_p4.v`**，编译面检查） | ❌ | 未跑 |
| `board/build_p7b_ku5p.tcl` / `vivado_prj/**` | ✅ | ✅ | 构建（非门） | ⛔ 按纪律不跑构建 |
| 其余命中的 `_tmp_w9*` / `notes/p7b_rate8` / `notes/p7b_gatecov` / `notes/p7b_lane4` 等 | 部分 ✅ | 视门而定 | 都针对 **UDP** `app_udp_pattern` 或 MAC | 未跑（非 R1 面） |

> ⚠️ 结论：**R1 的全部可覆盖性押在作者那一条新门上** —— 别的 `P7B_10G` 门就算编了它，也从不驱动它的 RX 路径。

---

## 4. 作者未跑的追加门（**我做**；副本在我的 scratch，canonical 目录零写入）

| 门 | EXIT | 关键读数（逐字） | 归属 |
|---|---|---|---|
| `p5_status` | **0** | `STATUS got : 'P5B1 ST=1 NX=12345679 … UTB=12345678 UTF=0BB8'` 与 `exp` 逐字符相同 → **`P5 STATUS OK`** | 绿 |
| `p5_pattern` | **0（内容却是 FAIL）** | **`P5 PATTERN FAIL viol=0 last_beats=2 keep_bad=1 active=0`** + 两行 W3 | ⭐ **既存红 + 对本改动零敏感**（§3.2 的 5 路 md5）；⚠️ 该 bat 末行是两句 `findstr`，**退出码与 PASS/FAIL 无关**（老坑，现役） |
| `p5d_multi neg_wq` | **1** | `== P5d multi: 112 checks, 24 FAIL ==`（组成 **21×①+2×⑥+1×⑦**）+ `[neg_wq] 期望 ① FAIL` 断言在 | 设计性红 ✔ |
| `p5d_multi neg_mgn` | **1** | `112 checks, 7 FAIL`（**7 条全是 ④**） | 设计性红 ✔ |
| `p5d_multi neg_mgn0` | **1** | `112 checks, 4 FAIL`（⑥×2+⑦×2）+ `[neg_mgn0] 期望 ⑦ FAIL: seq=2 rewind=2` | 设计性红 ✔ |
| `p5d_multi known_idle_fifo` | **0** | `[probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728` | 绿 |
| `p5_wrapper` | **1** | `wrapper GMII: 0 帧 (conn0 数据 0 / 其它 0 / 坏 FCS 0)` → `MISMATCH: wrapper 只出了 0 个 conn0 数据帧 (<2)` → **`P5 WRAPPER FAIL (1 项)`** | ⭐ **既存红**（§5.2，**5 路逐字节相同**） |

⚠️ **读法坑**：`neg_*` 三档的 `EXIT=1` 是**设计使然**（注入缺陷打红 ①/④/⑦ ⇒ 检查器 `return 1`）——
**"红的名单"才是判据**，我逐条比对过（§5.3）。

---

## 5. 逐红归属（**每一个红都配双跑对照**）

| # | 红 | 工作区臂 | HEAD 臂（`git show e9a4d23:` 的 `app_pattern.v` 放进 `head_rtl/`，其余全同） | 判定 |
|---|---|---|---|---|
| 5.1 | `p5_pattern` 内容 FAIL | EXIT 0，md5 `6e9c6f45…` | EXIT 0，**md5 相同**（另有 mutB/mutS/上一轮基线，共 5 路相同） | **既存**，且对本改动**零敏感** |
| 5.2 | `p5_wrapper` FAIL | EXIT 1，md5 `e042afb3…` | EXIT 1，**md5 相同** ⇒ **与上一轮的工作区臂、上一轮 HEAD 臂、上一轮 HEAD 隔离重跑臂全部逐字节相同（5 路）** | **既存**（根因仍未定位，同上一轮登记） |
| 5.3 | `p5d neg_wq` | EXIT 1，`112/24 FAIL`（21①+2⑥+1⑦） | EXIT 1，**整份日志 md5 相同**（`a4328ad1…`） | **设计性红**，零敏感 |
| 5.4 | `p5d neg_mgn` | EXIT 1，`112/7 FAIL`（7④） | EXIT 1，**md5 相同**（`3ca6cd14…`） | 同上 |
| 5.5 | `p5d neg_mgn0` | EXIT 1，`112/4 FAIL`（2⑥+2⑦） | EXIT 1，**md5 相同**（`2a83a99e…`） | 同上 |
| 5.6 | `p7b_chain` 单条 FAIL（**超出派单，我加的**） | EXIT 1，`105 PASS` + `[FAIL] 7b 0xEC reads 0 no wrap  src=axi_regs decode; 51-word bound`，`VERDICT = FAIL` | EXIT 1，`105 PASS` + **同一条 FAIL**，`VERDICT = FAIL`；**过滤后 diff = 0 行** | **既存** —— 该判据的 TB 注释逐字写着 "**51 字**占 0x20..0xE8 ⇒ 0xEC 必须读 0"，而快照窗口 **BIZ 轮起 61 字 / Stage A 起 63 字** ⇒ **陈旧判据**（09-30 的 136 门台账里此门 `VERDICT = PASS`，那时正好 51 字） |

**（`known_idle_fifo` 是绿，但也做了双臂：两份日志 md5 相同 `6e9b42dd…`。）**

---

## 6. 未测 / 未定位清单（**不许当已答**）

| # | 项 | 状态 |
|---|---|---|
| ① | 16 门矩阵**对 R1 的判别力** | **= 0**（§3）。**修法不在本轮范围**：要么把文件并进带宏的门，要么为新代码**新增一条带宏的编译器面门** |
| ② | `p5_wrapper` 红的**根因** | **仍未定位**（只证明了"与本轮无关"）。症状同上一轮：TB 的 APP_MODE 激励产不出帧 |
| ③ | `p7b_chain` 的 `0xEC` 陈旧判据 | **未修**（越界）。⚠️ 任何用它做验收的轮次都会**必然红**，且是**既存红**；同族还有 `sim/p6e_pcie` 的 `0xEC`/`BID=7` 双硬编码（上一轮已登记） |
| ④ | 作者的 RX8 门**之外**的 R1 覆盖 | **没有**（§3.4）。该门是**单元级**（直接例化 `app_pattern`，不经 `tcp_rx`/`frame_fifo`/真 wrapper 的 app 路径）—— 作者的 §5 已自陈，我复核同意 |
| ⑤ | `tcp_rx` 190 拍（RX 单路 10G 的真正限速级） | **未测**（不属本轮；作者 §5-2 已登记） |
| ⑥ | 构建读数（面积/时序） | **零**（我没跑综合/实现；纪律：不烧板） |
| ⑦ | `p5e_rate` / `p5wu` 编译面门 / `_proj_10g/notes/p7b_rate8` 一族 | **未跑**（非 R1 面；派单外） |
| ⑧ | 我跑过的门里 `unit_retx`/`unit_fifo` 的 `EXIT=0` | **假的**（bat 以 `type` 收尾）⇒ 我已按 B 列读真判据（`ALL 7 GROUPS PASS` / `PASS_ALL`） |

---

## 7. 证据地图（全部在 `sim/p7b_stageb_rx8_regress/`）+ 逐字命令

```bash
# ---- ① 16 门矩阵（28 min）----
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p7b_stageb_rx8_regress\run_matrix_here.bat'
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stageb_rx8_regress/collect_matrix.py \
    sim/p4gates/work_20261007_115515 sim/p7b_stageb_rx8_regress/matrix_p4dfix.log

# ---- ② 作者未跑的追加门（E2 变异臂在前）+ HEAD 双臂 ----
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\run_extra_gates.bat'
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\run_p5d_gates.bat'
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\run_head_arms.bat'

# ---- ③ 镜像树破坏实验（先 setup，再跑该臂）----
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stageb_rx8_regress/setup_arm.py M1_mutS_blind
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\run_arm_M1_mutS_blind.bat'
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stageb_rx8_regress/setup_arm.py M2_mutS_inset
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\run_arm_M2_mutS_inset.bat'
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stageb_rx8_regress/setup_arm.py M2p_mutS_inset_macro
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\run_arm_M2p_mutS_inset_macro.bat'

# ---- ④ 真 P7B_10G 门（真树）+ 作者 RX8 门独立重跑 ----
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\extra\p7b_chain\run_tb_p7b_chain.bat'
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\extra\p7b_appsplit\run_tb_p7b_appsplit.bat'
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\extra\p7b_chain_head\run_tb_p7b_chain.bat'   # HEAD 臂
cmd //c 'D:\...\sim\p7b_stageb_rx8_regress\author_gate\run_rx8_gate.bat'
```

| 文件 | 内容 |
|---|---|
| `matrix_stdout.log` / `matrix_two_column.txt` / `matrix_p4dfix.log` | 矩阵 stdout（逐门 `GATE x EXIT=n` + `MATRIX_BAT_EXITCODE=0`）/ 两列提取 / 矩阵日志原件副本 |
| `extra_log_p5_{pattern,pattern_mutB,pattern_mutS,pattern_head,status,wrapper}.txt` | 追加门与 E2 变异臂读数 |
| `extra_log_p5d_{neg_wq,neg_mgn,neg_mgn0,known_idle_fifo}.txt` + `head_log_p5d_*` | p5d 四档 工作区臂 / HEAD 臂 |
| `head_log_p5_{wrapper_head,pattern_head}.txt` · `p7b_log_p7b_{chain,chain_head,appsplit}.txt` | HEAD 臂 · 真 `P7B_10G` 门（含 HEAD 对照臂） |
| `arm_M{0,M1,M2,M2p}*.log` · `mirror/sim/p4sim/matrix_p4dfix.log` · `mirror_fp_test.txt` | 镜像树各臂 stdout / 镜像树自己的矩阵日志（含 `VERDICT: FROZEN`）/ 镜像树指纹 |
| `mut/app_pattern_mut{S,B}.v` · `mut_rtl_mut{S,B}/` · `head_rtl/` | 两个**单字节**变异件 / 变异 rtl 目录 / HEAD 版 rtl 目录 |
| `author_gate/`（含 `runA..runF`） · `author_gate_stdout.txt` | 作者 RX8 门的**独立重跑**（逐字副本 + 仅改路径深度） |
| `setup_arm.py` · `collect_matrix.py` · `run_*.bat` | 可复算的入口脚本 |

---

## 8. 一句话交给 TL

**矩阵 16/16 全绿 + 6 个红（含 1 个我自己加跑的真 `P7B_10G` 门）全部逐字节归属为既存/设计性 ⇒
在本轮改动可被观测的范围内，没有引入任何回归；但"16 门全绿"这件事本身对本改动零判别力**
（两种盲：文件不在清单里 + 门是宏关构建 —— 两者都已被**镜像树上的单字节破坏实验**实证）；
**R1 的全部覆盖押在作者那条新门上，而我独立重跑它 = `RX8-GATE: PASS`（六臂按声明表现、读数与作者逐字相同）**；
⚠️ 下一轮若要"矩阵看得见 Stage B 这类改动"，需要**同时**补清单与宏，
另有两笔**已存在**的陈旧判据（`p7b_chain` / `p6e_pcie` 的 `0xEC`）会在任何用它做验收的轮次里**必然红**。
