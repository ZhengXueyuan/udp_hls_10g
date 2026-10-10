# 构建 agent 报告（P7b snd_wnd 守卫 / BID `0x1E`）

> 落盘说明：本件正文由构建 agent 全文回传，**TL 代落盘**（该 agent 的 `REPORT.md` Write 被平台策略拒绝；按派单阶梯末级不绕守卫 —— 与 0x1C/0x1D 同款）。内容逐字保留。

**边界声明**：未烧录、未连 JTAG/hw_server、未碰板卡、未 ssh 对端、未写 QSPI、未改 `rtl/`·`tb/`·`sim/`、未走 GUI / `vivado_prj` 里那份 BID 0xA 旧 wrapper。只改了 `board/wrapper_p4.v` 的**一处值 + 两处注释**；git 只读（未提交）。本轮**不**下 PASS/FAIL 裁定。

| 项 | 值 |
|---|---|
| 位流 | sha256 **`e489ae4a4b868695cff1c6dfc2fbdef70de29d391cdb9a43e0a08accd342be1a`** / **15,431,261 B** |
| 位流身份 | `BUILD_ID_V = 32'h0000001E`（源码面）；窗口字长 / 未实现地址**不变**（仍 70 字 / `0x138`） |
| 构建 | `P7B_WNS = 0.034 / P7B_WHS = 0.010`；三类失败端点 **`0 / 0 / 0`**；`BUILD_EXIT=0` |
| 矩阵 | **17/17 门 EXIT=0，0 红，`gates failed: 0`，`VERDICT: FROZEN`**，`MATRIX_RC=0` |
| 全局 WNS 身份 | **`g_hw.clk_out0`（DP 域）**：`u_tcp_tx/u_fifo_a/rptr_reg[6]_replica/C → u_tcb/rcv_wnd_r_reg[2][9]/CE`，lvl=16 |
| DP 域 setup WNS | **`+0.034`**（0x1D = `+0.067`；0x1C = `+0.300`） |

## 步骤 1：预核

- 开工时 `git status --porcelain`：已跟踪文件**全干净**（只有 `.claude/`、一排 `_tmp_*.py`、`sim/aliasgate/_selftest/`、两份 `P4_MATRIX_FINGERPRINT_20261011_013144_*` 等 untracked）⇒ `rtl/`·`tb/`·`sim/`·`board/` 无改动。**HEAD = `0b0d20e`**（与派单一致）。
- `p7b_buildF_build/F/` = **17 件**（逐件 sha256 → `F_PRE_BUILD_INVENTORY.txt`）。锚点：`wrapper_p4.bit` = **`89e89f31…0f45`**（构建 F / 0x1A）、dcp = **`737a1418…ef6e`** —— 与 0x1D 报告所记**逐字相同** ⇒ 17 件未被动。
- **时间线核实（"守卫未进任何位流"成立；派单措辞需按 reflog 读）**：`a38d4a4` 的 **作者时间 = 01:55:09 / 提交者时间 = 02:41:30**，parent = `bd44490`（01:49:30），reflog 逐字 `cherry-pick: P7B-SNDWND-GUARD 实施…` ⇒ 它**落进主树 HEAD 的实际时刻 = 02:41:30**；而 0x1D 位流 02:30:34 已出、0x1D 矩阵 01:53→01:57:45（其 `GIT_HEAD` AFTER 读作 `bd44490`）⇒ **守卫在 0x1D 整个构建窗口内都不在盘上**。独立佐证：`git diff --stat bd44490..HEAD -- rtl/` = **`1 file changed, 21 insertions(+), 3 deletions(-)`** 且 `git log bd44490..HEAD -- rtl/` = **仅 `a38d4a4` 一条** ⇒ 相对 0x1D 位流，**本轮 RTL 功能差 = 且只 = 守卫**。
- **换行约定（引用哈希别踩）**：`core.autocrlf=true`（`.gitattributes` 只对 `*.sh` 强制 LF）⇒ 仓库存 LF 归一化 blob、工作树为 CRLF；本报告与 0x1D 的 `wrapper_p4.v` sha256 **都是工作树 CRLF 口径**。开工时工作树 sha256 = `04b1c783df4507ff98d5abdc76277289d86a34f7f6e4439a1b23f1fd1b7f6fd6` —— **与 0x1D 报告的"改后 sha256"逐字相同** ⇒ 我改的正是 0x1D 产出的那份。

## 步骤 2：`board/wrapper_p4.v`（一处值 + 两处注释）

**行号（改后现读）**：persist 注释头 `:2144-2145`；`.PERSIST_EN(1'b1)` 例化 **`:2160`（未动）**；`.BUILD_ID_V` `:4068`。

| 项 | 改前 | 改后 |
|---|---|---|
| `.PERSIST_EN`（`:2160`） | `1'b1` | **`1'b1`（保持不动）** |
| persist 注释头（`:2144`） | "本轮构建配置 (2026-10-11 · BID **0x1D**): …" | **"现役构建配置 (persist 自 **0x1D** 起开; 本版 **0x1E** 沿用): …"**（块内其余一字未动） |
| `BUILD_ID_V`（`:4068`） | `32'h0000001D` | **`32'h0000001E`** |
| BID 注释 | 0x1D 块 | **新增 0x1E 块**：内容 = **snd_wnd 写入守卫**（`rtl/tcp_rx.v`：`pend_wnd` 置位门与值锁存**成对**按"可接受 ACK"门控 —— 谓词 `ackok_l`（含等号 ⇒ 零推进的窗口更新 ACK 放行 = 零窗恢复必需）；RFC 793 p.72；参数 `SNDWND_GUARD = 1'b1`；cherry-pick `a38d4a4`）；门证据 = `sim/p3sim_sw/` 四臂全绿（FIXED 全 PASS / LEGACY `XFAIL-REPRODUCED` / MUTANT 腿 B1 红 / DROPA 腿 A 红）+ `logs/gate_stdout.txt` 尾 `SNDWND-GATE: PASS`；**回退点 = `SNDWND_GUARD` 置 0（或回滚 `a38d4a4`）**；⚠️ 窗口字长/未实现地址不变 ⇒ 读侧只需 `EXPECT_BID 0x1D→0x1E`（**本轮不做**，TL 另派）。**历史链保留**：0x1D persist / 0x1C 缺陷刀 / 0x1B 已分配未构建 / 0x1A 构建 F；原 0x1D 块降级进"（以下为历史，逐字保留）"段 |

**核验**：`git diff --stat -- board/wrapper_p4.v` = **`1 file changed, 25 insertions(+), 3 deletions(-)`**，**只有两个 hunk**（`@@ -2141,7 +2141,8 @@` 与 `@@ -4064,8 +4065,29 @@`）⇒ 无别的行被碰。**CRLF**：改后 **4443 行 / CRLF 4443 / 裸 LF=0 / 裸 CR=0 / 以 CRLF 结尾**（改前 4421 行，+22 行 = 25−3）。改后工作树 sha256 = **`a32dace1dd529735d5fc258e2a63844b50921c0afe70f3cca932feb66dbd941d`**（278,420 B）。

## 步骤 3：全量常驻矩阵（17 门）

`MSYS_NO_PATHCONV=1 cmd /c 'sim\p4gates\run_matrix_p4dfix.bat'` —— **`MATRIX_RC=0`**。⚠️ 捕获口径（与 0x1D 同形）：stdout 直播只到 `---- summary ----`；摘要正文/指纹写在 `sim/p4sim/matrix_p4dfix.log`（现核 `run_matrix_p4dfix.bat:221-226`）。原始行（副本 = `matrix_log_summary.txt`）：

```
BEFORE  DIGEST_COMPILE=bc1901ed9e2e0fe8a1194af073026bc80ea68914993c83eae888c045f6c77acf  FILES=212  DIGEST_ALL=17c8faa68f5dd0c8b97bd4ccaf0abea6a089fcbf28f4df759056e0af95a801b2  HEAD=0b0d20e
AFTER   DIGEST_COMPILE=bc1901ed9e2e0fe8a1194af073026bc80ea68914993c83eae888c045f6c77acf  FILES=212  DIGEST_ALL=17c8faa68f5dd0c8b97bd4ccaf0abea6a089fcbf28f4df759056e0af95a801b2  HEAD=0b0d20e
VERDICT: FROZEN -- all 257 hashed files byte-identical across the run; this log is bound to revision DIGEST_ALL(content)=7fbccb045c392da3bdca8cf12bb6fecbb63e619827cf16c500593fb5a8305a05
gates run   : 17 / 17
gates failed: 0
MATRIX DONE 2026/10/11 周日 4:07:30.05
```

- **17 门逐门 `EXIT=0`**：chain · burst200 · trunc50 · trunc100 · halfdrop · txdrop50 · gate4096 · dupstorm · pcackoob · vlanchain · vlanburst · stallgate · unit_retx · unit_fifo · unit_vlan · unit_uart · p5_wrapper。
- **跑动期间零源码漂移**：`DIGEST_COMPILE`(212) / `DIGEST_ALL`(257) BEFORE/AFTER 逐位同；**`GIT_HEAD` BEFORE=AFTER=`0b0d20e`**（本轮无他支推进 HEAD）。
- **静默门复核**：`unit_retx` = **`ALL 7 GROUPS PASS`**（`$finish` @111,486 ns）；`unit_fifo` = **`PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700`**。
  - ⚠️ **订正一条**：0x1D REPORT 记的这行是 `C=606302`；本轮实测 **`C=616302`**，且 `616302` 与全仓已入库基线**逐字相同**（`PORT_NOTES.md:3734`、`P7B_BIZ_REGRESSION.md:66/154`、`P7B_IMPLICIT_GATE_ROLLOUT.md:381`、`p7b_biz_reg/logs/p4_matrix16_rerun_matrix_log.txt:198` 等），而 `606302` 全仓唯一出处 = 那份 0x1D REPORT 自身 ⇒ 上一轮那个数**疑似转写笔误**（只登记，不归因）。
- 环境变量警告行 = **14 行 / 4 组**（trunc50×4 / trunc100×4 / halfdrop×4 / pcackoob×2，与 0x1D 同量、既存显示瑕疵）；矩阵日志 `grep -i "fail|error"` = 0 条实质命中。

**覆盖声明（点名要核的"空证据"面，照实报）**：6 个 manifest = `chain_src.f` · `fifo_src.f` · `p5wrapper_src.f` · `retx_src.f` · `uart_src.f` · `vlan_src.f`。⛔ **`sim/p3sim_sw/` 不在任一 manifest、不在 17 门、也不在 257 文件指纹面内**（现核 `grep -c p3sim <fingerprint before>` = 0）⇒ **矩阵对本刀的 snd_wnd 专项门是空证据**（四臂本轮未跑、其文件连指纹都不进）。✅ 但 `rtl/tcp_rx.v` 出现在 **`chain_src.f` + `p5wrapper_src.f`** ⇒ **12 个 chain 族门 + `p5_wrapper`** 编译/跑的就是带守卫的 tcp_rx（且它在指纹面内 = 与修订绑定）。⭐ **门-构建绑定独立复核**：`sim/p3sim_sw/logs/frozen_revision_sha256.txt` = `7517c94951598c7e`(tcp_rx) / `366d8f4f162f3d27`(tb)；本轮构建输入现读 = **`7517c94951598c7e42d11ba7d8e62164acc762cbbd8718356e4f8bf3bc6d1489`** / **`366d8f4f162f3d2791b7b4f0f158379eeef4d927e3d90d5fda8ba04341a35e78`** ⇒ **逐字相同**（门冻结的件 == 进本位流的件）。

## 步骤 4：构建（一次收口、无停滞）

窗口：预归档 **04:09:25** → `xdma_0` OOC 04:13–04:14 正常完成（**构建 F run1 的停滞未再现**）→ `pcs64` OOC 04:12 → synth 完成 04:19 → impl 04:20 → placed 04:30 → physopt 04:33 → route 完成 04:39 → **位流 04:41** → `BUILD_EXIT=0`（bat 退出码 0）。**一次收口，未重跑**。预归档：`ARCHIVE_SHA256_OK` + `ARCHIVE_DONE 20261011_040925 files=19`，且其中 `wrapper_p4.bit` sha256 = **`b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f`（= 0x1D 位流，逐字相同）** ⇒ 第二重保险成立。

```
BUILD_EXIT=0
P7B_CONVERGED_AT_ROUND = 2
P7B_IS_LOCKED_POSTGEN = 0
P7B_WNS = 0.034
P7B_WHS = 0.010
P7B_WPWS = 0.010 0.010 0.010 0.013 0.014 0.015 0.015 0.026 0.034 0.043 0.045 0.058 0.059 0.059 0.062 0.097 0.102 0.119 0.188 0.200 0.372 0.688 1.080 1.955 3.586 4.783 4.894 6.523 6.524 6.826 6.864 6.932 8.317 999.094
P7B_BIT_EXISTS = 1
P7B DONE
BITSTREAM-OK
```

`P7B_VERILOG_DEFINE = APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1`（与 0x1D 同表）。**硬门**：12 键 + 3 标记（`DROPPED-CONSTRAINT-FAIL / IMPLICIT-NET-FAIL / DRC-KEY-FAIL`）在 `board/p7b_ku5p_stdout.txt` 命中 **全 0**。

**三类失败端点（原始行）**：

```
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.034        0.000                      0               252078        0.010        0.000                      0               252078        0.000        0.000                       0                 82226

All user specified timing constraints are met.
```

`Slack (VIOLATED)` 计数 = **0**（`wrapper_p4_timing_summary_routed.rpt` 与 `board/p7b_ku5p_timing.rpt` 双件现核都为 0）。两条 Critical Warning（既存）：`Constraints 18-1056`×2 + `Vivado 12-1790` 评估许可 —— 与 0x1D 逐条相同。

## 步骤 5：定向查询（归档 dcp 副本上跑；`query/`）

**全局 WNS 身份**（`G #1..5`，**Path Group 全部 = `g_hw.clk_out0`**，`global_top5.rpt` `:21/:149/:277/:405/:533` 逐条现读）：

```
G #1 slack=0.034 lvl=16 sp=u_tcp_tx/u_fifo_a/rptr_reg[6]_replica/C ep=u_tcb/rcv_wnd_r_reg[2][9]/CE
G #2 slack=0.043 lvl=16 sp=…rptr_reg[6]_replica/C ep=u_tcb/rcv_wnd_r_reg[14][15]/D
G #3 slack=0.046 lvl=16 sp=同上 ep=u_tcb/snd_una_r_reg[13][0]/CE
G #4 slack=0.053 lvl=16 sp=同上 ep=u_tcb/rcv_wnd_r_reg[4][5]/D
G #5 slack=0.063 lvl=16 sp=同上 ep=u_tcb/snd_una_r_reg[1][18]/D
```

细节：`Data Path Delay 6.067 ns (logic 1.702 = 28.1% / route 4.365 = 71.9%)`；`Logic Levels 16 (CARRY8=2 LUT3=1 LUT4=2 LUT5=3 LUT6=8)`；skew −0.194。**与 0x1D 的 `tick_cnt_reg[2]/C → snd_wnd_r_reg[4][12]/CE` 是否同一对象 —— 按 #66 逐条：不是**（① 组相同（都是 `g_hw.clk_out0`，**不构成同族证据**）；② 源不同；③ 宿不同；④ 级数同为 16 = 巧合）。

**DP 域**：intra-clock 行 `g_hw.clk_out0  0.034 0.000 0 141473  0.010 0.000 0 141473  2.627 0.000 0 50602` ⇒ **DP setup WNS = `+0.034`**（0x1D `+0.067`，−0.033；**也是全局最差**）；DP 端点 141,287→**141,473**；DP 内三类失败端点 0/0/0。⚠️ DP 余量 = **0.53%**（0x1D = 1.05%）—— 只报读数。

**DP 前 10**：**10/10 同源 `u_tcp_tx/u_fifo_a/rptr_reg[6]_replica/C`**，宿 = `u_tcb/rcv_wnd_r_reg[2][9]/CE`(0.034) · `rcv_wnd_r_reg[14][15]/D`(0.043) · `snd_una_r_reg[13][0]/CE`(0.046) · `rcv_wnd_r_reg[4][5]/D`(0.053) · `snd_una_r_reg[1][18]/D`(0.063) · `state_r_reg[3][{0,2,1,3}]/CE`(0.067–0.068) · `rcv_wnd_r_reg[10][5]/D`(0.076)。0x1D 的 DP 前 10 是 9/10 同源 `tick_cnt_reg[2]`。⚠️ **大移位、无拆刀臂 ⇒ 不归因**：`rptr`/`replica`/`u_fifo_a` 在 0x1D `dp_top50` **0 命中**，本轮 `rptr_reg[6]_replica` **147 命中**；反向 `tick_cnt_reg[2]` 0x1D 141 命中 → 本轮 **0 命中**。⚠️ **`u_tcp_rx` 以"中间 cell"身份进 DP 关键路径**（新登记）：本轮 `dp_top10` 20 次 / `dp_top50` 100 次（0x1D `dp_top50` = 0 次），形态 = 路径中段经过 `u_tcp_rx/tx_upd_wr`(net,fo=56) → `u_tcp_rx/FSM_onehot_drn[3]_i_4/O` · `rcv_nxt_r[0][*]_i_*/O` · `sel_rx` 一组 LUT —— **只登记形态、不归因**（网名多是 opt 命名产物）。

**snd_wnd 守卫定向查**：

| 族（模式） | ncell | from_worst | to_worst |
|---|---|---|---|
| `*pend_wnd*` | **143**（⚠️ 跨 `u_tcp_rx`/`u_tcb`/`u_classify/u_wf` 三层 **同名不同物**） | **2.379** lvl=4（`u_tcp_rx/pend_wnd_reg/C → u_tcb/rcv_wnd_r_reg[2][9]/CE` = **与全局 WNS 同宿**） | **0.972** lvl=7（`u_tcp_rx/conn_id_l_reg[0]_rep__0/C → u_tcp_rx/pend_wnd_val_reg[4]/D`） |
| `*pending_wnd*` | **0 NOCELL** | — | — |
| `*ackok*` | **194** | **4.200** lvl=1（`u_tcp_rx/ackok_l_reg/C → u_tcp_rx/pend_wnd_val_reg[10]/CE`） | 1.774 lvl=8（`conn_id_l_reg[1]_rep__1/C → ackok_l_reg/D`） |
| `*ack_ok*` | **0 NOCELL**（wire `ack_ok` 被归并，判不了去向） | — | — |
| `*ack_adv*` | **278**（⚠️ `u_tcp_rx/ack_adv_l_reg` + `u_tcb/ack_adv_l_i_*` 同名不同物） | 3.924 lvl=3 | 0.766 lvl=9 |
| `*dup_l_reg*` | **75**（⚠️ 同上，`u_tcb/dup_l_reg_i_*` 是 MUXF8/CARRY8） | 4.045 lvl=2 | 0.788 lvl=9 |
| `*ack_hi*` | 0 NOCELL | — | — |

**⭐ 守卫结构证据（定向连通性）**：`-from *ackok* -to *pend_wnd*` ⇒ **`n=5` 条路径**，全部形如 `slack=4.200 lvl=1 sp=u_tcp_rx/ackok_l_reg/C ep=u_tcp_rx/pend_wnd_val_reg[10]/CE`（#2–#5 同形：`pend_wnd_val_reg[{11,2,6,15}]/CE`，4.200–4.250）⇒ **`ackok_l` 确认驱动 `pend_wnd_val` 寄存器的 CE 网（1 级 LUT = `s_axis_tcrs && ackok_l`）⇒ 守卫谓词进了本位流的网表**。⛔ 边界：这是**结构连通**读数；**"该 CE 网为守卫独有"的反事实对照（`SNDWND_GUARD=0` 网表）本轮未做**。**守卫族不进报告面**：`dp_top10`/`dp_top50` 全文件 grep `ackok|pend_wnd|ack_adv` = **0 命中**。

**persist 族 / 缺陷刀族复核**（括号 = 0x1D）：`ps_timer` from **1.761**(1.635)/to **0.591**(0.858)；`ps_phase` 2.434(2.385)/**0.532**(0.703)；`ps_stage` ncell **21**(42)、**0.770**(0.557，宿 = 全局 WNS 同宿)/**0.344**(0.294)；`ps_rd_d1` 6.068/1.277；`ps_rd_d2` 4.958/2.011；`ctrl_probe` **NOCELL**（未变）；`tx_is_probe` 3.261/1.961；`ctrl_pld` 1.721/1.960；`probe_sel` NOCELL；`whi_r_reg*` **2.881**(2.608)/**0.573**(0.754)；`ring_hi_reg*` ncell **132**(39)、**1.774**(2.101)/**1.084**(1.535)。⇒ **全部有移位，但两族四条全部远高于临界**（最紧 0.344 = 全局 WNS 的 10×）⇒ **方向性归因判不了**（无拆刀臂）。⚠️ ncell 变化（42→21、39→132）按**网名归并/优化产物**登记，不作族变化证据（#90）。

**route / DRC / 资源（与 0x1D 并列）**：logical nets **191,386**(190,535) · routable/fully routed **134,038/134,038**(133,500) · routing errors **0** · CLB LUTs **75,558 (34.83%)**(74,928, 34.54%；**+630**) · CLB Reg **72,886 (16.80%)**(72,717；**+169**) · BRAM **348 (72.50%)**(=同) · URAM 0 · DSP/IOB/GTYE4 = 4/10/6 · setup 端点 **252,078**(251,821) · WPWS 端点 **82,226**(82,055) · board DRC roster **逐字相同**（`REQP-1858`×41 · `DPOR-2`×18 · `DPOP-4`×4 · `DPIP-2`×4 · `DPOP-3`×2，**0 Error/Critical**）。⚠️ 资源/端点增量不归因（守卫自称 OVL 构建 FF=0，实测差值远大于该预期；无拆刀臂）。

## 任何红 / 异常

- **构建 0 红 / 矩阵 0 红**（见上）。
- 异常（均非红）：① env 警告 14 行/4 组（既存）；② **0x1D REPORT 的 `unit_fifo C=606302` 与全仓基线 `616302` 不符**（本轮实测 = 基线值；疑似上轮转写笔误）；③ `ctrl_probe`/`probe_sel` 网表无名（既存，未变）；④ 全局最差源族**第 3 次整体换位**（`rptr_reg[6]_replica` ↔ `tick_cnt_reg[2]`；`u_tcp_rx` 首次以中间 cell 进 DP 前 50）—— 机理未定位、不归因；⑤ `*ack_ok*`/`*pending_wnd*` = NOCELL（归并所致、判不了）。
- **并发面（#47）**：矩阵 `GIT_HEAD` BEFORE=AFTER=`0b0d20e` ⇒ 无他支推进 HEAD；构建后 `git status` 除 `board/wrapper_p4.v` 外只有构建自身重写的 `board/p7b_ku5p_{stdout,timing,drc,util,clkinteract}` 与 `sim/p4sim/matrix_p4dfix.log` ⇒ **无孤零零异常红**。另：`.claude/worktrees/agent-adbace7bf67a3753c`（守卫轮工作树）仍在盘上，不在指纹面/读数面内，我未触碰。
- **未做**：① 读侧 `EXPECT_BID` 同步（授权外，TL 另派）；② `sim/p3sim_sw/run_sndwnd_gate.bat` 本轮未跑（派单未要求；既有 logs 已入库、冻结修订与构建输入逐字相同）；③ 守卫反事实 A/B（GUARD=0 网表）未做；④ 未烧录（红线）。

## 附：本目录清单

`wrapper_p4.bit`(`e489ae4a…be1a`, 15,431,261 B) · `wrapper_p4_routed.dcp`(`51bd6427…5eb4`, 61,217,962 B) · `query/{q_0x1E.tcl, run_q.bat, q_stdout.txt, out/{global_top5,dp_top10,dp_top50}.rpt}` · `timing_summary_raw.txt` · `matrix_stdout.txt`(GBK) · `matrix_stdout_utf8.txt` · `matrix_log_summary.txt` · `build_console.txt` · `board_rpt/`(5 件) · `F_PRE_BUILD_INVENTORY.txt`(17 条) · `SHA256SUMS.txt`(19 条，**不含自身**；**REPORT.md 落盘后请补条**) · **REPORT.md（本件，待 TL 代落盘）**
