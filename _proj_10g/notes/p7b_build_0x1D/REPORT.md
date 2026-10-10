# 构建 agent 报告（P7b persist 刀 / BID `0x1D`）

> 落盘说明：本件正文由构建 agent 全文回传，**TL 代落盘**（该 agent 的 `REPORT.md` Write 被平台策略拒绝；bash heredoc 亦被环境拒 —— 引号解析失败且 heredoc 传输会吞反斜杠）。内容逐字保留。

**边界声明**：未烧录、未连 JTAG/hw_server、未碰板卡、未 ssh 对端、未写 QSPI、未改 `rtl/`·`tb/`·`sim/`、未走 GUI/`vivado_prj` 里那份 BID 0xA 旧 wrapper。只改了 `board/wrapper_p4.v` 两处值 + 两段注释；git 只读（未提交）。本轮**不**下 PASS/FAIL 裁定。

| 项 | 值 |
|---|---|
| 位流 | sha256 **`b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f`** / **15,431,261 B** |
| 位流身份 | `BUILD_ID_V = 32'h0000001D`（源码面）；窗口字长/未实现地址不变（仍 70 字 / `0x138`） |
| 构建 | `P7B_WNS = 0.067 / P7B_WHS = 0.010`；三类失败端点 `0 / 0 / 0`；`BUILD_EXIT=0` |
| 矩阵 | **17/17 门 EXIT=0，0 红，`gates failed: 0`，`VERDICT: FROZEN`** |
| 全局 WNS 身份 | **`g_hw.clk_out0`（DP 域）**：`u_tcp_tx/tick_cnt_reg[2]/C → u_tcb/snd_wnd_r_reg[4][12]/CE`，lvl=16 |
| DP 域 setup WNS | **`+0.067`**（0x1C = `+0.300`） |

---

## 步骤 1：预核

- **开工时 `git status`**：` M _proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt`（他支痕迹）+ `?? .claude/` · `?? _proj_10g/notes/p7b_defect_board_20261011/`（板级轮）+ 一排 `_tmp_*.py` + `?? sim/aliasgate/_selftest/` ⇒ **`rtl/`·`tb/`·`board/` 干净**；HEAD = `6b7d00e`（与派单一致）。
- **`p7b_buildF_build/F/` 开工前实况（原话）**：`ls -la` = **17 件**，含 **`wrapper_p4_routed.dcp`（60,011,449 B）** ⇒ 0x1C 轮抢救的 dcp 欠账仍封在档内。17 条 sha256+字节已算出 → 本目录 `F_PRE_BUILD_INVENTORY.txt`（锚点复核：`wrapper_p4.bit` = `89e89f31…0f45`、dcp = `737a1418…ef6e`，与 `p7b_build_0x1C/REPORT.md` 所记逐字相同）。
- 读了 `p7b_build_0x1C/REPORT.md`（形状模板）与 `P7B_PERSIST_DESIGN.md` v3 相关节。

## 步骤 2：`board/wrapper_p4.v` 改动（两处值 + 两处注释）

**行号（改后现读）**：注释块 `:2144-2158` / 例化 `:2159`；`BUILD_ID_V` `:4067`。

| 项 | 改前 | 改后 |
|---|---|---|
| `.PERSIST_EN`（`:2159`） | `1'b0` | **`1'b1`** |
| 注释块（`:2144` 起） | "persist **关** (下一版才开)" + 惰性论证 | **persist 开 = 发送侧零窗探询（RFC 1122 §4.2.2.17 MUST-36；同节 SHOULD 未字面采纳、用 MUST-36 + 有界旧数据探询段）**；内容 = persist 刀（含 **P-1 修复**：捕获块前移 + `cfg_up` 同 id 支清 `ps_rd_d1/ps_rd_d2`，实测臂 D7A `rdy` 存活 7→0）；**证据 = `_proj_10g/notes/p7b_persist_impl_review_20261011/`**；**回退点 = 改回 `1'b0`** |
| `BUILD_ID_V`（`:4067`） | `32'h0000001C` | **`32'h0000001D`** |
| BID 注释 | 0x1C（缺陷刀）块 | 新增 0x1D 块：内容 = persist 刀 + P-1 修复；⚠️ 窗口字长/未实现地址**不变**（70 字 / `0x138`）⇒ 读侧只需 `EXPECT_BID` 0x1C→**0x1D**（**本轮不做**，TL 另派）；**历史链：0x1C = 缺陷刀（RETXHI-GHOST）/ 0x1B = 已分配、从未构建（原定 persist）/ 0x1A = 构建 F（70 字窗口）**；原 0x1C 块降级进"（以下为历史，逐字保留）"段 |

**核验**（【事实】）：
- `git diff --stat -- board/wrapper_p4.v` = **`1 file changed, 30 insertions(+), 14 deletions(-)`**，且 `git diff` **只有两个 hunk**（`@@ -2141,18 +2141,22 @@` 与 `@@ -4060,8 +4064,20 @@`）⇒ **无别的行被碰**（`:3995-4013` m_axi tie-off 区、五行别名区、快照段均无 hunk）。
- **CRLF**：改后 4421 行 / **CRLF 4421 / 裸 LF=0 / 裸 CR=0 / 以 CRLF 结尾**（改前 4405 行 ⇒ +16 行 = 两块注释净增）。
- 改后 sha256 = **`04b1c783df4507ff98d5abdc76277289d86a34f7f6e4439a1b23f1fd1b7f6fd6`**（274,458 → 276,157 B）。
- ⚠️ **一条到手订正（上一版注释的笔误，本版已顺带修正）**：0x1C 版该块末行原写"回退点 = 这一处改回 `1'b1`"——而该版值**就是** `1'b0`，"回退到 1'b1"= 开机不是回退 ⇒ 本版改写为"回退点 = 这一处改回 `1'b0`"（与参数默认值 `rtl/tcp_tx_frame.v:299 = 1'b0` 一致）。如实登记：**这不是本刀的改动内容，是修掉上版遗留的措辞错误**。

## 步骤 3：全量常驻矩阵（17 门）

`MSYS_NO_PATHCONV=1 cmd /c 'sim\p4gates\run_matrix_p4dfix.bat'` —— **退出码 0**。原始行：

```
[P4GUARD OK] root=d:\repo\xcku5pmini\udp_hls_10g self=d:\repo\xcku5pmini\udp_hls_10g manifests=6
gate filter : (none -- all 17)
gates run   : 17 / 17
gates failed: 0
VERDICT: FROZEN -- all 257 hashed files byte-identical across the run; this log is bound to
         revision DIGEST_ALL(content)=b6f52171118a508be6a6125e2c79bbffbe7f89f3becf8d81e3eff6c4108d7d78
MATRIX DONE 2026/10/11 周日 1:57:45.32
```

- **17 门逐门 `EXIT=0`**：chain · burst200 · trunc50 · trunc100 · halfdrop · txdrop50 · gate4096 · dupstorm · pcackoob · vlanchain · vlanburst · stallgate · unit_retx · unit_fifo · unit_vlan · unit_uart · p5_wrapper。
- **指纹守卫**：`DIGEST_COMPILE = 584d8400…`（212 文件，BEFORE/AFTER 逐位同）；`DIGEST_ALL`（旧 scheme）`= 4eaee6b5…`（257 文件，逐位同）⇒ 跑动期间**零源码漂移**。⚠️ `GIT_HEAD` BEFORE=`6b7d00e` → AFTER=`bd44490`（**他支提交**，01:49:30 = 板级 S-0 轮台账 + 读侧脚本参数化，**不在 257 文件指纹面内**、BEFORE/AFTER 内容逐位同）⇒ FROZEN 结论不受影响。
- **静默门复核**（两门"无条件 exit 0"的门，日志尾现读，均为本跑新件）：`unit_retx` = **`ALL 7 GROUPS PASS`**（GRP A–G 行全 PASS，`$finish` @111,486 ns，01:54:32）；`unit_fifo` = **`PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=606302 pops A=567224 B=591216 C=611802 cycles=750700`**（01:56:50）。
- **既有显示瑕疵**：stdout 有 `环境变量 <名> 没有定义` 行（cmd 给带 env 的门展开 `TRUNC=50;TRUNCM=8` 这类串所致，源 = 该 bat 的 `call :gate` env 列，现读 `:184-189` 区）。⚠️ **本轮全量计数 = 14 行 / 4 组**（trunc50×4：TRUNC/50/TRUNCM/8；trunc100×4；halfdrop×4：HALFDROP/100/HALFDROPK/990；pcackoob×2：PCACKOOB/1）—— 上一轮报告只记了 trunc50 那 4 行，**同族、形态相同**；均发生在门启动前、不影响任何门的判据行与退出码。原始 GBK 件 = `matrix_stdout.txt`；转码件 = `matrix_stdout_utf8.txt`。

## 步骤 4：构建（`board/run_build_p7b_ku5p.bat`，**一次收口、无停滞**）

**窗口**【事实】：01:58:29 启动 → **`xdma_0` OOC 综合 02:03:05 正常完成（构建 F run1 的停滞未见）** → synth 02:09:14 → impl 起 02:10 → placed 02:21 → bitstream **02:30:34** → `BUILD_EXIT=0`。**预归档步**（每跑必做的 #54 收口）：`ARCHIVE_SHA256_OK` + `ARCHIVE_DONE 20261011_015829 files=19` —— 独立核对：归档里的 `wrapper_p4.bit` sha256 = **`09c280e4…ecbf`（= 0x1C 位流，逐字相同）** ⇒ **第二重保险成立**。原始关键行：

```
BUILD_EXIT=0
P7B_CONVERGED_AT_ROUND = 2
P7B_IS_LOCKED_POSTGEN = 0
P7B_WNS = 0.067
P7B_WHS = 0.010
P7B_WPWS = 0.010 0.011 0.011 0.011 0.013 0.013 0.015 0.018 0.039 0.050 0.050 0.052 0.052 0.059 0.067 0.080 0.108 0.195 0.292 0.372 0.455 0.470 1.305 2.252 3.050 4.426 4.674 6.713 6.774 6.827 6.893 7.232 8.262 998.998
P7B_BIT_EXISTS = 1
P7B DONE
BITSTREAM-OK
BUILD_RC=0
```

**硬门**：`12-4739 / Synth 8-11241 / undeclared symbol / VRFC 10-3091(actual bit length 1) / VRFC 10-2989 / implicitly declared / NSTD-1 / UCIO-1 / AVAL-326 / Opt 31-155 / Opt 31-67 / Route 35-7` 在 `board/p7b_ku5p_stdout.txt` 命中数 = **全 0**；`DROPPED-CONSTRAINT-FAIL / IMPLICIT-NET-FAIL / DRC-KEY-FAIL` = **0**。

**① 位流**：sha256 **`b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f`**，**15,431,261 B**（与 0x1C `09c280e4…` 及此前七档**同尺寸、异哈希** ⇒ 只有 sha256/BID 能分版）。

**② 三类失败端点（原始行）**：

```
| Design Timing Summary
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
      0.067        0.000                      0               251821        0.010        0.000                      0               251821        0.000        0.000                       0                 82055
All user specified timing constraints are met.
```

`Slack (VIOLATED)` 全文件计数 = **0**（timing_summary_routed.rpt）。

**③ 两条 Critical Warning（既存、非本刀）**：`Constraints 18-1056 Clock 'gtrefclk0' completely overrides clock 'gt_refclk_p'`（×2）与 `Vivado 12-1790 Evaluation License Warning`（xxv_ethernet 标配）。

## 步骤 5：定向查询（在归档 dcp 副本上跑；脚本/输出在 `query/`）

⚠️ **v1 撞坑如实登记**：首版 `get_property PATH_GROUP/PATH_TYPE` 在 timing_path 上不存在（`Common 17-54`，与 0x1C 轮"`-path_group` 选项不存在"同族工具坑）⇒ **v2** 改为"文本报告取组名 + 只取安全属性"，读数如下。

### 5.1 全局 WNS 身份（`get_timing_paths` top-5；文本报告 `global_top5.rpt`）

```
G #1 slack=0.067 lvl=16 sp=u_tcp_tx/tick_cnt_reg[2]/C ep=u_tcb/snd_wnd_r_reg[4][12]/CE
G #2 slack=0.086 lvl=16 sp=u_tcp_tx/tick_cnt_reg[2]/C ep=u_tcb/snd_wnd_r_reg[4][10]/CE
G #3 slack=0.086 lvl=16 sp=u_tcp_tx/tick_cnt_reg[2]/C ep=u_tcb/snd_wnd_r_reg[4][1]/CE
G #4 slack=0.086 lvl=16 sp=u_tcp_tx/tick_cnt_reg[2]/C ep=u_tcb/snd_wnd_r_reg[4][6]/CE
G #5 slack=0.121 lvl=10 sp=u_tcp_tx/u_retx/g_byte[1].mem_o_reg_7_bram_8/CLKBWRCLK ep=u_tcp_tx/ring_d_r_reg[60]/D
```

- **Path Group = `g_hw.clk_out0`（DP 域）**（global_top5.rpt `:21/:149/:277/:405/:533` 五行逐条现读）⇒ **本轮全局 WNS 的宿主 = DP 域**（0x1C 时 DP `+0.300` 还在全局 `+0.262` 之上，全局出身是 GT 域）。
- 路径分解（dp_top10.rpt 第 1 条）：`Data Path Delay 6.066 ns (logic 1.923 = 31.7% / route 4.143 = 68.3%)`；`Logic Levels 16 (CARRY8=3 LUT2=1 LUT3=2 LUT4=1 LUT5=2 LUT6=7)`；clock skew −0.162。中段经过 `u_retx/scan_id` → `u_csum/scan_id` → `u_fifo_b/ctrl_doff` → `u_ackq/ctrl_ack` → `u_tcb/cam_rd_id` → `u_tcb/f_seq` → 3×CARRY8 链（net `u_tcb/u_tcp_tx/ring_ovf12_out[31]`，**进位链网名**）→ `u_tcp_tx/fc_rr` → `u_ackq/rcv_nxt_r` → `u_ackq/tcb_id` → `u_ackq/snd_wnd_r[4][15]_i_1` → 宿 `CE`。⚠️ **不许把其中的网名当"某族进了关键路径"的证据**（`ring_ovf12_out[31]` 是 CARRY8 输出网；与 0x1C 的 `ring_restore1` 同族前车之鉴）。
- **与 0x1C 的全局 `+0.262` 是否同一对象 —— 按 #66 逐条：不是**（① **组不同**：`txoutclk_out[0]_3` ↔ `g_hw.clk_out0`；② **源不同**：`u_mac_tx/cw_len_reg[1]/C` ↔ `u_tcp_tx/tick_cnt_reg[2]/C`；③ **宿不同**：`u_pcs/…/is_valid_ctrl_reg[0]/D` ↔ `u_tcb/snd_wnd_r_reg[4][12]/CE`；④ 级数**同为 16 只是巧合、不构成同族证据**）。补充佐证：**本构建的 timing summary 里 `txoutclk_out[0]_3` 一次都不出现**（0 命中；只有 `txoutclk_out[0]`/`txoutclk_out[0]_1`，WNS 3.050 / 0.372），而 0x1C 归档的 `global_top25.rpt` 里该组名出现 56 次 ⇒ 两组不同网表连组名集合都不同。

### 5.2 DP 域（`g_hw.clk_out0`）——本轮看点

```
Setup : 0 Failing Endpoints, Worst Slack 0.067ns   Hold : 0 Failing / 0.011ns   PW : 0 Failing / 2.627ns
intra-clock 行: g_hw.clk_out0  0.067 0.000 0 141287  0.011 0.000 0 141287  2.627 0.000 0 50435
```

⇒ **DP 域 setup WNS = `+0.067`**（**0x1C = `+0.300`**，−0.233；也正是本轮全局最差）；DP 端点 140,472 → **141,287**（+815）；三类失败端点 DP 内 0/0/0。

**DP 组前 10 最差端点**（`dp_top10.rpt`，全部 `Slack (MET)`）：

| # | Slack | Source | Destination | 级数 |
|---|---|---|---|---|
| 1 | **0.067** | `u_tcp_tx/tick_cnt_reg[2]/C` | `u_tcb/snd_wnd_r_reg[4][12]/CE` | 16 |
| 2–4 | 0.086 | 同上 | `u_tcb/snd_wnd_r_reg[4][{10,1,6}]/CE` | 16 |
| 5 | 0.121 | `u_tcp_tx/u_retx/g_byte[1].mem_o_reg_7_bram_8/CLKBWRCLK` | `u_tcp_tx/ring_d_r_reg[60]/D` | 10 |
| 6 | 0.127 | `tick_cnt_reg[2]/C` | `u_tcb/snd_wnd_r_reg[11][8]/CE` | 16 |
| 7–10 | 0.129 | 同上 | `u_tcb/rcv_nxt_r_reg[5][{20,24,4,9}]/CE` | 16 |

- **9/10 条同源 `tick_cnt_reg[2]`**；0x1C 的 DP 前 10 是 `ack_pend_r_reg`（8/10）+ 老族 `u_app_udp/u_txf→u_udp_tx/ip_csum_r`。
- ⚠️ **大移位、无拆刀 ⇒ 不许归因**：`tick_cnt` 源族在 **0x1C 归档 `dp_top50.rpt` 里 0 命中**（现核），本轮在 `dp_top50.rpt` 里 **141 命中** —— 这是两**不同网表**之间的一次整体换位（本流程跨网表位移带 ±0.4–1.3 ns，首例即超带、**机理未定位**）；本刀同树只差两常量（`PERSIST_EN` 0→1、BID 0x1C→0x1D），**但"改常量也会确定性改变网表/时序"（全局 #64）⇒ 记"移位属实 / 归因判不了"**。

### 5.3 persist 新族定向查（`-from` / `-to`，v2 读数）

**进没进前 10/前 50：【事实】全部 0 命中** —— `dp_top10.rpt` 与 `dp_top50.rpt` **全文件 grep**（`ps_timer`/`ps_phase`/`ps_stage`/`ps_rd_d`/`ctrl_probe`/`tx_is_probe`/`whi_r`/`ring_hi` 任一模式）= 0（连**中间经过**的 cell 都没有）。它们各自的最差 from/to（全部 MET、无一接近临界）：

| 族 | ncell | from_worst | to_worst | 备注 |
|---|---|---|---|---|
| `ps_timer` | 420 | **1.635** lvl=11（→`u_retx/ra_e_r…/D`） | **0.858** lvl=14（`u_fifo_b/wptr→ps_timer_reg[5][17]/D`） | to 是族内最紧的一条 |
| `ps_phase` | 48 | 2.385 lvl=6 | **0.703** lvl=13（→`ps_phase_reg[3][1]/CE`） | |
| `ps_stage` | 42 | **0.557** lvl=15（`ps_stage_estab_reg/C → u_tcb/snd_wnd_r_reg[4][12]/CE`） | **0.294** lvl=10（`u_retx/g_byte…bram → ps_stage_byte_reg[2]/D`） | ⚠️ **from 的宿 = 与本轮全局 WNS 同宿**（0.557 ≫ 0.067：persist 参与该锥、但不是该锥最差项） |
| `ps_rd_d1_reg` | 1 | 5.860 lvl=1 | 1.131 lvl=13 | P-1 修复点，在网表里存在 |
| `ps_rd_d2_reg` | 1 | 4.543 lvl=0 | 2.569 lvl=3 | 同上 |
| `ctrl_probe` | **0（NOCELL）** | — | — | ⚠️ RTL 里是寄存器（`tcp_tx_frame.v:449`）但网表**无此名** ⇒ 未定位（见下） |
| `tx_is_probe` | 2 | 2.717 lvl=4 | 2.697 lvl=2 | |
| `ctrl_pld` | 8 | 1.516 lvl=12（→`ctrl_tcpcsum`） | 2.773 lvl=4 | |
| `probe_sel` | **0（NOCELL）** | — | — | `probe_sel` 是**线**不是寄存器 ⇒ NOCELL 预期 |

- ⚠️ **两条未定位（如实登记，均非红）**：① **`ctrl_probe` 无同名 cell** —— 补充查询（`q_0x1D_extra.tcl`）：`*probe*` 全设计只有 `u_tcp_tx/tx_is_probe_i_1`（LUT2）+ `u_tcp_tx/tx_is_probe_reg`（FDCE）**两个** cell；名字来源**未定位**（可能被合并/改名 —— 机理判不了）。② `ps_rd_d*` 全模式命中 6 个 cell，其中 **`u_slow_cfg/ps_rd_d2_i_2` / `_i_3`（LUT5）挂在另一层次下** —— 回源码核过：`ps_rd_d2` 这个名字**全仓唯一来源 = `rtl/tcp_tx_frame.v`**（`grep -rn` 除它外 0 命中）⇒ 【推断】这是综合/opt 的**命名与层次归属产物**（与 `ring_restore1`/`ring_ovf12_out` 同族现象）；**不许据网名当"新族"证据**。
- **缺陷刀族复核（`whi_r_reg*` / `ring_hi_reg*`，任务要求）**：ncell = 512 / 39（与 0x1C 相同 ⇒ 可比）：`whi_r`：from `2.608 →` **`2.484`** / to `0.754 →` **`1.361`**；`ring_hi`：from `2.101 →` **`1.837`** / to `1.535 →` **`1.128`**（括号内 = 0x1C 值）。⇒ **数值有移位（不同网表），但四条全部远高于临界**（最紧 1.128 仍是本轮全局 WNS 的 16.8 倍）⇒ 读数登记、**方向性归因判不了**（无拆刀臂）。

### 5.4 route / DRC / 资源（与 0x1C 并列）

| 项 | 0x1C | **本版 0x1D** | Δ |
|---|---|---|---|
| logical nets | 189,803 | **190,535** | +732 |
| routable / fully routed | 132,930 / 132,930 | **133,500 / 133,500** | +570 |
| nets with routing errors | 0 | **0** | 0 |
| CLB LUTs | 74,212 (34.21%) | **74,928 (34.54%)** | **+716** |
| CLB Registers | 72,424 (16.69%) | **72,717 (16.76%)** | **+293** |
| Block RAM Tile | 348 (72.50%) | **348 (72.50%)** | 0 |
| URAM | 0 | **0** | 0 |
| DSPs / Bonded IOB / GTYE4_CHANNEL | 4 / 10 / 6 | **4 / 10 / 6** | 0 |
| setup 端点总数 | 250,509 | **251,821** | +1,312 |
| WPWS 端点总数 | 81,762 | **82,055** | +293 |
| board DRC roster | 5 行全 Warning | **逐字相同**：`REQP-1858`×41 · `DPOR-2`×18 · `DPOP-4`×4 · `DPIP-2`×4 · `DPOP-3`×2；**`Error`/`Critical` = 0** | 0 |

⚠️ 资源/端点增量（**+716 LUT / +293 FF / +815 DP 端点**）出在"两常量不同"的两个网表之间（`PERSIST_EN` 开 + BID 换），**无拆刀臂 ⇒ 不归因到 persist 单独一项**（#64 已证常量本身参与综合/实现）。

## 任何红 / 异常

- **构建：0 红**（硬门 12 键 + 3 标记 = 0；`Slack (VIOLATED)`=0；route errors=0；DRC 全 Warning、0 Error/Critical）；**矩阵：0 红**（17/17 EXIT=0、FROZEN、两静默门有牙）。
- **异常/瑕疵（均非红，如实登记）**：① env 警告 14 行 / 4 组（见步骤 3 的计数订正）；② 查询 v1 的 `PATH_GROUP` 属性坑（v2 已修正取到全部读数）；③ `ctrl_probe` 网表无名（未定位）；④ 全局最差源族 `tick_cnt` 跨网表大移位（机理未定位、不归因）。
- **并发面（#47 记录）**：矩阵跑动期间 HEAD 被他人推进 `6b7d00e → bd44490`（台账/读侧脚本，不在指纹面）；02:42:05（**我全部窗口之外**）`sim/p6e_pcie/tb_p6e_pcie_{counters,wrapper}.v` 被他支修改 —— 该两件**不在矩阵 257 文件面内、也不在 17 门编译面内**（现核指纹文件 0 命中 "p6e_pcie"）⇒ 对我轮的读数无影响；我**未**触碰它们。
- **未做的（如实写）**：① 读侧 `EXPECT_BID` 同步（**授权外**；TL 已备"链式 0x1A→0x1C→0x1D"、0x1D 收口后 apply）；② 未跑作者门 `TX_OVL_GATE`（派单未要求）；③ 未烧录（红线）。

## 附：本目录清单（artifact map）

| 文件 | 内容 | 关键 sha256 |
|---|---|---|
| wrapper_p4.bit | 本版（0x1D）位流，15,431,261 B | **b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f** |
| wrapper_p4_routed.dcp | 本版 routed checkpoint，61,017,432 B | 0eda5f56bf716939ad2a1a1e175ab8c5b57dc9e800f00aaa0cc79473eb4c5854 |
| query/q_0x1D.tcl | 定向查询 v2（全局 top-5 / DP top-10,50 / 11 族 from-to） | 见 SHA256SUMS.txt |
| query/q_0x1D_extra.tcl + q_extra_stdout.txt | 补充查询（`*probe*`/`*ps_stage*`/`*ps_rd_d*` 全 cell 列表） | 同上 |
| query/run_q.bat | 查询运行器（ASCII+CRLF；指向本目录 dcp 副本） | 同上 |
| query/q_stdout.txt | v2 运行 stdout（G/DP/F 全部读数行；v1 的报错行也在文件头） | 同上 |
| query/global_top5.rpt · dp_top10.rpt · dp_top50.rpt | 文本报告（组名/级数/路径全清单） | 同上 |
| matrix_stdout.txt · matrix_stdout_utf8.txt | 矩阵控制台捕获（GBK 原样 / UTF-8 转码） | 同上 |
| build_console.txt | 构建控制台（ARCHIVE_* + P7B_* + BUILD_RC=0） | 同上 |
| board_rpt/ | 本次构建的 `p7b_ku5p_{timing,drc,util,clkinteract}.rpt` + `p7b_ku5p_stdout.txt` 副本（自含取证） | 同上 |
| F_PRE_BUILD_INVENTORY.txt | 开工前 `p7b_buildF_build/F/` 全目录 17 条 sha256+字节 | 同上 |
| SHA256SUMS.txt | 本目录**实存**文件的 sha256（19 条，不含自身；**REPORT.md 落盘后请补条**） | （本文件） |
| REPORT.md | 本文件（TL 代落盘） | 落盘后补进 SHA256SUMS.txt |
