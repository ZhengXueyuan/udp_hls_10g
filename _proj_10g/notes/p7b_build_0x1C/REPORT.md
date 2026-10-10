# 构建 agent 报告（P7b 缺陷刀 / BID `0x1C`）

> ⚠️ **落盘说明**：本件正文由构建 agent 回传（两段），**TL 代落盘**（该 agent 的 `REPORT.md` 写入被平台策略拒绝："Subagents should return findings as text, not write report files"）。内容逐字保留（含它自己的措辞与口径订正），仅把第二段的 artifact map 附在结尾。

**边界声明**：未烧录、未连 JTAG/hw_server、未碰板卡、未 ssh 对端、未写 QSPI、未改 `rtl/`·`tb/`·`sim/`、未走 GUI/`vivado_prj`。只改了 `board/wrapper_p4.v` 指定行；git 只读（未提交）。

---

## 步骤 1：归档核对（含 F 的 dcp 欠账）

**① F/ 开工前实况（原话）**：`ls -la _proj_10g/notes/p7b_buildF_build/F/` = **16 件**（`F_bat_stdout.txt` + `SHA256SUMS.txt` + 5 份 board rpt + `runme_impl_1.log` + `wrapper_p4.bit`(15,431,261 B) + 7 份 impl rpt）；**⛔ 里面没有 `wrapper_p4_routed.dcp`** —— 台账队列 §3-12 / OPEN_ITEMS #26(C13) 描述属实。

**② 全盘找 F 的 dcp —— 找到了**【事实】：
- 活路径 `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp` = **60,011,449 B**，sha256 `737a1418b9a2d7a189a45f95cb52b214027f3680beb4c36728dfae96179aef6e`。
- **归属判定（两条独立）**：该目录里的 `wrapper_p4.bit` sha256 = `89e89f31…0f4400f45` **与 `F/SHA256SUMS.txt` 逐字相同** ⇒ 现役 impl_1 就是构建 F 的 impl_1；且该 dcp 尺寸在**全盘所有 `wrapper_p4_routed*.dcp` 中唯一**（E=`2f90c801…`、D=`48c553a7…`、Build2=`…` 均不同）。
- ⚠️ 台账 §9-4 写的"F 的 dcp **疑似全盘不存在**"⇒ **订正：它一直活在活路径上，只是没进 `F/`**（若我不救，本步构建的 `create_project -force` 就会抹掉它）。
- **已复制进 `F/`**（`cp -p`），复制后 sha256 逐字相同 ⇒ `F/` 现为 **17 件**。步骤 1 的"开工前清单"（17 条 sha256+字节）已算出并与报告同录；原 15 条 `sha256sum -c SHA256SUMS.txt` **零非 OK 行**（清单自洽）。

**③ 构建后对账（本步构建的预归档步）**：
```
ARCHIVE_SHA256_OK
ARCHIVE_DONE 20261011_002044 files=19 dir=...\_proj_10g\notes\p7b_build_archive\20261011_002044
```
（**本版无 ARCHIVE_SKIP**。）19 件中与 `F/` 重叠的 **15 条逐字相同**（含 **`wrapper_p4.bit` = `89e89f31…`** 与 **`wrapper_p4_routed.dcp` = `737a1418…`**）；归档另带 4 件（`SHA256SUMS.txt`(新)、`runme_synth_1.log`、`wrapper_p4_synth.dcp`、`wrapper_p4_utilization_synth.rpt`）。`F/` 自身未被构建触碰（仍 17 件）。**⇒ F 档取证已被归档目录完整收走**（`F/` 独有的 `F_bat_stdout.txt` 与 F 的 `SHA256SUMS.txt` 属轮内台账件，归档脚本按设计不收，另写自己的 SHA256SUMS）。

## 步骤 2：`board/wrapper_p4.v` 改动（四行）

**改前 `git status`**：仅 ` M board/wrapper_p4.v` 无（当时干净）；**无别的写者**。⚠️ 期间 TL 提交了 `50828c9`（23:48:27，**只动台账 .md，+66 行**，不在矩阵指纹面内）——矩阵指纹取于 23:48:51，晚于该提交。

**行号核对**：派单给的 `:2150`/`:2144`/`:4058`/`:4060` **本轮回全中**（未漂），改动后为 `2144`(注释) / `2155`(使能行) / `4063`(BID)。

| 行 | 改前 | 改后 |
|---|---|---|
| 使能行 | `.PERSIST_EN(1'b1)` | **`.PERSIST_EN(1'b0)`** |
| 注释(2144) | "`.PERSIST_EN(1'b1)` = 本刀唯一打开的功能开关" | 本轮配置：`1'b0` ⇒ persist RTL **可证惰性**（两腿：静态检查零例外 + arm B 读数逐字相同；**腿①/腿②各带出处文件名**）⇒ 本版归因 = 缺陷刀 + 构建 F 基线；persist 留 `0x1D` |
| BID(4058→4063) | `32'h0000001B` | **`32'h0000001C`** + 改判理由（`0x1B` 已绑给 persist（`fd671b6`）⇒ 本版不能沿用；**缺陷刀=0x1C / persist 留 0x1D / `0x1B` = "已分配、从未构建"**） |
| 注释(4060) | "内容 = 加 `.PERSIST_EN(1'b1)`" | 内容 = **重放越界缺陷修复**（`whi_r`/`ring_hi` 高水位 + `ring_ovf` 钳位 + `ring_restore` 收尾恢复写；**两分支镜像**，带 OVL `:491/:795`、else `:1594/:1690` 现读行号）+ 读侧 `EXPECT_BID` 需 0x1A→0x1C（本刀未碰读侧） |

**注释里的两条断言我逐条现核过**（【事实】）：
- **静态检查零例外** ✓：`p7b_persist_impl/ev/static_check_formal.txt` = `[S1] 新增信号 22 个 / 写点 26 处 ==> 零例外` + `STATIC_CHECK_PERSIST: PASS`；同目录 `static_check_selfcheck.txt` 三个负对照都有牙。
- **arm B 读数逐字相同** ✓（**带一处口径订正**）：`ev/xs_runB_after.log` 对 `base/xs_runB_baseline.log` —— **17 条判据行两两逐字相同**、`$finish` 时间**逐位同为 `2279132800 ps`**；**但两个文件不是逐字节相同**（差异仅 = 会话时间戳 / PID / 可用内存 / `$finish` 里 TB 行号 1556→2438 的元信息）。⇒ 我写进源码的措辞就是"17 条判据行逐字同 + `$finish` 时间逐位同；文件级只差元信息"，**未按字面『整文件逐字相同』写**。

**CRLF 核对**：改前 4390 行 / 272,890 B / CRLF 4390 / **裸 LF=0 裸 CR=0**；改后 **4405 行 / 274,458 B / CRLF 4405 / 裸 LF=0 裸 CR=0 / 以 CRLF 结尾** ⇒ **仍纯 CRLF**。指纹：sha256 `dd9fb07da5ba01213a46f10850785480a9e4ac62614862f07ad2796451ba2aef`，md5 `747b6ca222c97c4a984f0471a39c7b8e`。`git diff --stat`：`1 file changed, 28 insertions(+), 13 deletions(-)`（仅该文件）。

## 步骤 3：全量常驻矩阵（17 门）

`cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'`（自定位入口）——**退出码 0**。原始行：
```
[P4GUARD OK] root=d:\repo\xcku5pmini\udp_hls_10g self=... manifests=6
Verdict/汇总:  gates run : 17 / 17
               gates failed: 0
VERDICT: FROZEN -- all 257 hashed files byte-identical across the run; this log is bound to
         revision DIGEST_ALL(content)=34bf1e5a83a93634ee17c990ae0eb49fb3debc12c46385ed41d9d55bdbc243ee
MATRIX DONE 2026/10/11 周日 0:15:37.95
```
- **门计数 = 17/17，红 = 0**；17 门逐门 `EXIT=0`（chain · burst200 · trunc50 · trunc100 · halfdrop · txdrop50 · gate4096 · dupstorm · pcackoob · vlanchain · vlanburst · stallgate · unit_retx · unit_fifo · unit_vlan · unit_uart · p5_wrapper）。
- **无静默门**：两门"无条件 exit 0"的日志尾已读 —— `unit_retx` = `ALL 7 GROUPS PASS`；`unit_fifo` = `PASS_ALL`（+6 条 `PASS_ph_*`）。其余 = `VLAN_STRIP TB PASS` / `UART-GATE-OK` / `P5 WRAPPER OK` / `P4 CHAIN OK` / `BURST OK`。
- **指纹守卫**：BEFORE/AFTER 的 `DIGEST_COMPILE/DIGEST_ALL` **逐位相同**，`HEAD=50828c9` ⇒ 跑动期间零源码漂移，本日志绑定于 `DIGEST_ALL(content)=34bf1e5a…`。
- ⚠️ **既存显示瑕疵（非红）**：stdout 有 4 行 `环境变量 TRUNC/50/TRUNCM/8 没有定义` = 矩阵给 `trunc50` 门传 env 串时 cmd 的未定义变量展开（源 = `run_matrix_p4dfix.bat:186-187/268-269`），**各门判据与退出码不受影响**。

## 步骤 4：构建（`board/run_build_p7b_ku5p.bat`，**一次收口、无停滞**）

**窗口**【事实】：00:20:44 起 → 综合完成 → `[00:31:39] Launched impl_1` → bit 落盘 00:48 → `BUILD_EXIT=0`。**F 的 run1 那种 `xdma_0` OOC 停滞本轮未再现**，故无"两次都报"。原始关键行：
```
P7B_CONVERGED_AT_ROUND = 2
P7B_IS_LOCKED_POSTGEN = 0
P7B_WNS = 0.262
P7B_WHS = 0.010
P7B_WPWS = 0.010 0.010 0.011 0.011 0.011 0.014 0.017 0.024 0.027 0.039 0.049 0.052 0.059 0.061 0.066 0.112 0.116 0.262 0.300 0.339 0.701 1.060 1.117 2.075 3.166 4.430 4.476 6.770 6.862 6.926 6.971 7.188 8.194 998.996
P7B_BIT_EXISTS = 1
P7B DONE
BITSTREAM-OK
BUILD_SCRIPT_RC=0
```
**硬门**：`12-4739 / Synth 8-11241 / undeclared symbol / VRFC 10-3091(actual bit length 1) / VRFC 10-2989 / implicitly declared / NSTD-1 / UCIO-1 / AVAL-326 / Opt 31-155 / Opt 31-67 / Route 35-7` 在 `board/p7b_ku5p_stdout.txt` 命中数 = **0**。

**① 位流**：sha256 **`09c280e464a4296ebaa531e777675ed88611534e6ddfdae02584d051b308ecbf`**，**15,431,261 B** ⇒ 与 F 的 `89e89f31…` **同尺寸、异哈希**（与"七档只有 sha256/BID 能分版"一致）。

**② 三类失败端点（原始行）**：
```
| Design Timing Summary
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
      0.262        0.000                      0               250509        0.010        0.000                      0               250509        0.000        0.000                       0                 81762
All user specified timing constraints are met.
```
`Slack (VIOLATED)` 块计数 = **0**（timing_summary 全文）。⇒ **三类失败端点 = 0 / 0 / 0**（F = 0.111/0.010/0.000、248,339/81,107 端点）。

**③ 全局 `0.262` 的身份**（勿误读成数据面）：`get_timing_paths` 定向查询 = group **`txoutclk_out[0]_3`**、lvl=16、`u_mac_tx/cw_len_reg[1]/C → u_pcs/…/i_TX_ENCODER/is_valid_ctrl_reg[0]/D` = **一条 setup 路径**。⚠️ **与 F 的全局 `+0.111`（`async_default` Recovery）不同对象、不同检查类型 ⇒ 两档全局 WNS 不可比**（#66）。

**④ DP 域（`g_hw.clk_out0`）—— 本轮看点**：
```
Setup :            0  Failing Endpoints,  Worst Slack        0.300ns,  Total Violation        0.000ns
Hold  :            0  Failing Endpoints,  Worst Slack        0.010ns,  Total Violation        0.000ns
PW    :            0  Failing Endpoints,  Worst Slack        2.627ns,  Total Violation        0.000ns
```
intra-clock 表行：`g_hw.clk_out0   0.300  0.000  0  140472  0.010  0.000  0  140472  2.627  0.000  0  50139`
⇒ **DP 域 setup WNS = `+0.300`**（F `+0.281`，+0.019）；WHS 同 0.010；DP 端点数 138,839 → **140,472**。

**DP 组前 10 最差端点（定向报告 `report_timing -group g_hw.clk_out0 -max_paths 10`，全部 `Slack (MET)`）**：

| # | Slack | Source | Destination | 级数 |
|---|---|---|---|---|
| 1 | 0.300 | `u_tcp_tx/ack_pend_r_reg/C` | `u_tcb/snd_nxt_r_reg[5][28]/D` | 14 (CARRY8=2) |
| 2 | 0.303 | 同上 | `u_tcb/snd_una_r_reg[2][29]/CE` | 14 |
| 3 | 0.308 | 同上 | `u_tcb/snd_nxt_r_reg[15][11]/CE` | 14 |
| 4 | 0.308 | 同上 | `u_tcb/snd_nxt_r_reg[15][1]/CE` | 14 |
| 5 | 0.321 | 同上 | `u_tcb/snd_nxt_r_reg[5][19]/D` | 14 |
| 6 | 0.324 | 同上 | `u_tcb/rcv_wnd_r_reg[2][7]/D` | 14 |
| 7 | 0.325 | `u_app_udp/u_txf/dout_reg[67]/C` | `u_udp_tx/ip_csum_r_reg[0][12]/D` | **21 (CARRY8=7)** |
| 8–10 | 0.333–0.337 | `ack_pend_r_reg/C` | `u_tcb/snd_una_r_reg[2][{0,8,21}]/CE` | 14 |

- **8/10 出自 `ack_pend_r_reg` 一族**（老信号，`git log -S` 追到 P5d/RETXFIX 轮，非本刀新增；第 7 条是历史老族 `u_app_udp/u_txf → u_udp_tx/ip_csum_r`）。
- **新族检查**【事实】：`whi_r_reg*`/`ring_hi_reg*` **不在 DP 前 10**（`dp_top50.rpt` 50 条里 **0 命中**）。定向查询给出新族**自身**最差路径（全部 MET）：`whi_r`（**512 cell**）from = **2.608** / to = **0.754**（宿 = 自己的 `CE`，lvl=2）；`ring_hi`（**39 cell**）from = **2.101**（宿 = `u_tcb/snd_nxt_r_reg[5][28]/D`，与 DP 第 1 条同宿）/ to = **1.535**。
- ⚠️ **一条"看着像新族"的假线索，已判掉**【事实】+【推断】：DP 第 1 条路径的数据路径里有一条网叫 **`u_tcp_tx/ring_restore1`**（net delay 0.372 ns）。**定向网络查询判定：`ring_restore1/2/11_out[31]` 三条网的驱动全部是 `u_tcp_tx/fc_rr_reg[3]_i_{10,9,8}` 的 **CARRY8 进位输出**、负载全部是同一个 LUT5 `u_tcp_tx/fc_rr[3]_i_7` 的三个输入** ⇒ 【事实】它们是**进位链上的网**，不是 RTL 里那条 `ring_restore` 控制线（`:795`/`:1690`）；【推断】该名字是 opt/synth 期的**网名归并产物**（命名机理**未定位**）。⇒ **不许据此写"本刀新族进了 DP 最差路径"。**
- ⚠️ DP WNS **宿主换人**（F = `u_clkgen/rel_sr_reg[3] → u_tcp_tx/u_retx/…RSTRAMB`；本版 = `ack_pend_r_reg → u_tcb/snd_nxt_r_reg[5][28]`）——按 #66「WNS 是不同对象」**不许归因**（无拆刀 A/B）。

**⑤ route_status / DRC / 资源 vs F**：

| 项 | F | **本版 0x1C** | Δ |
|---|---|---|---|
| logical nets | 186,967 | **189,803** | +2,836 |
| routable / fully routed | 131,204 / 131,204 | **132,930 / 132,930** | +1,726 |
| nets with routing errors | 0 | **0** | 0 |
| CLB LUTs | 72,874 (33.59%) | **74,212 (34.21%)** | **+1,338** |
| CLB Registers | 71,769 (16.54%) | **72,424 (16.69%)** | **+655** |
| Block RAM Tile | 348 (72.50%) | **348** | 0 |
| URAM | 0 | **0** | 0 |
| DSPs / Bonded IOB / GTYE4_CHANNEL | 4 / 10 / 6 | **4 / 10 / 6** | 0 |
| setup 端点总数 | 248,339 | **250,509** | +2,170 |
| board DRC（`report_drc` roster 行） | — | **5 行全 `Warning`**：`DPIP-2`×4 · `DPOP-3`×2 · `DPOP-4`×4 · `DPOR-2`×18 · `REQP-1858`×41；**`Error`/`Critical` 行 = 0** | — |

（板级 `board/p7b_ku5p_{timing,drc,util,stdout}` 已确认为**本次重建**：sha256 与 F 归档值全不同。）⚠️ 资源增量 **+655 FF / +1,338 LUT** vs 纸面 `+544 FF / +100–250 LUT` —— **不归因**（本刀 + persist RTL 同树，无拆刀臂）。

## 任何红 / 异常

- **构建：0 红**（硬门 0 命中、`Slack (VIOLATED)`=0、route errors=0、DRC 仅 Warning）。**矩阵：0 红**（17/17 EXIT=0，FROZEN）。
- **异常/瑕疵（均非红）**：① 矩阵 stdout 4 行 `环境变量 … 没有定义`（既存显示瑕疵，见步骤 3）；② 定向查询首版两个 Tcl 层错误（`**default**` 组不可 get_property；`-path_group` 选项不存在）——已在第二/三版修正后取到全部读数；③ arm B 两日志**非整文件逐字节相同**（仅元信息差异，见步骤 2）。
- **未做的（如实写）**：① 读侧 `EXPECT_BID` 同步（**授权外**，见拍板项；**已另派**）；② 未跑作者门 `TX_OVL_GATE`（派单未要求；其已知 S 臂状态见台账 §9-3）；③ 本版查询脚本/输出**只在系统 temp**（`C:\Users\zhxue\AppData\Local\Temp\p7b_0x1C_query\`）——**已按 TL 裁定复制进本目录 `query/`**。

---

## 附：本目录清单（artifact map；第二段回传）

| 文件 | 内容 | 关键 sha256 |
|---|---|---|
| wrapper_p4.bit | 本版（0x1C）位流，15,431,261 B | 09c280e464a4296ebaa531e777675ed88611534e6ddfdae02584d051b308ecbf |
| wrapper_p4_routed.dcp | 本版 routed checkpoint，61,332,410 B | dd7be0323a3004bbc51cc1a233271793eaa463fcde35891ef7b1a8c7b85c1b59 |
| query/q_0x1C.tcl | 定向查询脚本（v3：ring_restore 网判定 + DP top-50） | 98816d8f98684d7e… |
| query/run_q.bat | 查询运行器（CRLF；调用示范指向当时活路径 dcp） | a094db4b1ffa1bc7… |
| query/q_stdout.txt | v3 运行 stdout（三条 ring_restore* 网的驱动/负载判定） | 67b7deca10cb83fa… |
| query/dp_top10.rpt | DP 组前 10 setup 路径（v2 运行） | b9c874be57449b44… |
| query/dp_top50.rpt | DP 组前 50 setup 路径（v3 运行） | 25168106eb0c6cab… |
| query/global_top25.rpt | 全局前 25 setup 路径（v2 运行） | da78274d76664492… |
| query/whi_r_reg_{from,to}.rpt | whi_r_reg* 定向 from/to 路径（v2） | 2cde9059… / 817269a1… |
| query/ring_hi_reg_{from,to}.rpt | ring_hi_reg* 定向 from/to 路径（v2） | 3646b66c… / 738c8c87… |
| F_PRE_BUILD_INVENTORY.txt | 开工前 p7b_buildF_build/F/ 全目录 17 条 sha256+字节 | 8108ac627f6ca5c0… |
| SHA256SUMS.txt | 本目录其余全部文件的 sha256（不含自身） | （本文件） |

⚠️ query/ 里有版本史：q_stdout.txt = v3；v2 的 Tcl 层读数（全局 0.262 宿主、两族 from/to）**只保存在本 REPORT 正文**。

## 并发命名撞车（第二段回传，TL 需处置）

`git status` 现同时出现：
```
?? _proj_10g/notes/p7b_build0x1C/     ← 不是本 agent 的（读侧同步那支自建）
?? _proj_10g/notes/p7b_build_0x1C/    ← 本 agent 的（按 TL 逐字给的路径）
```
两个目录**只差一个下划线** ⇒ 下游按名引用时极易串。**处置（TL）**：读侧那支改名 `p7b_readside_bid1c_20261011/`（本目录名保持 `p7b_build_0x1C/`）。
