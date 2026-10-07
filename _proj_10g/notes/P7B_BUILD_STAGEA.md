# P7B_BUILD_STAGEA —— Build 1（Stage A：P1/P2 + 快照窗口 61→63 字）构建读数

**日期** 2026-10-07 · **构建 agent 报告** · 工作区 = HEAD `95c9485` + 未提交改动
（RTL 面 = `rtl/app_ctrl.v` P1/P2/F2 + `board/wrapper_p4.v` 窗口 63 字/槽 22-23/BUILD_ID 9 +
`_proj_pcie/rtl/axi_regs.v` **仅注释**）

## 0. 一句话

Build 1 **建成**：三条硬门的主 stdout 栏全 0、时序 **三类失败端点 0/0/0**（WNS `+0.100` / WHS `+0.010` / WPWS `0.000`，
`board/p7b_ku5p_timing.rpt:156,159`）；**新锥（W61/W62/wu_act）未进 DP 前 10**；
对抗审查指名的 `u_snap_p7bdp/hold_b_reg[*]` 族**全族 524 位逐端点已扫**（§4），最差 hold `0.011ns`（旧位 642，MET），
判**非新族**；位流 sha256 `b9f16c75…d804`（15,431,261 B）—— ⛔ **未烧板**（本轮纪律：不烧板、不写 `0x08`）。

## 1. 逐字命令 / 时刻 / 耗时 / 配置自证

```
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'
```

| 项 | 值 | 来源 |
|---|---|---|
| START / END | `2026-10-07 10:05:27 +0800` → `10:28:35 +0800` | 本 agent 的 tee 日志首尾行 |
| **耗时** | **23 min 08 s**（构造脚本预告 21.5–27 min） | 同上 |
| 宏 | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1` | `board/p7b_ku5p_stdout.txt` `P7B_VERILOG_DEFINE` |
| top / 文件数 | `wrapper_p4` / `P7B_NFILES = 440` | 同 stdout |
| IP 收敛 | `P7B_CONVERGED_AT_ROUND = 2`（round#1 = 5 失配 → round#2 = 0；设 `CONFIG.CORE` 重置从属参数的既定行为） | 同 stdout |
| IP 读数 | `CORE = Ethernet PCS/PMA 64-bit` · `NUM_OF_CORES = 2` · `LINE_RATE = 10` · `GT_REF_CLK_FREQ = 156.25` · `IS_LOCKED_POSTGEN = 0` | 同 stdout |
| 完成判据 | `P7B_SYNTH_STATUS = synth_design Complete!` · `P7B_IMPL_STATUS = write_bitstream Complete!` · `P7B_BIT_EXISTS = 1` · `P7B DONE` · `BITSTREAM-OK` · `BUILD_EXIT=0` | bat tee 日志 + stdout |
| 路由 | `INFO: [Route 35-16] Router Completed Successfully` | `vivado_prj/p7b_ku5p_prj.runs/impl_1/runme.log:944` |

**并发声明（全局 #50 防假红）**：10:05:27–10:28:35 全程本机只有这一个 Vivado 在跑（无并发构建/仿真/烧录；
两次 dcp 定向查询都在构建**结束后**）。本轮读数未见任何异常形态。

## 2. 两栏门（`bash _proj_10g/notes/p7b_biz_build/gatecheck.sh /d/repo/XCKU5PMini/udp_hls_10g`）

⚠️ 该脚本自己也 `exit 0` —— 以下判定 = 我读它的输出（留档 `_proj_10g/notes/p7b_build_stageA/gatecheck_out.txt`）。
栏 A = 主 stdout；栏 B = `{synth_1,impl_1,pcs64_synth_1,xdma_0_synth_1}/runme.log` 合计。

| 硬门键 | 栏A | 栏B | 判定 |
|---|---|---|---|
| `12-4739`（约束被静默丢弃） | 0 | 0 | 过 |
| `Synth 8-11241` | 0 | **33** | 见下 ⚠️ |
| `undeclared symbol` | 0 | **33** | 同上（同一族消息的两键） |
| `VRFC 10-3091] actual bit length 1 differs…` | 0 | 0 | 过 |
| `VRFC 10-2989` | 0 | 0 | 过 |
| `implicitly declared` | 0 | 0 | 过（2025.2 下恒 0，哑键） |
| `NSTD-1` / `UCIO-1` / `AVAL-326` | 0/0/0 | 0/0/0 | 过 |
| `Opt 31-155` / `Opt 31-67` / `Route 35-7` | 0/0/0 | 0/0/0 | 过 |
| 附加面：`^ERROR` | 0 | 0 | 过 |
| 附加面：`^CRITICAL WARNING` | 3 | 3 | 见下 ⚠️ |

⚠️ **33 条 `Synth 8-11241`/`undeclared symbol` 的真实身份**：全部是 **AMD IP 自己生成的代码**里的
`INFO: [Synth 8-11241] undeclared symbol '<gt wizard 端口名>' …`（`pcs64_synth_1/runme.log:28-55` 共 28 条 +
`xdma_0_synth_1/runme.log:28-33` 共 5 条；文件均指向 `vivado_prj/…/ip/pcs64/…` 与 `…/ip/xdma_0/…`）。
**基线对照 = 逐数相同**：WU 轮（现役位流 `1076e50e…` 那一次构建）的 gatecheck
（`_proj_10g/notes/p7b_wu_build/gatecheck_out.txt`）两栏 = **0 / 33**、`undeclared symbol` = **0 / 33** —— 与本轮逐字一致。
⇒ 判：**厂商 IP 固有、非本轮引入**（本工程自己的 RTL 在 `synth_1` 栏 **0 命中**）。
⚠️ 如实登记：若按"栏 B 任一侧非 0 即 FAIL"的**严格口径**，本构建 FAIL —— 但**基线构建同样 FAIL**，
口径选择权不在构建 agent。

⚠️ **3 条 CRITICAL WARNING**（主 stdout `:1277,:3305,:4258`）：`[Constraints 18-1056] Clock 'gtrefclk0' completely overrides clock 'gt_refclk_p'` ×2
+ `[Vivado 12-1790] Evaluation License Warning` ×1（`xxv_ethernet` 的评测声明，与基线**同数同文**；
runme.log 侧 3 条 = impl_1:60 / synth_1:979 / impl_1:1013）。WU 轮同栏计数 = **3/3**，逐数相同。

**DRC 对照**：`board/p7b_ku5p_drc.rpt` 与基线 `BASE_p7b_ku5p_drc.rpt`（均 69 checks）除时间戳外
**`diff` 无差异**（逐字相同）⇒ 无新增 DRC。

## 3. 时序对照表（基线 = WU 构建 `1076e50e…`，同流程同策略 `Performance_ExtraTimingOpt`）

**0 失败端点的出处（我亲自读到的报告行）**：新 `board/p7b_ku5p_timing.rpt:156` 数字行 + `:159`
逐字 `All user specified timing constraints are met.`；基线同文件 `_proj_10g/notes/p7b_build_stageA/BASE_p7b_ku5p_timing.rpt:156,159`。

| 指标 | 基线（WU） | **Build 1** | 差 |
|---|---|---|---|
| **WNS** | +0.147 | **+0.100** | **−0.047** |
| **WHS** | +0.010 | **+0.010** | 0 |
| **WPWS** | 0.000 | **0.000** | 0 |
| setup 失败端点 (TNS) | 0 | **0** | 0 |
| hold 失败端点 (THS) | 0 | **0** | 0 |
| PW 失败端点 (TPWS) | 0 | **0** | 0 |
| 端点总数 (setup/hold) | 242,080 | 242,411 | **+331** |
| 端点总数 (PW) | 78,746 | 78,967 | +221 |
| **DP 域** (`g_hw.clk_out0`) setup 最差 / 失败 | 0.147 / 0 | **0.100 / 0** | −0.047 |
| DP 域 hold 最差 / 失败 | 0.010 / 0 | **0.010 / 0** | 0 |
| DP 域 PW 最差 / 失败 | 2.627 / 0 | 2.627 / 0 | 0 |
| DP 域端点（setup/hold） | 135,245 | 135,235 | −10 |
| `async_default` DP（异步复位 R/C） | 0.743 / 0.125 / 0 失败 | **0.551 / 0.116 / 0 失败** | −0.192 / −0.009 |
| `async_default` pcie_axi_aclk | 0.496 / 0.122 / 0 失败 | **0.170 / 0.114 / 0 失败** | −0.326 / −0.008 |
| 互时钟 `txoutclk_out[0]_3→rxoutclk_out[0]_3` | 5.072 / 0.032 / 0 失败 | **4.953 / 0.010 / 0 失败** | −0.119 / −0.022 |

（新值出处：`board/p7b_ku5p_timing.rpt:156` 总表、`:1963-1968` DP 段头、`:200-229` Intra 表、`:246-260` Other Path Groups 表、`:230-240` Inter 表；
基线值出处：同文件的 `BASE_` 副本同位置。）

**有违例吗？没有**（三类皆 0）—— 但简报要求"有违例就列族并判是不是同族"，无违例改判**最差族是否同族**，答案是**两条最差都同族**：

| 最差 | Build 1 | 基线 | 判 |
|---|---|---|---|
| 全局/DP setup | `u_app_udp/u_txf/dout_reg[69]` → `u_udp_tx/ip_csum_r_reg[1][12]/D`，19 级，route 56.0%（`p7b_ku5p_timing.rpt:1974` 起） | **同源族** `…/dout_reg[68]` → `…/ip_csum_r_reg[*]`，20 级（`BASE:2010` 起） | **同族换最差位**（同一 app_udp TX 载荷 → UDP IP 校验和锥） |
| DP hold | `u_udp_split/u_desc/wptr_reg[0]` → `u_desc/mem_reg_0_63_14_20/RAM*/WADR0`，0.010，0 级 | 同族（基线有 `u_udp_split/u_udp_rx/emit_k_reg[5] → …/RAMF/I` 0.011 等 5 条同型） | **同族** |
| WPWS = 0.000 的来源 | `PCIE40E4/PIPECLK` Min Period req=4.000 act=4.000 → slack 0.000（**MET**）+ `PCIE40E4/MCAPCLK` req=act=8.000 → 0.000（**MET**）（`p7b_ku5p_timing.rpt:1752,1777`） | 基线**同两条**（`BASE` 同款行） | **同族**（PCIe 硬核内部，非本设计逻辑） |

⚠️ 口径提醒：bat 打的 `P7B_WPWS` 行是**一列每 group 的最差 slack 列表**（非标量，本轮最小 = 0.010）；
WPWS 真值以报告总表（0.000 / 0 失败）为准 —— 这是 bat 脚本的既有形态，两轮一致。

## 4. `u_snap_p7bdp/hold_b_reg[*]` 专门读数（对抗审查指名的必查项）

**方法**（只读 dcp，不烧板）：`open_checkpoint …impl_1/wrapper_p4_routed.dcp` +
`get_timing_paths -delay_type {min,max} -to <pin>/D -max_paths 1` ×524 位 ×2；
脚本 `_proj_10g/notes/p7b_build_stageA/holdb_query2.tcl`，原始输出 `holdb_query2_out.txt`（v1 因 `DESTINATION_PIN` 属性不存在崩过一次，
v2 修正为 `ENDPOINT_PIN`，同时保留逐位循环）。
**族的确切定义**：`u_snap_p7bdp` = `board/wrapper_p4.v:3637` 的 `snap_cdc #(.W(32), .NW(24))`，
`hold_b` 是 `rtl/snap_cdc.v:92` 的一根 `NW*W = 768` 位寄存器。

**先解释 524（不是 768）**：实测存在位区间 = `2-21, 27-30, 32-63, 192-223, 256-324, 352-608, 640-735, 739-752`。
消失的 244 位全是**常量折叠**（无 FF 需求，不是缺陷）：
槽 2…5 = `32'd0`（128 位，`wrapper_p4.v:3600-3607` 的 generate，头部注释写明"由 tx 束装配"）、
W46/W58 整字/高位常量（32+31 位）、W49 高 27 位、**W62 的低 3 位**（`app_rx_occ = {wptr-rptr, 3'b0}` 左移 3 ⇒ 恒 0，`wrapper_p4.v` 的 `biz_w62` 注释）+ 高 15 位（`{15'd0,…}`）。
（新字映射：W61 = `stat_wu` = 位 704..735；W62 = `rx_occ` = 位 736..767，实际存在 739..752 = occ 位 3..16。）

**全族结论**：

| 项 | 读数 |
|---|---|
| 存在 D 端点数 | **524**（523 条有约束 + 1 条仅非约束：[30] 只有 `rxoutclk/txoutclk → dp` 的 async-clock-groups 路径，`Path Group:(none)`，非真实判据） |
| **hold 最差** | **0.011 ns（MET）**，位 **642**（旧位 = W59 `slow_tx_adp.stat_fifo_ovf` 的 bit2），LL=0，源 `u_slow_tx/stat_fifo_ovf_reg[2]/C`（`wrapper_p4_timing_summary_routed.rpt:14730`） |
| hold 分档（523 条） | `<0.02 = 4` ｜ `0.02–0.05 = 39` ｜ `0.05–0.10 = 164` ｜ `≥0.10 = 316`；**无违例**（且全局 `THS failing = 0`，§3 出处） |
| **setup 最差** | **3.645 ns**，位 585（`u_tcp_tx/retx_hi_reg[9]`），523 条全部 ≥3.6 ⇒ 全族 setup 距 6.4 ns 周期余量 ≥56% |
| **新位 W61（704-735）** | hold 最差 **0.021**（位 727，LL=0，源 `u_app_ctrl/stat_wu_reg[23]`）；setup 最差 5.307 |
| **新位 W62（存在的 739-752）** | hold 最差 **0.221**（位 741，**LL=2**，源 `u_tcp_echo/u_fifo/wptr_reg[1]_rep__2` —— 减法器锥）；setup 最差 **4.037**（位 750，**LL=3**，源 `u_tcp_echo/u_fifo/rptr_reg[0]`） |

**"是不是新族"判定 —— 不是新族。三条独立支证：**
1. **结构面**：整族清一色是"dp 域寄存器 → hold_b D 脚"，且绝大多数 **LL=0** = 该位被综合成 **FDCE 的 CE 形式**
   （`hold_b <= update_b ? din_b : hold_b` ≡ 时钟使能），即**数据通路是一根直连线** ⇒ 这批端点的 hold 余量由**时钟偏斜**支配而非逻辑深度
   —— 这正是"4 条 <0.02、39 条 <0.05"成簇出现的原因，是**族的结构性质**，基线的同族报告里也是这一形状（基线 `[30]/D` 出现在 `Timing Exception: Asynchronous Clock Groups` 的非约束段：Max 侧 `Slack: inf`、Min 侧 0.210；同族 DP 内有约束路径未进前 10）。
2. **基线对照**：`hold_b_reg[642]` 在基线 **8.5 MB `-max_paths 10` 全文报告里 0 命中**
   （`_proj_10g/notes/p7b_wu_build/timing_archive/…NEW_1076e50e.rpt`，`grep -c` = 0），而基线同段 (DP-DP) Min 前 10 的门限 = **0.012**
   ⇒ 基线时它**不在最差 10**、本轮到 0.011 进前 10。该端点**不是本轮的任何一个新位**（642 ∈ W59，BIZ 轮就有），
   偏移幅度（≤0.001+）远小于本流程的 P&R 重排幅度（±0.4~1.3 ns，WU 轮已立此结论）。
3. **新锥自证**：简报担忧的 W62 组合锥在 **hold 侧反而最松**（0.221，因为 17 位减法器给数据路径加了延迟 ⇒ 对 hold 有利），
   setup 侧 4.037（LL=3）离 6.4 ns 周期还有 63% 余量 ⇒ **W62 的"组合派生"两向都没有制造紧张端点**。
   W61（stat_wu 直连）的 0.021 是族内第二档，但**不是族内最差**（最差是旧位 642）。

## 5. DP 前 10 名单（判"新锥有没有进"）

来源：新 `impl_1/wrapper_p4_timing_summary_routed.rpt` 的 DP-DP 段（`To Clock` 行 `:13323`，首条路径 `:13333`），
与基线归档**同一条报告的同一格式**（`-max_paths 10 -routable_nets -report_unconstrained`）。

| # | Build 1 slack / 源 → 宿 / 级 | 基线 slack / 源 → 宿 / 级 |
|---|---|---|
| 1 | **0.100** `u_app_udp/u_txf/dout_reg[69]` → `u_udp_tx/ip_csum_r_reg[1][12]` / 19 | 0.147 `…/dout_reg[68]` → `…/ip_csum_r_reg[0][5]` / 20 |
| 2 | 0.173 `dout_reg[69]` → `ip_csum_r_reg[0][12]` / 19 | 0.159 `dout_reg[68]` → `[1][5]` / 20 |
| 3 | 0.200 `u_clkgen/rel_sr_reg[3]` → `rx_trace_mem_reg[510]` / 1 | 0.159 `dout_reg[68]` → `[0][12]` / 19 |
| 4 | 0.212 `rel_sr_reg[3]` → `rx_trace_mem_reg[463]` / 1 | 0.195 `dout_reg[68]` → `[1][12]` / 19 |
| 5 | 0.217 `rel_sr_reg[3]` → `rx_trace_mem_reg[58]` / 1 | 0.198 `rel_sr_reg[3]` → `rx_trace_mem_reg[1726]` / 1 |
| 6 | 0.219 `rel_sr_reg[3]` → `rx_trace_mem_reg[80]` / 1 | 0.198 `dout_reg[68]` → `[1][13]` / 19 |
| 7 | 0.221 `rel_sr_reg[3]` → `rx_trace_mem_reg[31]` / 1 | 0.207 `rel_sr_reg[3]` → `u_tcp_tx/u_retx/…RSTRAMB` / 0 |
| 8 | 0.231 `rel_sr_reg[3]` → `rx_trace_mem_reg[707]` / 1 | 0.223 `rel_sr_reg[3]` → `rx_trace_mem_reg[551]` / 2 |
| 9 | 0.236 `rel_sr_reg[3]` → `rx_trace_mem_reg[1616]` / 1 | 0.227 `rel_sr_reg[3]` → `rx_trace_mem_reg[1375]` / 1 |
| 10 | 0.239 `rel_sr_reg[3]` → `rx_trace_mem_reg[848]` / 1 | 0.229 `dout_reg[68]` → `[0][13]` / 19 |

**判**：① 同源族 **6 → 2**（`dout_reg[68]→[69]` 换位，同族未新增）；② 余下 8 条 = `rel_sr_reg[3] → rx_trace_mem`
（基线 5 条同族）；③ **新锥一条都没进** —— 快照/`hold_b`/W61/W62 减法器/wu_act 在 DP 前 10 里**零出现**
（新锥最差 setup = 4.037 ns，距前 10 门限 0.239 还有 ≈3.8 ns）。

## 6. 资源对照

| 资源 | 基线（WU） | **Build 1** | 差 |
|---|---|---|---|
| CLB LUTs | 71,238（32.83%） | **71,094（32.77%）** | **−144** |
| CLB Registers | 69,744（16.07%） | **69,965（16.12%）** | **+221** |
| F7 Muxes | 3,688 | 3,673 | −15 |
| Block RAM Tile | 348（72.50%） | **348（72.50%）** | 0 |
| URAM | 0（0%） | **0（0%）** | 0 |
| DSPs | 4 | 4 | 0 |
| Bonded IOB | 10 | 10 | 0 |

出处：`board/p7b_ku5p_util.rpt:36,41,45,109,114,125,136` vs `BASE_p7b_ku5p_util.rpt` 同位置。
FF +221 vs 预期 +208（= 快照三份 64×3 + `wu_act` 16）：**方向与量级相符**（+13 差额未逐条归因，见 §9）。
LUT −144 说明净逻辑被优化/重排吸收（新增保护的或非门 + mux 被合并），**不是漏建**（新逻辑在报告的锥里可见，§4/§5）。

## 7. 位流

| 项 | 值 |
|---|---|
| 路径 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit` |
| **sha256** | **`b9f16c754e693ca48997c70c49b9ac21e5cd404d52c6ca2eb5a64d7b8146d804`** |
| 字节数 / 时间 | 15,431,261 B / 2026-10-07 10:27 |
| 板级 | ⛔ **未烧**（本轮纪律）；板上现役仍是基线 `1076e50e…1160` |
| 基线备份 | `_proj_10g/notes/p7b_build_stageA/wrapper_p4_BASELINE_WU_1076e50e.bit`（sha256 已复核 = `1076e50e6d80e155538122ea6918a608c1d9427dafef188c5111b7317f1e1160`，构建前抢救） |

## 8. 修订漂移检查（构建前 → 构建后）

| 文件 | 构建前 sha256 | 构建后 sha256 | 判 |
|---|---|---|---|
| `rtl/app_ctrl.v` | `f6c5b296…899a9` | `f6c5b296…899a9` | **无漂移** |
| `board/wrapper_p4.v` | `76945167…7d40` | `76945167…7d40` | **无漂移** |
| `_proj_pcie/rtl/axi_regs.v` | `686abf64…9f02` | `686abf64…9f02` | **无漂移** |

⇒ 本轮读数有效（整轮不作废）。未提交 git（纪律）。

## 9. 没能证明的部分（如实登记）

1. **板上行为一律未测**：本轮不烧板 ⇒ 位流只证"能出、时序收口"，**不证** W61/W62 在板上的读回值、不证 wu 修复的板级行为（那是后续板级轮的事）。
2. **基线逐端点不可复算**：`create_project -force` 已重建工程 ⇒ 基线 routed dcp 不存在；基线同族的对照只能用 WU 轮自留的
   `-max_paths 10` 全文归档做"**是否进前 10**"这个粗判据（§4 支证 2），**不能**逐端点算差。
3. **0.011 那位（bit 642）与基线的精确差量不可归因**：只知道"基线不在最差 10（其 slack ≥ 0.012，未列入）、本轮 0.011"；P&R 重排幅度 ±0.4~1.3 ns 是已知量级，
   本端点偏移远小于此 ⇒ 无法把这一格单独归因到某个改动（也不该硬归因）。
4. **+221 FF 的构成未逐条证明**（推断 = 192 快照三份 + 16 `wu_act` + 13 未归因）。
5. **W62 的功能语义（读回值 = 真实占用）未证**：本轮只证"它作为组合源进 D 脚后，STA 两向都有余量"。
6. **33 条栏 B 命中的口径裁定不在我**：我判"厂商 IP 固有 + 与基线逐数相同 ⇒ 非本轮引入"，但"任一侧命中即 FAIL"的严格口径会让**基线也 FAIL**（§2）。
7. **`IS_LOCKED_POSTGEN = 0` 只说明 IP 未被锁**，不构成 license 的独立证明（license 分叉的既有结论见 `CLAUDE.md` / `_lic/`；本轮未重做）。
8. 基线 `BASE_*.rpt` 与 WU 轮归档的关系：本报告的基线读数每一条都来自我**亲自读的** `BASE_` 副本行号（§3/§6 已列），
   不是转抄既有笔记；但我**未**逐条核对笔记 `P7B_WU_BUILD.md` 里的历史数字与本副本的一致性（副本本身 sha256 未记录）。

## 附：本轮产出物清单（都在 `_proj_10g/notes/p7b_build_stageA/`）

| 文件 | 内容 |
|---|---|
| `bat_stdout.txt` | bat 全程 tee（START/END + BUILD_EXIT + 读数行 + BITSTREAM-OK） |
| `gatecheck_out.txt` | 两栏门原始输出 |
| `BASE_p7b_ku5p_{timing,util,drc,clkinteract}.rpt` | 构建前抢救的基线报告（WU 轮） |
| `wrapper_p4_BASELINE_WU_1076e50e.bit` | 基线位流备份 |
| `holdb_query.tcl` / `holdb_query2.tcl` / `holdb_query{,2}_out.txt` | hold_b 族定向查询脚本与原始输出（v1 崩因留档） |
