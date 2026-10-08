# P7B_BUILD_STAGEB —— Build 2（Stage B：`rtl/app_pattern.v` RX 8 路并行 R1）构建读数

**日期** 2026-10-07 · **构建 agent 报告** · 工作区 = HEAD `e9a4d23` + 未提交改动（**唯一被跟踪的 RTL 改动 = `M rtl/app_pattern.v`**，+199 行，全部包在既有宏 `ifdef P7B_10G` 内）

## 0. 一句话

Build 2 **建成**：三条硬门两栏与基线逐数相同（§2）、**三类失败端点 0/0/0**（WNS `+0.006` / WHS `+0.008` / WPWS `0.000`，`board/p7b_ku5p_timing.rpt:156,159`）；
⭐ **对抗审查的预测被实测证实、且精确**：新锥 **11 级 / logic 1.230 ns**（审查估 "10–11 级 ≈1.2–1.5 ns"）⇒ **新锥一条都没进 DP 前 10**（新锥最差 2.083 ns vs 前 10 门限 0.173 ns，**12×** 余量）；
⭐ **最差族没换** —— 仍是 `u_app_udp/u_txf/dout_reg[*] → u_udp_tx/ip_csum_r_reg[*]`（同族换最差位 `[69]→[70]`，**DP 前 10 被它整体占满 2→10 条**），
**WNS 掉的 0.094 ns 全部落在这一条老旧族上**，正是审查预言的"风险在 P&R 重排不在新锥"。
位流 sha256 `1ccbd9cd…6cdd07`（15,431,261 B）—— ⛔ **未烧板**（本轮纪律：不烧板、不写 `0x08`、不改 `rtl/`）。

## 1. 逐字命令 / 时刻 / 耗时 / 配置自证

```
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'
```

| 项 | 值 | 来源 |
|---|---|---|
| START / END | `2026-10-07 12:59:10 +0800` → `13:24:32 +0800` | 本 agent 的 tee 日志首尾行（`p7b_build_stageB/bat_stdout.txt`） |
| **耗时** | **25 min 22 s**（简报预告 23–27 min） | 同上 |
| 宏 | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1` | `board/build_p7b_ku5p.tcl:145`；stdout `P7B_VERILOG_DEFINE` |
| IP 收敛 | `P7B_CONVERGED_AT_ROUND = 2`（与基线逐字相同） | stdout |
| IP 读数 | `P7B_IS_LOCKED_POSTGEN = 0` | stdout |
| 完成判据 | `P7B_SYNTH_STATUS = synth_design Complete!` · `P7B_IMPL_STATUS = write_bitstream Complete!` · `P7B_BIT_EXISTS = 1` · `P7B DONE` · `BITSTREAM-OK` · `BUILD_EXIT=0` | stdout + bat tee |
| 路由 | `INFO: [Route 35-16] Router Completed Successfully` | `impl_1/runme.log` |

**并发声明（全局 #50 防假红）**：12:59:10–13:24:32 全程 `tasklist` 只看到**一个** `vivado.exe`（= 本构建）。
两次 dcp 定向查询（`newcone_query` 13:27–13:28、`detail_query` 13:31–13:32）都在**构建结束之后**。
另有两支并发 agent（只改文档/判据；只读扫描）—— 它们**未起 Vivado、未起 xsim**，**未碰 `rtl/`**（§8 漂移检查佐证）。

## 2. 两栏门（`bash _proj_10g/notes/p7b_biz_build/gatecheck.sh /d/repo/XCKU5PMini/udp_hls_10g`）

⚠️ 该脚本自己也 `exit 0` —— 以下判定 = 我读它的输出（留档 `p7b_build_stageB/gatecheck_out.txt`）。
栏 A = 主 stdout；栏 B = `{synth_1,impl_1,pcs64_synth_1,xdma_0_synth_1}/runme.log` 合计。**基线两栏** = 我构建前抢救的 Stage A 归档（`BASE_gatecheck_stageA_out.txt`）+ WU 归档（`BASE_gatecheck_wu_out.txt`）。

| 硬门键 | 栏A | 栏B | 基线（WU / Stage A） | 判定 |
|---|---|---|---|---|
| `12-4739`（约束被静默丢弃） | 0 | 0 | 0 / 0 · 0 / 0 | 过 |
| `Synth 8-11241` | 0 | **33** | 0 / **33** · 0 / **33** | **逐数相同** |
| `undeclared symbol` | 0 | **33** | 0 / **33** · 0 / **33** | **逐数相同** |
| `VRFC 10-3091] actual bit length 1 differs…` | 0 | 0 | 0 / 0 | 过 |
| `VRFC 10-2989` | 0 | 0 | 0 / 0 | 过 |
| `implicitly declared` | 0 | 0 | 0 / 0（2025.2 下哑键） | 过 |
| `NSTD-1` / `UCIO-1` / `AVAL-326` | 0/0/0 | 0/0/0 | 0/0/0（两轮同） | 过 |
| `Opt 31-155` / `Opt 31-67` / `Route 35-7` | 0/0/0 | 0/0/0 | 0/0/0（两轮同） | 过 |
| 附加面：`^ERROR` | 0 | 0 | 0 / 0 | 过 |
| 附加面：`^CRITICAL WARNING` | **3** | **3** | **3 / 3**（两轮同） | **逐数相同** |

⚠️ **33 条栏 B 命中的真实身份**：全部是 **AMD IP 自己生成的代码**（`pcs64_synth_1/runme.log:28-55` 共 28 条 `gtwiz_*`/`qpll*_*_in` + `xdma_0_synth_1/runme.log` 5 条），
文件路径均指向 `vivado_prj/…/ip/pcs64/…` 与 `…/ip/xdma_0/…`。**本工程自己的 RTL 在 `synth_1` 栏 0 命中**（与我逐条 `synth_1/runme.log` 核对一致）。
⇒ 判 **厂商 IP 固有、非本轮引入**。⚠️ 同 Stage A 的口径提醒：若按"栏 B 任一侧非 0 即 FAIL"的**严格口径**，本构建 FAIL —— 但**基线与 WU 同样 FAIL**，口径选择权不在构建 agent。

⚠️ **3 条 CRITICAL WARNING** = `[Constraints 18-1056] Clock 'gtrefclk0' completely overrides clock 'gt_refclk_p'` ×2 + `[Vivado 12-1790] Evaluation License Warning` ×1（`xxv_ethernet` 评测声明）—— 与基线**同数同文**（WU 轮同栏 = 3/3）。

**DRC 对照**：`board/p7b_ku5p_drc.rpt` 与 `BASE_p7b_ku5p_drc.rpt`（均 **69 checks**）**除第 4 行时间戳外 `diff` 无差异**（`diff <(grep -v "| Date" …)` 空输出）⇒ **无新增 DRC**。

**时钟交互对照**：`clkinteract.rpt` 全部差异**只在 slack 数值与端点数**，**每一行的 `Clean`/`No Common Node` 分类逐字未变**（含既存的 `txoutclk_out[0]_3 → rxoutclk_out[0]_3 = No Common Node / Timed (unsafe)`，**基线同样如此**）⇒ **未引入新的时钟交互分类**。

## 3. 时序对照表（基线 = Build 1 / Stage A，同流程同策略 `Performance_ExtraTimingOpt`）

**0 失败端点的出处（我亲自读到的报告行）**：新 `board/p7b_ku5p_timing.rpt:156`（总表数字行）+ `:159` 逐字 `All user specified timing constraints are met.`；基线同文件 `p7b_build_stageB/BASE_p7b_ku5p_timing.rpt:156,159`。

| 指标 | 基线（Build 1） | **Build 2** | 差 |
|---|---|---|---|
| **WNS** | +0.100 | **+0.006** | **−0.094** ⚠️ |
| **WHS** | +0.010 | **+0.008** | −0.002 |
| **WPWS** | 0.000 | **0.000** | 0 |
| setup 失败端点 (TNS) | 0 | **0** | 0 |
| hold 失败端点 (THS) | 0 | **0** | 0 |
| PW 失败端点 (TPWS) | 0 | **0** | 0 |
| 端点总数 (setup/hold) | 242,411 | **242,843** | +432 |
| 端点总数 (PW) | 78,967 | **79,109** | **+142** |
| **DP 域** (`g_hw.clk_out0`) setup 最差 / 失败 | 0.100 / 0 | **0.006 / 0** | −0.094 |
| DP 域 hold 最差 / 失败 | 0.010 / 0 | **0.010 / 0** | 0 |
| DP 域 PW 最差 / 失败 | 2.627 / 0 | **2.627 / 0** | 0 |
| DP 域端点（setup/hold） | 135,235 | **135,660** | +425 |
| `async_default` DP（异步复位 R/C） | 0.551 / 0.116 / 0 失败 | **0.758 / 0.177 / 0 失败** | **+0.207 / +0.061** |
| `async_default` pcie_axi_aclk | 0.170 / 0.114 / 0 失败 | **0.158 / 0.157 / 0 失败** | −0.012 / +0.043 |
| 互时钟 `txoutclk_out[0]_3→rxoutclk_out[0]_3` | 4.953 / 0.010 / 0 失败 | **4.909 / 0.014 / 0 失败** | −0.044 / +0.004 |

（新值出处：`board/p7b_ku5p_timing.rpt:156` 总表、`:221` DP 段头、`:248-256` Other Path Groups 表；基线值出处：`BASE_p7b_ku5p_timing.rpt` 同位置。`async_default` 一族其余行见附件对照，全部 0 失败。）

⚠️ **口径提醒**：bat 打的 `P7B_WPWS` 行是**一列每 group 的最差 slack 列表**（非标量，本轮最小 = 0.006）；WPWS 真值以报告总表（0.000 / 0 失败）为准 —— bat 脚本的既有形态，两轮一致。

**有违例吗？没有**（三类皆 0）。改判**最差族是否同族**，答案是 **同族、且同族内部恶化**：

| 最差 | Build 2 | 基线（Build 1） | 判 |
|---|---|---|---|
| 全局 / DP setup | `u_app_udp/u_txf/dout_reg[70]` → `u_udp_tx/ip_csum_r_reg[1][9]/D`，**20 级**，route **55.7%**，0.006（`p7b_ku5p_timing.rpt:1989-1998`） | **同源族** `…/dout_reg[69]` → `…/ip_csum_r_reg[1][12]/D`，19 级，route 56.0%，0.100（`BASE:1974-1983`） | **同族换最差位**（同一 app_udp TX 载荷 → UDP IP 校验和锥；源换 `[69]→[70]`、宿换 `[1][12]→[1][9]`，级数 19→20） |
| DP hold | 最差 0.010 `u_udp_split/u_udp_rx/mac_lo_reg[7]` → `u_udp_tx_cfg/peer_mac_r_reg[39]/D`，LL=0 | 基线**同族**（Stage A §3 判同族） | **同族** |
| WPWS = 0.000 的来源 | `PCIE40E4/PIPECLK` req=act=4.000 → 0.000（**MET**）+ `MCAPCLK` 8.000 → 0.000（**MET**） | 基线**同两条** | **同族**（PCIe 硬核内部，非本设计逻辑） |

⚠️ **简报给的基线行有一处错**（我按原始件核对）：简报写"全局最差 `dout_reg[69]` → `ip_csum_r_reg[0][5]/D`（20 级 / route 55.5%）"。
实测 **`[0][5]` 是 WU 轮**（`p7b_wu_build/timing_archive/wrapper_p4_timing_summary_routed.NEW_1076e50e.rpt:13564`，源 `dout_reg[68]`，该档 `dout_reg[69]` 命中 **0** 次），
**Build 1 的真身是 `[1][12]` / 19 级**（`BASE_p7b_ku5p_timing.rpt:1977`，我构建前亲自抢救的原始件）。
⇒ 简报把 **WU 的宿端 + Build 1 的源端**拼成了一行。本报告一律以**我抢救的原始件**为准。

## 4. DP 前 10 名单（判"新锥有没有进"）+ 最差族判定

来源：新 `impl_1/wrapper_p4_timing_summary_routed.rpt` 的 DP-DP 段（`Max Delay Paths` 起 `:13385`，段内 **恰 10 条**）；
**并用 `get_timing_paths -from/-to [get_clocks g_hw.clk_out0] -max_paths 40` 在 routed dcp 上独立复核**（`p7b_build_stageB/newcone_query_out.txt` 的 `QC_DPTOP` 1–14）—— **两条口径逐条一致**。

| # | Build 2 slack / 源 → 宿 / 级 | 基线（Build 1）slack / 源 → 宿 / 级 |
|---|---|---|
| 1 | **0.006** `u_app_udp/u_txf/dout_reg[70]` → `u_udp_tx/ip_csum_r_reg[1][9]` / 20 | 0.100 `…/dout_reg[69]` → `ip_csum_r_reg[1][12]` / 19 |
| 2 | 0.010 `dout_reg[70]` → `ip_csum_r_reg[1][13]` / 20 | 0.173 `dout_reg[69]` → `ip_csum_r_reg[0][12]` / 19 |
| 3 | 0.018 `dout_reg[70]` → `ip_csum_r_reg[1][5]` / 19 | 0.200 `u_clkgen/rel_sr_reg[3]` → `rx_trace_mem_reg[510]` / 1 |
| 4 | 0.079 `dout_reg[70]` → `ip_csum_r_reg[0][9]` / 20 | 0.212 `rel_sr_reg[3]` → `rx_trace_mem_reg[463]` / 1 |
| 5 | 0.082 `dout_reg[70]` → `ip_csum_r_reg[0][5]` / 19 | 0.217 `rel_sr_reg[3]` → `rx_trace_mem_reg[58]` / 1 |
| 6 | 0.083 `dout_reg[70]` → `ip_csum_r_reg[0][13]` / 20 | 0.219 `rel_sr_reg[3]` → `rx_trace_mem_reg[80]` / 1 |
| 7 | 0.084 `dout_reg[70]` → `ip_csum_r_reg[1][15]` / 20 | 0.221 `rel_sr_reg[3]` → `rx_trace_mem_reg[31]` / 1 |
| 8 | 0.157 `dout_reg[70]` → `ip_csum_r_reg[0][15]` / 20 | 0.231 `rel_sr_reg[3]` → `rx_trace_mem_reg[707]` / 1 |
| 9 | 0.171 `dout_reg[70]` → `ip_csum_r_reg[0][11]` / 20 | 0.236 `rel_sr_reg[3]` → `rx_trace_mem_reg[1616]` / 1 |
| 10 | 0.173 `dout_reg[70]` → `ip_csum_r_reg[1][2]` / 19 | 0.239 `rel_sr_reg[3]` → `rx_trace_mem_reg[848]` / 1 |

**判**：
1. **最差族没换** —— 仍是 `u_app_udp/u_txf/dout_reg → u_udp_tx/ip_csum_r_reg`（同一 app_udp TX 载荷 → UDP IP 校验和锥），只是**源位 `[69]→[70]`**、宿位换位、级数 19→20。
2. ⚠️ **该族的 DP 前 10 占位从 2 条涨到 10 条**（基线余下 8 条 = `rel_sr_reg[3] → rx_trace_mem`，**本轮全部被挤出前 10**）⇒ WNS 掉的 0.094 ns **全部落在这条老旧族上**，不是新逻辑。
3. ⛔ **新锥（`u_app` 的 RX 8 路：`rx_lfsr → xs_word8 → 逐 lane 比较 → pop8 → 32 位加`）一条都没进 DP 前 10** —— 前 10 门限 = 0.173 ns，而新锥最差 = **2.083 ns**（§5），**差 12×**。

⭐ **同族占位的三轮摆动 = "P&R 重排"归因的独立正面证据**（我逐条读原始件得到，非转抄）：

| 构建 | 该族（`dout_reg[*] → ip_csum_r_reg`）在 DP 前 10 的**占位** | 源位 | 该族最差 slack |
|---|---|---|---|
| WU 轮（`NEW_1076e50e.rpt` DP-DP Max 段，**恰 10 条**，跨 0.147–0.229） | **6 / 10** | `dout_reg[68]` | 0.147 |
| Build 1 / Stage A（引 Stage A §5 文字表） | **2 / 10** | `dout_reg[69]` | 0.100 |
| **Build 2 / 本轮** | **10 / 10** | `dout_reg[70]` | **0.006** |

⇒ 该族占位 **6 → 2 → 10**、最差 slack **0.147 → 0.100 → 0.006** —— **非单调**。
**若 Stage B 是"结构性变差"，占位应单调上升**（6 → 2 那一步说不通）；**实测的摆动形状正是 P&R 重排的特征**（本流程重排幅度 ±0.4–1.3 ns 是 WU 轮既定结论 —— ⛔ 2026-10-09 口径订正：该幅度 = **两个不同网表之间**的位移、17 条样本全落 **pcs64/PCIe-GT/pipe_clk 域**；**同输入重跑 = 位级复现、方差 0**；见 `P7B_WU_TIMING_DELTA.md` §8）。
⇒ 支持审查 §B1 的归因（"风险在重排"），**也支持"这 0.094 ns 不该记在 Stage B 新逻辑的账上"**——但 ⚠️ **不等于"Stage B 无成本"**：本轮的具体布局把该族推到了 0.006，**这是一次真实的读数**（§9-7）。
4. DP 前 12 里第一处非 `ip_csum` 的东西 = **#12/#13 `u_app_ctrl/c_snd_nxt_reg[10][1]` → `u_app/stg_reg[24..25]/CE`**（0.188/0.189，LL=15）。
   ⚠️ **它不是本轮的新锥**：`stg` 是 `rtl/app_pattern.v:313` 的 **TX 侧**图案暂存寄存器（消费 `stg_n`/`gen_byte`/`pw_data`，见 `:426,661,690,696`），源是 app_ctrl 的**连接状态**寄存器 ⇒ 属**既有的 "app_ctrl 门控 TX" 通路**，与本轮 RX 改动无关。判 MET。
   ⚠️ 如实登记：它**不在 WU 轮归档的 DP 前 10**（`grep -c u_app/stg_reg NEW_1076e50e.rpt` = **0**，而 WU 前 10 门限 = 0.229 ⇒ 0.188 当时**够得着**）⇒ **它的深度是 WU 之后才变差的**，但**是 Stage A 还是 Stage B 造成的不可判**（Build 1 的 routed 报告已被 `create_project -force` 删除，见 §9-2）。

## 5. `u_app` 新锥定点读数（对抗审查预测的证实/推翻）—— 本轮核心

**方法**（只读 dcp，不烧板、不改 RTL）：`open_checkpoint …impl_1/wrapper_p4_routed.dcp` + 逐端点 `get_timing_paths`。
脚本 `p7b_build_stageB/newcone_query.tcl`（族扫描）+ `detail_query.tcl`（单路径细分），原始输出 `newcone_query_out.txt` / `detail_query_out.txt`。

| 新锥端点族 | D 端点数 | **最差 setup slack** | **级数** | 源 |
|---|---|---|---|---|
| `u_app/stat_mismatch_reg[*]/D` | 32 | **2.083 ns** | **11** | **`u_app/rx_lfsr_reg[20]/C`** |
| `u_app/stat_rx_bytes_reg[*]/D` | 32 | 2.847 ns | 5 | `u_app/FSM_sequential_rxs_reg/C` |
| `u_app/rx_lfsr_reg[*]/D` | 64 | 3.201 ns | 2 | `u_app_ctrl/o_ev_up_reg/C` |

⭐ **最深新锥的细分（`detail_query_out.txt`）**：
```
QD u_app/stat_mismatch_reg[31]/D slack=2.083 LL=11 delay=4.202 logic=1.230 route=2.972 src=u_app/rx_lfsr_reg[20]/C
```
⇒ 数据通路 4.202 ns（**logic 1.230 ns** / route 2.972 ns），11 级。

**对照审查的预测（`P7B_STAGEB_RX8_REVIEW.md` §B1）**："`rx_lfsr → xs_word8(≤3 级 LUT6) → 逐 lane 比较(2) → pop8(2) → 32 位加(4 级 CARRY8) ≈ **10–11 级 ≈ 1.2–1.5 ns** …远小于 6.4 ns 周期，所以**风险不在"新锥太长"而在"重排动了既有最差位"**"

**判：✅ 预测被实测证实，且两段都中，精确度高：**
- **级数**：预测 10–11 级 ⇒ 实测 **11 级**。
- **逻辑延迟**：预测 1.2–1.5 ns ⇒ 实测 **logic = 1.230 ns**（落在预测带**下沿**）。
- **风险归因**：预测"风险在重排不在新锥" ⇒ 实测 **WNS 的 −0.094 全部来自旧族换最差位**，新锥 12× 余量外。**两段都证实。**

⚠️ 同时**推翻作者的估计**：`P7B_STAGEB_RX8.md:168` 写"新锥 **≤4–5 级**" —— 实测 11 级 ⇒ 作者**偏低 2.2–2.75×**，审查的订正（"真锥含那条 32 位 CARRY 链"）是对的。

## 6. 资源对照

| 资源 | 基线（Build 1） | **Build 2** | 差 | 审查/设计件估计 |
|---|---|---|---|---|
| CLB LUTs | 71,094（32.77%） | **71,414（32.92%）** | **+320** | 设计件 `P7B_STAGEB_RX8.md:168` 估 **+0.6–1.0 k** ⇒ 实测**只有估计的 1/2~1/3** |
| CLB Registers | 69,965（16.12%） | **70,107（16.16%）** | **+142** | 设计件估 **+0**（"纯组合 + 复用既有寄存器"）⇒ ⚠️ **不符** |
| F7 Muxes | 3,673 | **3,524** | **−149** | 未给估计 |
| Block RAM Tile | 348（72.50%） | **348（72.50%）** | 0 | 估 +0 ✓ |
| URAM | 0（0%） | **0（0%）** | 0 | 估 +0 ✓ |
| DSPs | 4 | **4** | 0 | — |
| Bonded IOB | 10 | **10** | 0 | — |

出处：`board/p7b_ku5p_util.rpt:36,41,45,109,114,125,136` vs `BASE_p7b_ku5p_util.rpt` 同位置。

⚠️ **+142 FF 与 diff 结构不符（如实登记，未归因）**：`rtl/app_pattern.v` 的 +199 行**没有新增任何 `reg`** —— 只有两个 `function`（`xs_next8`/`xs_word8`，纯组合）、`wire`、以及 FSM `if` 链的改写 ⇒ **综合级应 +0 FF**。
辅助证据：**PW 端点数也恰 +142**（78,967 → 79,109），与"真加了 142 个寄存器"自洽。
⇒ 最可能是 **opt/phys_opt/retiming 层的重构产物**（本流程 post-synth 49,398 FF → post-route 70,107 FF，**+20,709**，±142 只占其 0.7%；Stage A 也有同类未归因项 LUT −144）。
⚠️ **但我无法证明**：Build 1 的 post-synth 归档不存在（§9-2），**"这 142 FF 是重构噪声还是结构性新增"不可判**。**不得**写成"新逻辑 0 FF"。

## 7. 位流

| 项 | 值 |
|---|---|
| 路径 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit` |
| **sha256** | **`1ccbd9cd84292d1a10973a1442f71ca2187e66834be5e09d7eeb22b42c6cdd07`** |
| 字节数 / 时间 | **15,431,261 B** / 2026-10-07 13:23:32 |
| 板级 | ⛔ **未烧**（本轮纪律）；板上现役仍是 Build 1 `b9f16c75…d804` |
| 基线备份 | `_proj_10g/notes/p7b_build_stageB/` 无位流备份（构建前未抢救 Build 1 位流）⚠️ 见 §9-1 |

## 8. 修订漂移检查（构建前 → 构建后）

| 文件 | 构建前 sha256 | 构建后 sha256 | 判 |
|---|---|---|---|
| `rtl/app_pattern.v` | `da7a2c7c6876000b5b7c2e378a8862460803133c04deefdee33f6de035a499e1` | `da7a2c7c6876000b5b7c2e378a8862460803133c04deefdee33f6de035a499e1` | **无漂移** ✓（= 简报预期值 `da7a2c7c…`） |
| HEAD | `e9a4d232a406f3add24350b39d22f8c2840db690` | 同 | **无漂移** ✓ |

⇒ **本轮读数有效（整轮不作废）**。未提交 git；未改 `rtl/` 任何文件（构建期间两次脏区扫描只看到 `M board/p7b_ku5p_stdout.txt`（本构建自己写的）与 `M sim/p4sim/matrix_p4dfix.log`（另一支 agent 的））。

## 9. 没能证明的部分（如实登记）

1. **板上行为一律未测**：本轮不烧板 ⇒ 位流只证"能出、时序收口"，**不证** RX 8 路在板上逐字节正确、不证 `ΔW53/ΔW54` 读数、不证 187 拍/段落位。
2. ⛔ **基线（Build 1）的 routed `-max_paths 10` 报告已被删除、未能抢救**：`create_project -force` 在本构建**开工时**就删掉了 `impl_1/`（我 12:59:00 查时该目录已不存在）。
   ⇒ 我能抢救的只有 `board/p7b_ku5p_*.rpt` 一族（`report_timing_summary` **默认 max_paths**，每时钟对仅 1 条）+ Stage A 报告 §5 的**手写**前 10 表。
   ⇒ **"Build 1 的 DP 前 10" 只能引 Stage A 的文字表**（§4 右列），**不是**我读的原始件；且 **Build 1 的 post-synth 读数、routed dcp 全部不存在** ⇒ §4-4 的 `stg_reg` 归因、§6 的 FF +142 归因**都因此不可判**。
3. **抢救的 `stdout` 命名已订正**：我在 12:59 的抢救里把 `board/p7b_ku5p_stdout.txt` 也复制了一份，但该文件在 **12:59:10 已被本构建的 `>` 重定向截断** ⇒ 复制到的是**新构建的残片**。已改名为 `PARTIAL_stageB_stdout_at_1259.txt` 并在 §附件说明；基线门的对照改用 **Stage A / WU 的 `gatecheck_out.txt` 归档**（两者除一行信息性 `Synth 8-` 计数外**逐字相同**）。
4. **+142 FF 未归因**（§6）—— 只证"与 diff 结构不符 + 与 PW 端点增量自洽"，**未证**其来源。
5. **LUT +320 的构成未逐条证明**（推断 = `xs_next8`/`xs_word8` 两张 XOR 网 − 被 F7/F8 mux 吸收的部分；F7 Muxes −149 与 "+320 而非 +640" 相容，但**未逐锥核对**）。
6. **33 条栏 B 命中的口径裁定不在我**：我判"厂商 IP 固有 + 与基线逐数相同 ⇒ 非本轮引入"，但"任一侧命中即 FAIL"的严格口径会让**基线也 FAIL**（§2）。
7. **`P7B_WNS = 0.006` 与"离违例有多近"是两件事**：本流程 P&R 重排幅度 **±0.4–1.3 ns**（WU 轮既定结论）**远大于** 0.006 ns 余量 ⇒ **同输入重跑完全可能变负**（⛔ **2026-10-09 位级订正：此推理已作废** —— 实测 = **同输入重跑位级复现、方差 0**（R0/R1 `cmp -l` 只差 5 字节 `.bit` 头时间戳；C1 vs r6-fix 归档 6 字节头差 + `SW_CRC=da663843` 逐字相同）；±0.4–1.3 ns 那个幅度测于**两个不同网表之间**（BIZ 基线 ↔ WU 构建）、17 条样本**全落 pcs64/PCIe-GT/pipe_clk 域、非 DP 域** ⇒ 下句"只对这一次布局成立"同样作废；**保留结论 = 0.006 ns 对任何改动都太薄 ⇒ 一次构建收口**；详见 `P7B_WU_TIMING_DELTA.md` §8 + `p7b_build_longflow/INDEX.txt`）。本轮 **0 失败端点只对"这一次布局"成立**，**不构成"这个设计有 0.006 ns 余量"的稳健结论**。
8. **未验证 `xs_word8`/`xs_next8` 与逐字节路径的等价性**（那是仿真/回归轮的判据，`P7B_STAGEB_RX8_REGRESSION.md` 归另一支）；本轮只证**时序与资源**。

## 附：本轮产出物清单（都在 `_proj_10g/notes/p7b_build_stageB/`）

| 文件 | 内容 |
|---|---|
| `bat_stdout.txt` | bat 全程 tee（START/END + BUILD_EXIT + 读数行 + BITSTREAM-OK） |
| `stageB_p7b_ku5p_{stdout,timing,util,drc}.rpt` | 本构建的原始报告副本 |
| `BASE_p7b_ku5p_{timing,util,drc,clkinteract}.rpt` | **构建前抢救**的 Build 1 基线报告 |
| `BASE_gatecheck_{stageA,wu}_out.txt` | 基线两栏门原始输出（两者除一行信息性计数外逐字相同） |
| `gatecheck_out.txt` | 本构建两栏门原始输出 |
| `PARTIAL_stageB_stdout_at_1259.txt` | ⚠️ 抢救时已被截断的 stdout 残片（仅作留档，非基线） |
| `newcone_query.tcl` / `run_newcone_query.bat` / `newcone_query_out.txt` | 新锥族扫描 + DP 前 40 独立复核 |
| `detail_query.tcl` / `run_detail_query.bat` / `detail_query_out.txt` | 新锥最深路径的 delay/logic/route 细分 |

## 附：逐字原句留档（防下游转抄走样）

- 时序总表（`board/p7b_ku5p_timing.rpt:156`）：`0.006 0.000 0 242843 0.008 0.000 0 242843 0.000 0.000 0 79109`
- 判定行（`:159`）：`All user specified timing constraints are met.`
- DP 段头（`:221`）：`g_hw.clk_out0 … 0.006 0.000 0 135660 0.010 0.000 0 135660 2.627 0.000 0 47998`
- 全局最差首行（`:1989-1998`）：`Slack (MET) : 0.006ns` / `Source: u_app_udp/u_txf/dout_reg[70]/C` / `Destination: u_udp_tx/ip_csum_r_reg[1][9]/D` / `Logic Levels: 20`
- 新锥最深（`detail_query_out.txt`）：`slack=2.083 LL=11 delay=4.202 logic=1.230 route=2.972 src=u_app/rx_lfsr_reg[20]/C`
