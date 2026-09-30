# P6B_REVIEW — 对抗审查发现清单

> 审查对象: `P6B_SPEC.md`(1325 行) + `rtl/fifo_async.v` + `rtl/clk_gen_p6b.v` + 两个 TB。
> 审查 agent: 与施工 agent 并行工作；**本文件与 `review_scratch/` 是本 agent 唯一写过的路径**
> （未修改 `P6B_SPEC.md` / `rtl/` / `tb/` / `board/` / `_proj_pcie/` 下任何既有文件）。
> 全部结论附独立证据（代码行 / 我自己的 xsim 输出 / 我重算的数字）。**未验证项在 §6 逐条列。**
> ⚠️ 审查期间施工 agent 正在改动 `board/wrapper_p4.v` / `rtl/*.v`；凡引用"现状"的行号均已实测读出。
> 凡"预测"（如 Vivado DRC）均已标注**未实测**。
>
> ⚠️⚠️ **时间戳与自我更正（必读）**：我的审查与施工 agent 的施工**重叠进行**。
> 落笔前后我**撤回了 2 条自己的误判**（都在下面逐条留痕，不做静默删除）：
> · **F2 撤回** —— 我一度判 `sys_clk_p/n` 端口"无条件声明"，实测它在 `ifdef PCIE_OBS` 内（`:175-177`）。
> · **F3 大幅降级** —— 我判"全链门没定义 `P6B_SIM_CLKGEN` 且 TB 不驱动 `sys_clk`"，
>   到落笔时**已被施工 agent 修好**（`run_tb_p6e_pcie.bat` 已加 `-d`，TB 已加 `sys_clk_p/n`）。
> ⇒ **凡与"当前文件内容"绑定的结论都有时效性**；施工 agent 若已改过，以实际文件为准。
> 我保留 `review_scratch/` 的全部原始日志，可逐条复核。

---

## 0. 汇总（按严重度）

| # | 严重度 | 一句话 | 证据 |
|---|---|---|---|
| **F1** | 🟠 **中（潜伏设计债）** | P6b 的 8 个时间常数被 `ifdef PCIE_OBS` 守卫 —— **一个语义完全无关的宏**。`PCIE_OBS` 现在同时表示"例化 PCIe 观测通道"**和**"数据面跑在 156.25MHz"。当前树里没有构建会踩（`build_p6e` 已被施工 agent 显式声明为"被 P6b 取代"并**同步补齐**了 3 个新 RTL + 2 个新 XDC），**但规格书全文从未提 `PCIE_OBS`** ⇒ 下次有人要"有 PCIe 窗口但数据面仍 125MHz"时会拿到 8 个错的时间常数，且**无任何告警**（UART 变 7680 波特、RTO 变 125ms、FIN 超时变 500ms） | `board/build_p6e_ku5p.tcl:1-6`(施工 agent 自述)、`:110`；`board/build_p6a_ku5p.tcl:65`（**无** PCIE_OBS ✓）；`rtl/tcp_tx_frame.v:165-169`；`rtl/slow_rx_adp.v:22-26`；`rtl/app_status_uart.v:50-56`；`rtl/app_ctrl.v:218-222`；`board/uart_dbg.v:141-145,199-205`；`board/wrapper_p4.v:295-320` |
| ~~F2~~ | ⚪ **撤回（我读错，此处是我方错误）** | 我曾判"`sys_clk_p/n` 端口无条件声明 ⇒ 打破基线端口表"。**实测证伪**：`board/wrapper_p4.v:175` 的 `ifdef PCIE_OBS` 在 `:177` 后 `endif` 收口 —— 端口**正确地**包在 `ifdef PCIE_OBS` 内，注释还逐字写了理由（与 P6B_SPEC §B2 一致）。P6a/P5/P6_t8p0/P6_t6p4 的端口表**未变** | `board/wrapper_p4.v:172-178`（`ifdef`/`endif` 包住）；`:165-177` 全文件 `sys_clk` 只在 `ifdef` 内 |
| **F3** | 🟡 **中（施工 agent 已在审查期间修好大半，剩一条残留）** | 我审查到一半时全链门确实是"定义了 `PCIE_OBS`、没定义 `P6B_SIM_CLKGEN`、TB 不驱动 `sys_clk_p/n`"⇒ 会例化**真 MMCM** 且永不失锁 ⇒ DP 域钉在复位、门读到全 0。**到 09:4x 实测已被修**：`run_tb_p6e_pcie.bat` 已加 `-d P6B_SIM_CLKGEN`，TB 已加 `reg sys_clk_p/n` + `always #5` 并接到 `u_dut`。**残留 3 条**：① `sim/p6e_pcie/files.f` **仍缺** `clk_gen_p6b.v`/`fifo_async.v`/`snap_seq.v` ⇒ 门现在会在 **xelab** 报 module not found；② 规格书 R7 提的宏名是 `P6B_SIM_DPCLK`，实现叫 `P6B_SIM_CLKGEN` —— **照规格书施工会加错宏**；③ TB 把 `sys_clk_p/n` 驱动成**同相**（两个 `#5` 同时翻转），行为级旁路下无害，但**真 IBUFDS 需要反相** ⇒ 谁把旁路关掉就会得到"没有时钟" | `sim/p6e_pcie/run_tb_p6e_pcie.bat:19`（`git diff` 实测已改）；`sim/p6e_pcie/tb_p6e_pcie_wrapper.v:62,67-68,92-93`；`sim/p6e_pcie/files.f`（209 行，grep 三个新文件 = 0 命中）；`board/wrapper_p4.v:296-302`；`P6B_SPEC.md:1202` |
| **F4** | 🔴 **高** | **两个独立缺陷，都被我自己的 xsim 复现**：<br>**(a) 恒等式不是结构性的**：`mac_rx_64` 的丢帧分支在**已 push 过字之后**才丢 ⇒ 流里留下**孤儿字**（有 `popc`、无 TLAST）⇒ `W31` 永久多算。实测：一次帧中丢帧使 `W1−W31 = −64`。<br>**(b) ⭐ 更严重：帧尾那一拍会让 `stat_frames`/`stat_bytes` 谎报成功，而 TLAST 字被 `fifo_sync` 静默丢弃**。机制已逐拍钉死（§3.4）：帧尾决策 `:142` 读到 `full=0`（FIFO 7/8，**读得对**）⇒ push 成立、计数器 +1；但**同一拍**完成字的那次 push 把 `wptr` 推到满，于是**下一拍**`fifo_sync` 的 `wr && !full` 判假 ⇒ 写被丢（`fifo_sync` 无溢出保护）⇒ 该帧的 **TLAST 字永久丢失**，而 `W0`/`W1` 已算它成功。实测 `W0−W30 = −1`、`W1−W31 = −12`（76 − 64，**逐字节对得上**）。此缺陷**与 P6b 无关（P6b 前就有）**，但**C1 判据会把它报成"CDC 完整性故障"** | `rtl/mac_rx_64.v:142-155`（帧尾 push）+ `:180-194`（完成字 push）；`rtl/fifo_sync.v:26`（`full` 组合）+ `:40`（`wr && !full` 才写）+ `:47`（指针）—— **无溢出保护**；`board/wrapper_p4.v:422`（`rxsrc_tready = ~rx_fifo_full`）；xsim 原始输出见 §3.4 |
| **F5** | 🟠 中高 | 规格书 §7.2 的两张索引表 `FE_IDX`/`DP_IDX` **与它自己那张 32 行对照表互相矛盾**（`FE_IDX` 把 `fe[8]/fe[9]` 写在下标 24/25；`DP_IDX` 在 W26..W31 上整体**错位两个槽**）。施工 agent **已按对照表纠正**（`rtl/snap_seq.v:43-48,78-109`），但 §7.4 ⑦ 仍然指示"必须与 §7.2 的两张表逐项一致" ⇒ 照规格书重实现会**重新引入**静默串位 | `P6B_SPEC.md:912-919` vs `:923-935` vs `:879-880`；`rtl/snap_seq.v:43-48` |
| **F6** | 🟠 中 | `WIDTH(77)` 是规格书的**算术错**（64+8+1+1+1+1 = **76**，不是 77）。已原样落进 `board/wrapper_p4.v:405,412`（76 位 `din`/`dout` 接 77 位端口的 `[76]`）。功能上良性（Verilog 补零），但注释与实际分叉，且会诱导后人"补一个字段" | `P6B_SPEC.md:61,445,572`；`board/wrapper_p4.v:405-412`；`rtl/mac_rx_64.v:227`（`FW=76`） |
| **F7** | 🟠 中 | §7.7 的"÷64 → ÷80"逐处清单**漏了 5 处**，其中 2 处是**活算式**（会打印错误的复位次数）：`p6e_snap_check.sh:143`、`p6b_accept.sh:278`；另有 `p6e_boot_timeline.sh:18`、`README.md` 的「已建成的能力 · 慢路径」与「已建成的能力 · 板级诊断接口」两节（README 2026-09-30 结构性重写**前**为 `README.md:69,155`） | 见 §4 表 |
| **F8** | 🟡 中低 | §5.1 的"必须改"清单**漏了 `rtl/app_ctrl.v` 的两处注释块**（`:79-80` 的 "1 计数 = 256 拍 = 2.048us @125MHz"、`:128` 的 "4 轮 = 1024 拍"）⇒ 触发本工程"文档与 RTL 分叉 = 硬失败" | `rtl/app_ctrl.v:79-80,128` |
| **F9** | 🟡 中低 | 跨文档冲突：`p6b_accept.sh:76` 说"未实现地址必须挪到 **0x88**"，规格书 §7.4 ⑤ 说 **0xA0**。且 `p6e_snap_check.sh` 的 **活判据**在 `:165`（`U84=$(rd 0x84)`），规格书只点了 `:161`（注释） | `_proj_pcie/p6b_accept.sh:76`；`_proj_pcie/p6e_snap_check.sh:161,165`；`P6B_SPEC.md:978,1017` |
| **F10** | 🟡 中低 | **链式触发偏斜上界 59.2 ns 是两个错误相互抵消的产物**。正确值 ≈**43.2 ns**（含 2 个被漏算的 axi 拍），且 `∈{0,1}` 的真实依据比规格书更强（帧尾间距 ≥672 ns，不是 IFG 96 ns）。**结论不倒，但数字不能用** | §3.2 |
| **F11** | 🟡 中低 | `W20 − W7 ∈ {0,1}` 只在 **`W21 == 0` 的条件下**成立：`mac_tx` 帧内中止后回到 `S_IDLE`，会把**中止帧的剩余字当成一帧新的重发**并 `stat_frames++` ⇒ 一次 abort 会让 W20 多计若干"帧"。规格书 §9.3 把它写成结构性判据 | `rtl/mac_tx_64.v:148-152` + `:106-128` + `:179-186` |
| **F12** | ⚪ 记录 | MMCM VCO 1250 MHz **合法**（ds922 Table 38: `MMCM_FVCOMIN=800 / FVCOMAX=1600`，xcku5p 全速度档同值）—— 规格书 §A1 的"两者都合法"**实测证实** | ds922 p.36（本 agent 用 pymupdf 提取） |
| **F13** | ⚪ 记录 | 实现用 `dbg_occ_w` 出 W28，规格书 §7.1/§7.2 说"需要 `dbg_occ_r`"。**实现的偏离是对的**（`dbg_occ_r` 属 gmii 域，塞进 DP 束就是多比特 CDC）。但规格书 §7.2 的注释"两个值…天然保守 **≤** 真实占用"**对 `dbg_occ_w` 是错的**（它是**上界**） | `rtl/fifo_async.v:122-123`（探针端口）+ `:240-256`（`gray2bin` + 两条 `assign`）；`board/wrapper_p4.v:2152,2699` |

---

## 1. 施工状态快照（审查期间实测）

| 文件 | 状态 |
|---|---|
| `rtl/clk_gen_p6b.v` / `rtl/fifo_async.v` / `rtl/snap_seq.v` | 已落地 |
| `board/wrapper_p4.v` | **已被大幅改造**：`u_rxcdc`/`u_txcdc` 已例化（`:412,2187`）、`clk_gen_p6b` 已例化（`:304`）、W24..W31 已在（`:2589-2699`）、§5.1 常数已改、`sys_clk_p/n` 端口**已正确包在 `ifdef PCIE_OBS` 内**（`:175-177`） |
| `rtl/tcp_tx_frame.v` / `slow_rx_adp.v` / `app_status_uart.v` / `app_ctrl.v` / `board/uart_dbg.v` | 已改，**全部包在 `ifdef PCIE_OBS` 里**（→ F1） |
| `board/build_p6b_ku5p.tcl` | 已建（`verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1}`，已 import 三个新文件 + 两个新 XDC） |
| `board/build_p6e_ku5p.tcl` | **已被施工 agent 改动**：文件头声明"已被 P6b 取代"，并**同步补齐了**三个新 RTL 与 `ku5p_p6b_sysclk.xdc`/`ku5p_p6b_cdc.xdc` ⇒ P6e 档现在也**是**双域构建（→ F1 因此降级） |
| `sim/p6e_pcie/files.f` | **尚未**加入 `clk_gen_p6b.v`/`fifo_async.v`/`snap_seq.v`（209 行，实测无这三个文件） |
| `_proj_pcie/p6b_accept.sh` | 已落地（`EXPECT_BUILD_ID=TODO`；`ADDR_DP_FREE=0x80`/`ADDR_MMCM=0x84`） |

---

## 2. 逐条承重结论（S1–S7）

### S1 —— 「W4/W20/W21 在数据面域结构性不可复算」：**有条件同意（结论成立，理由有三处错）**

**独立核实**（`rtl/mac_rx_64.v` / `mac_tx_64.v`）：

**(a) W4 `rx_stat_drop` —— 结论成立，但规格书给的理由是错的。**
四个自增点逐条读：
- `:158`（帧尾 `hwv && fifo_full`）、`:184`（帧中 `hwv && fifo_full`）、`:206`（`S_FLUSH` 满）
  —— 三者都在**该帧已经 push 过字之后**才丢（`:184` 要求 `hwv==1`，而 `hwv` 置位发生在第 1 个整字完成时，
  此时若已有旧保持字就会被 push；`:206` 只在 `:143` 那次 push 之后才可能到达）。
- `:161`（`bcnt==0`，零净荷帧）—— **只有这一条**真的"一个字节都没进 FIFO"。

⇒ 规格书 §2.4(a) 的"**帧的字节一个都没进 FIFO**"只对 `:161` 成立；对另外三条**可证伪**（见 §3.4 的实测）。

**但这不推翻结论**：DP 侧虽然能看到"孤儿字"，却**无法把这些字归因到帧**（孤儿字与下一帧的字在流里是连续的，
SOP 只标记帧首，无法区分"孤儿 run"与"正常帧的字"）。所以 W4 仍需 FE 侧计数器。
**可用的部分交叉检查**（规格书完全没提）：DP 侧可以数 `SOP 数 − TLAST 数`，
它精确等于"**至少 push 过一个字的丢帧数**"（每帧恰好 1 SOP / 1 TLAST；被中途丢的帧只有 SOP）。
这能把 W4 拆成两半，是白捡的独立证据。

**(b) W21 `tx_stat_abort` —— 同意。** 它是 `mac_tx_64` 内部 16 深 FIFO 的"输入断供"（`:148-152`），
DP 侧没有任何回读通路（`mac_tx_64` 的端口表 `:9-22` 只有输入侧 `s_axis_tready`，输出侧无 ready）。
"16 字 = 128 拍缓冲吸收掉 DP 短停顿而不中止"的论证成立 ⇒ **中止门槛在 DP 侧观测不到。**

**(c) W20 `mac_tx_frames` —— 同意"不可分开"，但"W20 = W21 的补集"这句是错的。**
`stat_abort` 后 `state <= S_IDLE`（`:150`），而该帧**剩余的字仍在 `u_txcdc` 里**，
`S_IDLE` 一看到 `!fempty` 就重新 `S_PRE → S_DATA`（`:106-128`），把这些残字当成**一帧新的**发完 ⇒
`S_FCS → S_IFG → stat_frames++`（`:171-186`）。
⇒ `W20 = (MAC 启动过的帧数) − W21`，而"启动过"包含 abort 的尾巴 ⇒ **一次 abort 会让 W20 多计若干帧**。
（推论见 **F11**：`W20−W7 ∈ {0,1}` 只在 `W21==0` 前提下成立。）

**(d) 否决方案 (i) 的结论 —— 同意**，但 §2.4 的第 4 条理由（"引入定义漂移"）与我上面 (a) 的发现叠加后更强：
即使把 W0/W1/W3 复算过去，`W1` 也从"Σfbytes"变成了"Σpopc(去孤儿)+4×帧"，
**两个定义的差值正是孤儿字节数** ⇒ 两条线会永久分叉。

### S2 —— 「链式触发偏斜上界 ≤59.2 ns」：**推翻数字，同意结论**

见 §3.2 的完整重推：**正确上界 ≈ 43.2 ns**（FE 锁存 → DP 锁存）。
规格书的 4 行表里，第 1 行（`req → FE 锁存` 24 ns）在 **FE 锁存之前**，不进入两个锁存之间的偏斜；
而剩下的 axi 段**漏算了 2 拍**（`valid_a` 的寄存拍 + `snap_cdc#DP` 的 `toggle_a` 寄存拍 = 8 ns）。
+24 与 −8 恰好抵消成 −16 ⇒ 59.2 − 24 = 35.2，35.2 + 8 = 43.2。**两个错误互相掩盖。**

**结论不倒**（43.2 ns 与 59.2 ns 都 < 96 ns），而且规格书用来支撑 `∈{0,1}` 的"96 ns 最小 IFG"**偏保守得离谱**：
两个计数器都在**帧尾**自增，而 1G 上两个帧尾的最小间距 = IFG(12B) + 前导(8B) + 最小帧(64B) = **84 B = 672 ns**。
⇒ `∈{0,1}` 的真实理由是 **672 ns 的稀疏事件间隔**，不是 96 ns 的偏斜上界。
（前瞻：10G 下 84 B = 67.2 ns，43.2 ns 的偏斜就只剩 1.55× 余量 —— 值得在 P6 收口时重新审视。）

### S3 —— 「W0/W1/W3 精确可复算」的三条恒等式：**推翻（在丢帧边界上不成立）**

独立复现见 **§3.4**（我自己的 xsim，正/负对照俱全）。结论：

| 恒等式 | 无丢帧时 | 有丢帧时 |
|---|---|---|
| `Σpopc(tkeep) + 4×帧数 ≡ stat_bytes`（= `W31 == W1`） | ✅ 逐位相等（F1/F4 对照实测 gap=0） | ❌ **被孤儿字破坏**（F2 实测 gap=−64） |
| `stat_frames ≡ 推进 FIFO 的帧数`（= `W30 == W0`） | ✅ | ❌ **可被破坏**（F3 实测 `dW0=+1` 而 `dW30=0`） |
| `Σpopc(tkeep) ≡ 内容字节数`（单帧内） | ✅ 逐帧成立（打包 4 字节前瞻 + `ljust` 的代数我逐行核过） | — |

⇒ **规格书 §7.3 把 C1 写成"停机态下的精确等式"是假的**：停机态只保证 FIFO 空，
**不擦除已经流过去的孤儿字**。第一次板级"深度不够 ⇒ 丢帧"就会让 C1 永久 FAIL，
而且**无法区分"C1 FAIL 是 CDC 坏了"还是"C1 FAIL 是丢了一帧"** —— 这正是判据最需要区分能力的地方。
维修建议见 §5-R4；**另一条更要紧的发现见 F4(b)**：帧尾那一拍会让 `stat_frames`/`stat_bytes`
**谎报成功**而 TLAST 字被 `fifo_sync` 静默丢弃（机制已逐拍钉死，见 §3.4）——
这条即使没有 CDC 问题也会独立破坏 `W0==W30`/`W1==W31`，且**现有任何门里都没有能抓它的断言**。

### S4 —— 「DEPTH=256 够不够 / W26/W27/W28 是不是安慰剂」：**部分同意**

- **深度推导本身同意**：`256 ≥ 190`（一个 1518B 最大帧的字数）是"整帧进得来"的硬下界，
  `u_tx_arb` 一次只放一帧（`rtl/tx_arb.v:38-52` 的 `busy` 锁到 TLAST）确实要求 FIFO 容得下整帧 ✓。
  "最深停顿无上界"（`rtl/tcp_rx.v:25` 的 64KB 共享 frame_fifo）也确实是事实 ✓。
- **W26 不是深度表，是"写者被挡"表**：`full` 由**同步过来的**读指针判定（`rtl/fifo_async.v:169`），
  读时钟慢时 `full` 会提前 2–3 个 rd 沿拉高 ⇒ **W26 涨只证明"写者被挡过"，不证明"真的满过"**。
  规格书自己说的是"W26 单调上涨 ⇒ 确认是新 FIFO 造成的" ✓ 用法对，但别当深度读数。
- **W27/W28 有方向性缺陷（规格书说反了）**：
  `assign dbg_occ_w = wbin_r − gray2bin(rgray_s2_w)` 用的是**滞后的**读指针 ⇒ **上界**；
  `assign dbg_occ_r = gray2bin(wgray_s2_r) − rbin_r` 用的是**滞后的**写指针 ⇒ **下界**。
  规格书 §7.2 说"两个值…天然保守 **≤** 真实占用"——对 `dbg_occ_w` 是**反的**。
  ⇒ 判据含义因此不对称：`W27/W28 == 256` 是**充分**的"深度不够"证据（不会漏报），
  但 `W27 = 250` **不能**证明"真的到过 250"（最多高报 ~4 字：8ns 读钟 vs 6.4ns 写钟，rptr 同步滞后 2–3 个 gmii 沿）。
  施工 agent 给 W27/W28 **都**取写域值（`board/wrapper_p4.v:2673,2699`）—— **这个选择比规格书好**
  （读域值属 gmii 域，塞进 DP 束需要多比特 CDC）⇒ **F13**，规格书 §7.1 需改。
- **所以：W26/W27/W28 不是安慰剂**，但只有 `W27/W28` 是深度读数，且只有"贴 256"这一侧有判别力。

### S5 —— 「HLS ×0.8 漂移会不会打破验收判据」：**有条件同意（对 ping/图案成立）**

逐条自查（不是"读了它写得很清楚于是同意"）：

| 项 | 我的独立核算 | 结论 |
|---|---|---|
| `WDOG` 补偿 = `22'd2621440` | 2²¹×8 ns = 16.777 ms；2621440×6.4 ns = **16.777 ms** —— **逐位精确相等** | ✅ 规格书的"给 HLS 同样的 16.8ms"**成立** |
| `rst_cnt` 64→80 + W17 ÷64→÷80 | 64×8 = 512 ns = 80×6.4 ✓ | ✅ |
| ping 是否碰计时器 | `hls/src/layer_icmp.cpp:173` 的应答 dst MAC 来自 `arp_lookup()`；而 ARP 表的 `l1_age` 是**访问驱动的 LRU**（`layer_arp.cpp:32-42`，只在 `l1_lru_touch` 里变），**不含时间老化** ⇒ ×0.8 不影响它 | ✅ 规格书结论成立 |
| pass 计数计时器是否门住 ICMP 应答 | 全 HLS 里的 pass 计数计时器只有 `layer_stats.cpp:27`（状态上报节流 0.8→0.64s）、`layer_udp.cpp:126`（HELLO 周期 5→4s）、以及 `layer_tcp.cpp` 的**主动建连**路径（`ACTIVE_DELAY`/`ACTIVE_ARP_INTERVAL`）。**没有一条门住 ICMP 应答** | ✅ |
| 图案/吞吐 | UDP 8081 走 `u_app_udp`，**完全不进 HLS** | ✅ |
| 副作用（规格书未点） | **HELLO 帧周期 5s→4s ⇒ 线上多 25% 的慢路径帧。** 对 931 Mbps 图案测试无影响；但在**"停流量 → 等 ≥13µs"**（C1）窗口里若恰好撞上一帧 HELLO，那 13µs 不够 —— 建议 C1 的等待改成 **≥ 100 µs** 或显式等到 `ΔW0 == 0` 连续 N 次 | ⚠️ **需补一句** |
| §5.3 表的数据来源 | 规格书引的是 `hls/src/*.h/*.cpp`。这些源里 `TCP_RTO_MIN`/`ACTIVE_DELAY`/`ACTIVE_ARP_INTERVAL`/`TX_PACING_COUNT` **全部带 `#ifndef/#ifdef` 覆盖**（例：`eth_types.h:176-180` 的 `TX_PACING_COUNT` 在 `__SYNTHESIS__` 下是 625e6、否则 0x100）。**板上跑的是生成 RTL**，规格书没写它核过生成 RTL 的常数 | ⚠️ 建议补一条"以 `hls/slowstack_prj/solution1/syn/verilog/` 为准"的核对 |

⇒ **验收判据不会被打破**（前提：C1 的等待窗口加长）。但 §5.3 的"只记录不改"是对的，**要记录得更准**。

### S6 —— `rtl/fifo_async.v` + `rtl/clk_gen_p6b.v` 的代码审查：**有条件同意（未发现承重缺陷）**

逐条查过（lint 看不见的那几类）：

| 检查项 | 结论 | 证据 |
|---|---|---|
| 位宽截断 | `{{AW{1'b0}}, wr_ok}` = AW+1 位 ✓；`{~rgray_s2_w[AW:AW-1], rgray_s2_w[AW-2:0]}` = 2+(AW−1) = AW+1 ✓（**要求 AW≥2** ⇒ DEPTH≥4 是硬下界，模块头注释已写明并有 `initial` 自检）| `rtl/fifo_async.v:165-169`（`wr_ok`/`wbin_n`/`full_n`）+ `:185,211`（`assign empty`）+ `:126-134`（参数自检） |
| 灰码性质 | `bin2gray = b^(b>>1)` ✓；`full` 用 `wgray_n`（含本拍待写）✓ —— 这条**是**正确的保守方向，`mut_full_off` 负对照专测它 | `rtl/fifo_async.v:166-169` |
| ASYNC_REG 落点 | 两条读/写域灰码同步链（各 2 级，整宽寄存器 `:160-161`）+ 两条复位同步器（`:140,147`）上都打了 ✓；`snap_cdc` 的 3 级链（`rtl/snap_cdc.v:84,108`）也打了 ✓ | `rtl/fifo_async.v:140,147,160,161`；`rtl/snap_cdc.v:84,108` |
| 满/空契约 | 单时钟域的经典 Cummings 结构；`empty_r` 复位值 = 1（**不能是 0**）✓（`:200`）；`mem` 无复位（LUTRAM/BRAM 推断前提）✓（`:216-219`）；`full==1` 时的 `wr_en` 被静默忽略（`wr_ok` 门 `:165`）✓ 与头注释一致 | `rtl/fifo_async.v:165-190`（写域）+ `:193-211`（读域）+ `:216-219` |
| **复位跨域（硬契约②）** | 每域一条"异步置位/同步释放"（`:140-152`），域内所有寄存器（含灰码同步链）都用**本域同步释放后**的复位 ⇒ 释放沿不落在时钟沿附近 ✓。**但调用方必须给两侧同一代复位** —— 实现里 `wr_rst_n`/`rd_rst_n` **都接 `reset_n`** ✓（`board/wrapper_p4.v:414-415` 的接线实测一致），`rst_dp` 未进 FIFO 复位路径 ✓ | `rtl/fifo_async.v:140-152,42-57`（头注释契约）；`board/wrapper_p4.v:289-293,413-420` |
| MMCM 参数合法性 | `CLKFBOUT_MULT_F=12.500`（2.000–64.000 且 0.125 步长 ✓）、`DIVCLK_DIVIDE=1` ✓、`CLKOUT0_DIVIDE_F=8.000` ✓、`BANDWIDTH="OPTIMIZED"` ✓、`PWRDWN=0/RST=0` ✓。**VCO 1250 MHz 合法**（ds922 Table 38: `MMCM_FVCOMIN=800`、`MMCM_FVCOMAX=1600`，xcku5p 全档同值）| `rtl/clk_gen_p6b.v:164-183`；ds922 p.36 |
| `locked` 的用法 | `rst_async = (~locked) | rst_ext` 异步置位、`rel_sr` 4 拍**同步**释放 ⇒ `rst_dp` 的两个跳变都对齐 `clk_dp` ✓，下游用 `posedge rst_dp` 无 recovery/removal 风险 ✓。规格书 §6.2 的四条理由逐条对照**成立** | `rtl/clk_gen_p6b.v:199-208` |
| `clk_in_100` 的行为级模型 | `assign clk_in_100 = clk_p;` —— 仿真下是**裸单端引脚**（真路径是 IBUFDS+BUFG）。**仅仿真**，但若将来有人拿它当"100MHz 干净时钟"用会踩 | `:126` |
| 行为级 lock 模型 | `quiet` 由 `posedge clk_p` 清、由 `posedge clk_dp_byp` 增 ⇒ clk_p 停 >16 个 dp 周期后 `lock_byp=0` ✓ 与注释一致；`lock_byp <= (quiet < 16)` 用旧值（非阻塞）滞后 1 拍，无副作用 | `:130-137` |
| 备用路线 | `CLKIN1_PERIOD_NS=8.000/MULT=10.000` 与主线**共用 VCO 1250 MHz** ✓ 算术正确（`HALF_DP_PS = 8000*1*8000/(2*10000) = 3200` ✓）| `:99-107,24-26` |

**唯一实质提醒**：`rel_sr` 的 `rst_async` 是**组合**函数（`~locked | rst_ext`），它的**撤销**相对 `clk_dp` 是异步的
⇒ `rel_sr[0..3]` 的 CLR 引脚会跑 recovery/removal 检查。这是复位同步器的固有代价（只有第一级真正暴露），
Xilinx 标准做法接受它；但 **`rst_ext`（= `~reset_n`，来自 PERST# 引脚 J9）若没有 `set_false_path`，
这条检查会按理想到达时间算** —— 建议在 `ku5p_p6b_cdc.xdc` 里显式 `set_false_path -from [get_ports reset_n]`（或
`-to` 复位引脚），免得它成为一条假的 setup 违例。

### S7 —— 「两个 TB 真的有区分能力吗」：**同意（做了独立变异，门抓到了）**

我**没有**用作者自带的 3 个变异体（它们可能与判据同源），而是自造两个（只改副本，未动交付件）：

| 我造的变异 | 改法 | `C_BAL` | `C_WRFAST` | `C_BOUND` | `C_RESET` |
|---|---|---|---|---|---|
| **mutC** 满标志只用 1 级同步 | `full_n` 用 `rgray_s1_w` 替 `rgray_s2_w` | **PASS** | **FAIL**（"占用到过 DEPTH" + "内容错"） | PASS | — |
| **mutF** 写侧复位同步器减到 1 级 | `wr_rst_n_s = wr_rst_sync[0]` | **PASS** | — | — | **FAIL**（RESET3/RESET4/6 + 内容错） |

命令（可复跑）：`cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\review_scratch\runmuts.bat'`
（基线 `rd_base_bal` = `FIFO_ASYNC_GATE: PASS_ALL`；变异体产物在 `review_scratch/rd_mutC_*`、`rd_mutF_*`）

⇒ **门不是空的：基线 PASS，我自造的变异体都被至少一个 case 抓死。**
**但**必须记一条方法论警告：**上面每个变异体都只在部分 case 里显形**（mutC 只被 WRFAST 抓、mutF 只被 RESET 抓），
而 `sim/fifoasync/run_mut_*.bat` 三个脚本**各自只跑一个 case** ⇒
"变异体对单个 case 可杀"**不等于**"判据对任意变异体都可杀"。`run_all.bat` 跑全 7 case 才是完整门。

**另一个观察**：判据 9（"二级同步的结构契约延迟 dt>3T"）**只覆盖数据同步链**，不覆盖复位同步链 ——
这正是 mutF 在 BAL 下漏网的原因。

---

## 3. 关键推导与原始读数

### 3.1 MMCM VCO 合法性（ds922 原始提取）

```
py -c "import pymupdf; doc=pymupdf.open('ds922-kintex-ultrascale-plus.pdf'); ..."  # p.36, Table 38
MMCM_FVCOMIN Minimum MMCM VCO frequency   800  800  800  800  800  MHz
MMCM_FVCOMAX Maximum MMCM VCO frequency  1600 1600 1600 1600 1600  MHz
MMCM_FINMIN  Minimum input clock frequency  10 ... MHz
```
⇒ **1250 MHz 在 [800, 1600] 内，全速度档合法**。规格书 §A1 的"两者（1250 与 1562.5）都合法"**证实**。

### 3.2 链式偏斜重推（S2）

从 `rtl/snap_cdc.v` 逐级数**目的域时钟沿**：

```
FE 锁存 (e3)                       ← snap_cdc#FE 的 hold_b 在 update_b 那拍锁存
  ack_b 在 e3 同沿翻转             (:100-106)
  ack_sync_a[0] @c1, [1] @c2, [2] @c3  → done_a 在 c3 之后 (:108-117)
  valid_a 在 c4（`valid_a <= done_a && !done_r`，:126 —— 规格书按 3 拍算，少 1 拍）
  snap_seq 见到 valid_fe 后寄存 req_dp → req_dp 在 c5 之后（§3.2 硬契约①要求 1 拍脉冲）
  snap_cdc#DP 的 toggle_a 在 c6 翻转（:76-79 —— 规格书完全没算这一拍）
  DP 锁存 e3' = c6 + (2~3 个 clk_dp)
```
- `c1 − e3 ∈ (0, 4]` ns；`c6 = c1 + 5×4 = c1 + 20` ⇒ `c6 − e3 ∈ (20, 24]` ns
- `e3' − c6 ∈ (12.8, 19.2]` ns
⇒ **FE 锁存 → DP 锁存 ∈ (32.8, 43.2] ns**

规格书 4 行的和 = 59.2 = 24 + 12 + 4 + 19.2。其中
第 1 行 `req → FE 锁存 24 ns` **在 FE 锁存之前**，不进偏斜；
剩下 35.2 ns 比我的 43.2 ns **少 8 ns = 2 个 axi 拍**（`valid_a` 的寄存 + `snap_cdc#DP` 的 `toggle_a`）。
⇒ **+24 与 −8 抵消**，两个错误互相掩盖。**结论（< 96 ns）不倒**，但 59.2 这个数不能用。

**支撑 `∈{0,1}` 的正确理由更强**：`stat_frames`/TLAST 都在**帧尾**自增，
1G 上两个帧尾的最小间距 = 12 B(IFG) + 8 B(前导) + 64 B(最小帧) = **84 B = 672 ns**（不是 96 ns）。
43.2 ns ≪ 672 ns ⇒ 窗口内**最多 1 次自增**。

### 3.3 索引表逐项核对（F5）

三处必须一致，实测**只有两处一致**：

| 来源 | W24/W25 | W26/W27 | W28..W31 |
|---|---|---|---|
| 两束拼接（`P6B_SPEC.md:879-880`）| DP dp[16]/dp[17] | **FE** fe[9]/fe[8] | DP dp[18..21] |
| 32 行对照表（`P6B_SPEC.md:923-935`）| DP dp[16]/dp[17] | **FE** fe[9]/fe[8] | DP dp[18..21] |
| **§7.2 的 `localparam`（`:912-919`）** | `FE_IDX[24,25] = 8,9` ✗ / `DP_IDX[24,25] = 16,17` ✓ | `FE_IDX[26,27] = -1` ✗ / `DP_IDX[26,27] = 18,19` ✗ | `DP_IDX[28..31] = 20,21,-1,-1` ✗ |

⇒ 照 §7.2 的 `localparam` 施工，W26/W27 会读出 **0**、W28/W29 会读出 **W30/W31 的值**、W30/W31 读出 **0**。
施工 agent 的 `rtl/snap_seq.v:78-109` 用的是 `case` 函数并逐项注释，**与"对照表"逐字一致** ✓（`snap_seq.v:43-48` 还留了变更说明）。
**建议**：把 §7.2 的 `localparam` 字面量改成"以对照表为准"（或直接删掉字面量、只留对照表），否则下次重实现会重新踩。

### 3.4 S3 的独立 xsim 证据（F4）

TB：`review_scratch/rw/tb_rvw_macrx.v`（自写；只读 `rtl/mac_rx_64.v`，未改动它）
驱动：GMII 前导(8×55+D5) + N 个内容字节 + 4 个假 FCS 字节；`m_axis_tready` 按窗口拉低以真正触发
`fifo_full` 丢帧路径；**随后释放 tready**，把已经 push 的字排出去（那正是 W30/W31 会数的东西）。
复跑：`cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\review_scratch\runmac.bat'`

```
F1 (对照, content=200, 不 stall)
   FE W0=1 W1=204 W4=0 | DP W30=1 W31=204 | gap(W1-W31)=0   gap(W0-W30)=0      ← 恒等式成立 ✓

F2 (content=200, tready 在 cyc[30,300) 拉低)
   [drop #1] t=5908000  dut.state=3  stat_drop=1
   FE W0=1 W1=204 W4=1 | DP W30=1 W31=268 | gap(W1-W31)=-64  gap(W0-W30)=0
   DELTA: dW0=0 dW1=0 dW4=1 | dW30=0 dW31=+64
   → 丢帧发生在 :182-184（帧中, bcnt==7 且 hwv 且 full —— 由 5-cycle 逐拍轨迹确认）
   → **8 个孤儿字（64 字节）留在流里**，W31 多算 64；W0/W1 不动
   → 这就是"W1 == W31 不是结构性恒等式"的**直接反例**

F3 (content=72, tready 在 cyc[12,300) 拉低)
   [framecnt] t=10924000 state=0 fbytes=76 bcnt=0 hwv=0 fifo_full=1 wptr=9 rptr=1
   DELTA: dW0=+1 dW1=+76 dW4=0 | dW30=0 dW31=+64
   → FE 记了一帧(76 字节), DP 侧**既没有它的 TLAST、也少 12 字节**
   → gap(W0-W30) = -1, gap(W1-W31) = -12
   → **第二种破坏方式, 且它连 W0==W30 也破坏**

F4 (对照, content=20, 不 stall)   gap 两式均 = 0  ✓

F3 的**逐拍轨迹**（加打 push/push_last/wptr/rptr/full/stat_frames/stat_bytes）:
   t=10908000 st=2 fby=75 bcnt=7 hwv=1 push=0 last=0 full=0 wptr=8 rptr=1 dv=1 sf=1 sb=204
       ↑ 完成第 9 字: hwreg<=word9, push<=1(word8)          ← 经 push=1 在下一拍可见
   t=10916000 st=2 fby=76 bcnt=0 hwv=1 push=1 last=0 full=0 wptr=8 rptr=1 dv=0 sf=1 sb=204
       ↑ 帧尾决策拍: full=0 (真值: 7/8 占用) ⇒ 走 :142
         同拍完成"word8"的写 → wptr 8→9；同拍 :142 执行 push<=1 / push_last<=1 / sf<=2 / sb<=280
   t=10924000 st=0 fby=76 bcnt=0 hwv=0 push=1 last=1 full=1 wptr=9 rptr=1 dv=0 sf=2 sb=280
       ↑ 关键: full=1 (wptr=9,rptr=1 ⇒ 8/8)。`fifo_sync` 的 `wr && !full` **判假**
         ⇒ **word9 (= TLAST) 那一笔写被丢弃**; wptr 不增 (停在 9); 下一拍 push 归零, hwv 已清
         ⇒ **word9 永久丢失**。而 sf/sb 已经在上一拍算它成功了。
   之后: 8 个字 (word1..word8, 全 popc=8 = 64 B) 排空, **没有 TLAST**
   ⇒ 与实测 dW30=0 / dW31=+64 / dW1=+76 逐项吻合 (76 − 64 = 12) ✓
```
⇒ **`W1 == W31` 与 `W0 == W30` 都只是"无丢帧 + FIFO 空"这个条件下的等式，不是结构等式。**
**(b) 是比 (a) 更严重的一类：不是"丢了一帧"（那是设计合同允许的），
而是"计数器说这帧成功了、TLAST 却没了"** —— 下游按 TLAST 完整性丢弃半帧的合同虽然兜住了数据，
但 `W0`/`W1` 从此与事实不符，C1 会把它归因成 CDC 故障。

### 3.5 FIFO 变异测试原始输出（S7）

```
rd_base_bal : FIFO_ASYNC_GATE: PASS_ALL (case=BAL)
rd_mutC_C_BAL    : PASS_ALL      ← 满标志单级同步, BAL 抓不到
rd_mutC_C_WRFAST : FAIL  FAIL-DETAIL: WRFAST: 占用到过 DEPTH
                         FAIL-DETAIL: 通用1: 四实例内容错 0
rd_mutC_C_BOUND  : PASS_ALL
rd_mutF_C_BAL    : PASS_ALL      ← 复位同步器单级, BAL 抓不到
rd_mutF_C_RESET  : FAIL  FAIL-DETAIL: RESET3/RESET4 前置(C)/RESET6/通用1
```

---

## 4. 全仓假设扫描（规格书**漏掉**的条目）

复跑命令与逐条结论（规格书 §7.7/§9.3 已点名的**不重复**；只列漏的）：

| 文件:行 | 假设 | 为什么被 P6b 打破 | 规格书点到了吗 |
|---|---|---|---|
| `_proj_pcie/p6e_snap_check.sh:143` | 打印 `÷64 = 看门狗复位次数`（**活算式**） | `rst_cnt` 64→80 ⇒ 打印出来的"复位次数"少 20% | ❌ **漏**（只点了 `p6e_slowpath_probe.sh`） |
| `_proj_pcie/p6b_accept.sh:278` | `$(( W[17] / 64 ))`（**活算式**，判据 5f 的实测串） | 同上 | ❌ **漏** |
| `_proj_pcie/p6e_boot_timeline.sh:18` | 注释 "W17 … ÷64" | 同上 | ❌ 漏（与 `:23` 同文件，只点了 `:23`） |
| `README.md`「已建成的能力 · 慢路径」（重写前 `:69`） | "看门狗 (饥饿超时 **64 拍**复位脉冲)" | 80 拍 | ❌ **漏**（README 完全不在清单里） |
| `README.md`「已建成的能力 · 板级诊断接口」（重写前 `:155`） | "64 拍 TR/RXT 轨迹环" | 这是**环形缓冲深度**（条目），不是时间 ⇒ **不该改**，但清单没区分，容易被顺手改错 | ❌ 漏（**负向**：应明确"不改"） |
| `P6E_OBS.md:47,105` | `÷64` | 同上 | ⚠️ 部分（§9.3 只说"P6E_OBS 要加注记"） |
| `board/wrapper_p4.v:48` | 注释 "9600-8N1, gmii_clk 125MHz 域, 13021 拍/位" | 域变 dp；13021→16276 | ✅ 点了（§5.2 的警告） |
| `rtl/app_ctrl.v:79-80` | 注释 "16 槽轮一遍 = 256 拍/轮 ⇒ 1 计数 = 2.048us @125MHz"、"FIN_TO_LIM = 195313 ⇔ …400ms" | 数值与换算全变 | ❌ **漏** |
| `rtl/app_ctrl.v:128` | 注释 "再数 FIN_GRACE 轮（4 轮 = 1024 拍）" | FIN_GRACE 4→5 | ❌ **漏** |
| `rtl/mac_rx_64.v` / `mac_tx_64.v` / `tx_arb.v` / `vlan_strip.v` | 它们自己**没有**时钟选择（都是 `input clk`）⇒ 域由 wrapper 决定 | — | ✅ §B5 已自认 |
| `rtl/frame_fifo.v:54-56` | `W=73 D=2048 AW=11`（**默认参数**，不是实例值） | 规格书 §5.2 写的是 `rtl/frame_fifo.v:54-56` = `W=73 D=2048` —— 但 `slow_rx_adp`/`slow_tx_adp` 实例化的是 `D=512 AW=9` | ⚠️ 规格书这条**引错了行**（默认参数 vs 实例参数），结论无影响 |
| `sim/p6e_pcie/run_tb_p6e_pcie.bat:19` / `run_tb_p6e_pcie_counters.bat:26` | 编译宏 = `PCIE_OBS + DEV_USP + APP_MODE`（"MUST match the real build"） | P6b 后这套宏**同时**选时钟域与时间常数 ⇒ 门与板会分叉 | ❌ **漏**（见 F1/F3） |
| `_proj_pcie/p6b_accept.sh:23,260-266` | `W20 == W7` | 规格书 §9.3 已点名要改成区间 | ✅ **点了**（这里只记"脚本未改"） |
| `_proj_pcie/p6b_accept.sh:76` | "未实现地址挪到 **0x88**" | 规格书 §7.4 ⑤ 说 **0xA0**（32 字窗口） | ❌ **漏**（两文档冲突） |
| `board/wrapper_p4.v:175-177` | `sys_clk_p/n` 声明 | **已正确包在 `ifdef PCIE_OBS` 内** ⇒ 基线端口表未变 ✓（我先前判为"无条件"，**已撤回**，见 F2） | — |
| `board/build_p6a_ku5p.tcl:65` vs `build_p6e_ku5p.tcl:110` | 两个档的宏集合差一个 `PCIE_OBS`，而现在 `PCIE_OBS` **同时**决定时钟域与 8 个时间常数 | P6a 恰好**没有** PCIE_OBS ⇒ 未被污染 ✓；但这是**巧合**而非设计（P6e 就是因为"也有 PCIE_OBS"而必须同步补齐 XDC） | ❌ **漏**（规格书从未提这个宏） |
| `board/wrapper_p4.v:411-427` 等 `ifdef PCIE_OBS` 的 `else` 分支（FIFO 旁路成线名别名、`dp_clk=gmii_clk`） | "非 P6b 构建 = 单域" | **所有 P5/P6a/P6_t8p0/P6_t6p4 门与构建都走这个分支 ⇒ u_rxcdc/u_txcdc/链式快照在那些门里从不被激励**（坑 8/25 的形态）。P6b 侧有全链门（`run_tb_p6e_pcie.bat -d PCIE_OBS`），但见 F3 | ⚠️ 部分（§9.2-B 只要求"每个 `ifdef` 配置有一门"，没点出 FIFO 旁路分支本身从未被负向覆盖） |

---

## 5. 给施工 agent 的可执行建议（按代价排序）

- **R1（建议）**：把"数据面域"的判据从 `PCIE_OBS` 里**分出来**。两条路：
  ① 新建 `DP_156M`（或 `P6B_DPCLK`）宏，只在 `build_p6b_ku5p.tcl`（+ 已声明被取代的 `build_p6e`）定义，
  `rtl/*.v` 的 `ifdef PCIE_OBS`（`rtl/tcp_tx_frame.v` 等 5 个文件共 8 处常数）改 `ifdef DP_156M`；
  ② 或把 8 个常数改成**模块端口/参数**由 wrapper 显式传，wrapper 在时钟域分支内给值。
  代价小、风险低，但它把"两个语义无关的开关绑成一根线"这个雷拆掉。
  ⚠️ 注意 `board/wrapper_p4.v` 里 `PCIE_OBS` 同时守卫着 *时钟拓扑*（`:295-320`）、
  *FIFO 例化*（`:411-427`）、*快照通道* 与 *app 分支* ⇒ 换宏要**逐处**对照，别一刀切。
- **R2（撤回，见 F2）**：端口已正确 `ifdef`，无需动作。（保留一条**可验证的正面判据**：
  任何非 P6b 构建的端口表里都不应出现 `sys_clk_*` —— 可用 `report_io` 或 `.dcp` 的 `get_ports` 核对。）
- **R3（残留三条，必修）**：① 把 `clk_gen_p6b.v`/`fifo_async.v`/`snap_seq.v` 加进
  `sim/p6e_pcie/files.f`（否则全链门在 xelab 就挂）；② 把 `P6B_SPEC.md:1202` 的宏名
  `P6B_SIM_DPCLK` 改成实现里真用的 `P6B_SIM_CLKGEN`（工具脚本已经用后者）；
  ③ TB 里把 `sys_clk_n` 改成与 `sys_clk_p` **反相**（真 IBUFDS 需要差分），
  或者显式断言"本门只在 `P6B_SIM_CLKGEN` 下跑"，免得将来有人关掉旁路后误判"MMCM 不锁"。
- **R4（强烈建议）**：把 C1（`W1 == W31`）改成**三段式**：
  ① 前置：`W4` 自本版上电起**从未变过**（否则跳过并打印 `SKIP (有丢帧 ⇒ 恒等式不适用)`）；
  ② 主判据放**增量**：`ΔW0 == ΔW30` 且 `ΔW1 == ΔW31`（停机窗内的增量，而不是绝对值）；
  ③ 保留 `-1 ≤ W0−W30`/有向不等式做长跑回归。**绝对值式 C1 在第一次丢帧后就永久 FAIL 且无法归因。**
- **R5**：`W28` 的口径说明照实现（写域值）改规格书 §7.1/§7.2；并把 §7.2 的
  "两个值…天然保守 ≤ 真实占用"改成"`dbg_occ_w` 是**上界**、`dbg_occ_r` 是**下界**"。
- **R10（F4(b)，建议交回数据面审查）**：`mac_rx_64` 帧尾那次 push 的 `fifo_full` 与
  `fifo_sync` 真正落笔的 `full` **差了一拍**（前者是"本次 push 前"，后者是"上次 push 后"），
  二者只在"本次 push 恰好把 FIFO 填满"时分歧 —— 而**那正是丢帧压力最大的时刻**。
  三条可选修法（都要重跑 MAC 门）：
  ① 帧尾 push 前**先看** `wptr` 推一位后的满判据（等价于 `fifo_sync` 的 `wgray_n` 式保守判据）；
  ② 给 `fifo_sync` 加一个"写入被拒"输出，`mac_rx_64` 用它把 `stat_frames/stat_bytes` 回退（**不推荐**：改公共模块）；
  ③ 最省：**帧尾只在 `full==0` **且** `wptr` 距满 ≥2** 时才 push，否则走 `:156` 的整帧丢**（多丢一帧、但计数不撒谎）。
  ⚠️ 无论选哪条，**都要在 `tb_mac_rx_64` 的 `STALL2` 档里加一条断言**：
  "输出流里每个 SOP 后面在下一个 SOP 之前必须有一个 TLAST" —— 这条现在**不存在**，
  所以 (b) 类缺陷在任何现有门里都看不见。
- **R6**：`WIDTH(77)` → **76**（规格书 + wrapper 注释 + 例化参数）；并在 wrapper 注释里写明
  位域顺序 `{tdata[63:0], tkeep[7:0], tuser, tlast, tcrs, terr}`（76 位）。
- **R7**：§7.2 的 `localparam` 字面量删掉或按对照表改正（F5）。
- **R8**：补 §4 表里那几处遗漏（`÷80` 两处活算式、`README.md`「已建成的能力 · 慢路径」（重写前 `:69`）、`app_ctrl.v:79-80,128`）。
- **R9**：`set_false_path` 给 `reset_n`（PERST#）到复位同步器的路径，免得 recovery/removal 出来一条假违例。

---

## 6. 我**没能验证**的（诚实清单）

| # | 项 | 为什么没验 | 建议怎么验 |
|---|---|---|---|
| ~~N1~~ | ~~F2 的 Vivado DRC 预测~~ | **已撤回**：F2 本身是我的误判，端口在 `ifdef` 内（见 §3.1 的更正说明） | — |
| N2 | **全链门是否真的跑绿**（F3 的残留） | 需要 `files.f` + XDMA 全套；我读到 `files.f` 还没加三个新文件，elaboration 必然失败 ⇒ 我没花时间跑 | 补齐 `files.f` 后跑一次 `run_tb_p6e_pcie.bat`，并把日志入 `sim/p6e_pcie/` |
| N3 | ~~F4 中 F3 那一幕的精确分支~~ | **已钉死**（第二轮定点实验，逐拍轨迹见 §3.4）：帧尾 `:142` 读到 `full=0` **是对的**（7/8 占用），但同拍完成字的 push 把 `wptr` 顶到满 ⇒ 下一拍 `fifo_sync` 的 `wr && !full` 判假 ⇒ **TLAST 字被静默丢弃，而计数器已 +1** | — |
| N4 | **`fifo_async` 的综合推断**（FWFT=1 是否真的落 LUTRAM、256×77 的 LUT 数） | 同上，不能跑综合 | P6b 构建后 `report_utilization` grep `RAM64X1`/`RAM32X1` |
| N5 | **HLS 生成 RTL 里的实际时间常数** | 只读了 `hls/src/*`（它们带 `#ifdef` 覆盖）；没逐个核 `hls/slowstack_prj/solution1/syn/verilog/` | 对生成 RTL grep 那 5 个常数 |
| N6 | **`.gitattributes`/`.gitignore` 是否会让 `review_scratch/` 被误提交** | 未查（我按要求不 commit） | `git status --short` 复查 |
| N7 | **10G 下 43.2 ns 偏斜的余量** | 只做了 67.2 ns 除以 43.2 的一步估算，没重算 10G 下的 axi/dp 周期 | P6 收口时重推 |
| N8 | **`p6b_accept.sh` 其余 8 条判据的容差合理性**（如 `W13/W18/W19 恒 0`、`W4 涨速与 W0 脱钩`） | 时间预算；只审查了它与我发现冲突的 5/6/7 条 | 板级首测时逐条看 |

---

*本文件由 P6b 对抗审查 agent 产出（2026-09-29）。所有读数均给可复跑命令；所有"预测"均已标注。*
*实验产物：`review_scratch/`（`rw/tb_rvw_macrx.v`、`rw/mutC_full1stage.v`、`rw/mutF_rst1stage.v`、`run*.bat`、`rd_*` 日志）。*
*本 agent 未修改任何交付件，未 `git add/commit/push`，未烧板，未跑综合/实现。*

---

# 附录 R —— F4 修复的对抗复核（第二轮，2026-09-29）

> 复核对象：`rtl/mac_rx_64.v` + `rtl/fifo_sync.v`（F4 修复）+ `sim/f4sim/` 的证据。
> 我的全部原始产物在 `review_scratch/`：`rw/tb_rvw_fullnext.v`、`rw/tb_rvw_term.v`、
> `rw/tb_rvw_conserve.v`、`rw/mac_rx_64_old.v`（用 `git show HEAD:` 取的修复前版本，
> 仅重命名模块以便同 TB 内 A/B）、`runfn.bat` / `runterm.bat` / `runcons.bat` /
> `runmacrx*.bat` 及各自的 `rd_*/` 日志。
> **本轮我撤回或修正了自己 3 处误判**（见 §R.6），逐条留痕、不静默删除。

## R.1 ① `full_next` 的精确性 —— **通过（独立、遍历式）**

**解析**（`rtl/fifo_sync.v:53-57`）：`wptr_n` / `rptr_n` 就是**下一拍的真实指针**
（`wptr_n = wptr + (wr&&!full)`、`rptr_n = rptr + (rd&&!empty)`），而
`full_next = pred(wptr_n, rptr_n)`；下一拍的写闸门是 `wr && !full`，其中
`full`@(t+1) = `pred(wptr@t+1, rptr@t+1)` = `full_next`@t。
⇒ `push_ok = !full_next` **恰好**等于"本轮决定的这次推入下拍一定落笔"。
**两个方向同时成立**：不外溢（不漏字），也不悲观（不凭空丢帧）。

**TEST-1 遍历式核对**（`tb_rvw_fullnext.v`：force 指针 → 读 `full_next` → release → 过**一个真时钟沿**
→ 比对**下一拍真实的 `full`**。参考值是 DUT 自己的下一拍输出，**不是公式的重述**）：

| 配置 | 组合数 | 结果 |
|---|---|---|
| D=4 / AW=2 | 8x8x4 = 256 | **0 不一致** |
| D=8 / AW=3 | 16x16x4 = 1024 | **0 不一致** |
| D=16 / AW=4 | 32x32x4 = 4096 | **0 不一致** |
| **合计** | **5376** | **0 不一致** |

同一遍历里逐组合核对 `ovf_pulse === (wr && full)`：**5376/5376 成立**。

**TEST-2 自由跑逐拍滞后等价**：断言 `full_next@t === full@(t+1)`，60000 拍 x 3 配置
（读写占空比 7:4 / 6:5 / 7:3，既饱和又排空）⇒ **70752 次检查，0 错误**。

> ⚠️ **我的第一轮跑出 36056 次"不一致"，差点判"地基不稳" —— 那是我自己 TB 的采样竞争**
> （`wr`/`rd` 用非阻塞写在时钟沿翻转，却在沿后采 `full_next`，正是本工程坑 17 的形态）。
> 改成"沿前采样 + 沿后比对"后 **0 错误**。**这条是我的错，不是 DUT 的**（§R.6-a）。

## R.2 ② TERM 字通路 —— 下游逐个处置

| 下游 | 关键行 | 对 `tkeep=0,tlast=1,tcrs=0,terr=1` 的行为 | 结论 |
|---|---|---|---|
| `vlan_strip` | `rtl/vlan_strip.v:105,120-125` | 组合直通/拼接；`tlast` 与 `tkeep` 按原值走，无特殊分支 | 直通、无挂死 ✓ |
| `rx_classify` | `:118-124`（S_FILL 见 tlast ⇒ RT_SLOW）、`:131-141`（n==2/n==5 定路由）、`:152-170`（S_DRAIN/S_PASS） | TERM 的 tlast 让 FSM 在**正确的帧边界**回 S_FILL ⇒ **真正闭合了 S_PASS「只在 TLAST 上退出」的滞留隐患**；路由由**孤儿字**（被中止帧的头部）决定 ⇒ TERM 跟被中止帧走同一条路 | **隐患闭合** ✓（不是换形态） |
| `slow_rx_adp` | `rtl/slow_rx_adp.v:85-87,214-215` | `frame_bad = abort \|\| ff_full \|\| !s_axis_tcrs \|\| s_axis_terr` ⇒ TERM **两条都命中** ⇒ `do_rollbk` ⇒ **`stat_drop++`(W19)** | **W6 不被污染** ✓ / W19 必涨 |
| `frame_fifo` | `rtl/slow_rx_adp.v:69-75,92` | TERM 字先写入、随后被 `rollback` 整帧作废 | ✓（**潜在坑**：`keep2n(8'h00)` 落 `default` 返回 **1** 字节 —— 若哪天 TERM 真被播放会吐 1 字节垃圾，现靠 rollback 兜住） |
| `tcp_rx` | `rtl/tcp_rx.v:326-345`、`:700-800` | `trunc_pay` / `fend_pay` 处理"线上 tlast 早于承诺载荷"⇒ 闭合边界、按真实字节推进、`ferr=1` | 不死锁、不吞尾 ✓（优于旧行为"并进下一帧"） |
| app 侧（TX 惯例） | `CLAUDE.md` 坑 20 | 设计里**已有**另一种 `tkeep=0` 语义（TX 侧 0 载荷 opener = **合法**）。与 TERM（=坏帧、丢）**同符号不同义** | ⚠️ 未来碰撞风险；建议在 RX 侧注释里锁死语义 |

**「是否污染窗口计数器」的明确结论**

- **W6（`srx_stat_commit`）不被污染** ✓ —— TERM 同时带 `tcrs=0` **和** `terr=1`，`frame_bad` 必真。
- **W7 / W13 不受影响** ✓ —— TERM 不进 app、不进图案校验。
- **W19（`srx_stat_drop`）必然上涨** —— 每一个"已推过字"的被中止帧 +1。
  ⚠️ 这**改变**了 W19 的稳态值，而且方向是**修复带来的**：**旧**代码里被中止帧的孤儿字会
  **并进下一帧**，若下一帧 FCS 恰好是好的，那段"合并帧"可以**被 commit**
  （⇒ W6 多算、且提交的是垃圾数据）；**新**代码一律 rollback ⇒ **W6 更准**，
  但 **W19 从此与 MAC 层丢帧强耦合**。
  ⇒ **`_proj_pcie/p6b_accept.sh` 判据 5 的「W19 恒 0」必须改**（它已因 `W20==W7` 被点名一次，
  这是第二处，且**这一处是本次修复引入的**）。建议改成**有向耦合**：
  「`ΔW19 > 0` 只允许出现在 `ΔW4 > 0` 的窗口里」。

**⭐「有界性」结论（实测，不是推演）：有界，但"闭合"是条件性的。**
用**现成的** `tb/tb_mac_rx_64.v` STALL2 档配我自己的探针 TB，跑完整个激励后 DUT 停在这里：

```
PROBE npush=187 state=5(S_TERM) term_pend=1 first_done=1 fpushed=1368 hwv=0
      fifo_full=1 fifo_empty=0 stat_drop_full=9 stat_drop_partial=1
      stat_orphan_bytes=1368 stat_fifo_ovf=0
```

⇒ 交付流里**最后一个 SOP 永远没等到 TLAST**（`SOP=3 / TLAST=2 / TERM=0`），
**`term_pend=1` 挂着发不出去**；而**修复前的版本给出逐位相同的流**
（`OLD` 与 `NEW` 在该激励下 `words / frames / partials / SOP / TLAST / popc / stats` 全部相同）。
⇒ **修复声明第 4 条「交付流恒满足每个 SOP 后恰一个 TLAST」是假的**；
正确表述是「**一旦消费者继续排空**，交付流满足」。
同时：`stat_orphan_bytes=1368 = 171 字 x 8` ✓ 账目**完全正确**、`stat_fifo_ovf=0` ✓ **无静默丢失**、
`term_pend` 只有 **1 位** ⇒ 挂起态**有界**、消费者一读就解开 ⇒ **无死锁** ✓。
**⇒ 有界、非静默、不死锁，但"闭合"非无条件。**

## R.3 ③ 独立守恒律验证（我自己的激励）—— **PASS_ALL**

`rw/tb_rvw_conserve.v`：帧内容 8/9/14/15/20/60/63/64/65/72/200/1000（**含次最小 runt** ——
修复方自己的 `tools/gen_f4_stim.py` 最小只到 **60** ⇒ 它扫不到这些）、背靠背、坏 FCS、
硬停 tready 后全排空：

```
P1 (混合长度含 runt, 不 stall) / P2 (硬停 -> 全排空) / P3 (背靠背 64B)
REVIEW_CONSERVE_RESULT: PASS_ALL
  totals: words=371 popc=2934 SOP=33 TLAST=33 (nz=32 term=1) baresop=0
  L1 TLAST&keep!=0 == stat_frames               : 32 == 32                        OK
  L2 Sum popc == stat_bytes-4*F+stat_orphan_bytes: 2934 == 2998-128+64 = 2934       OK
  L3 TERM frames == stat_drop_partial           : 1 == 1                           OK
  L4a stat_drop_partial<=drop_full<=drop        : 1 <= 8 <= 8                      OK
  L4b stat_fifo_ovf == 0 (无静默丢失)           : 0                               OK
  L5 每个 SOP 恰一个 TLAST                      : bare SOP = 0                     OK
```

**「无溢出路径逐位不变」的独立复验**：用**现成的** `tools/gen_stim_mac.py` 激励 +
**现成的** `tools/parse_mac_rx.py` 三模式（在我自己的 scratch 副本里跑，**不动 `sim/`**）：

| 模式 | NEW vs 黄金 | NEW vs OLD |
|---|---|---|
| NOSTALL（严格逐词）| **PASS** | **逐位相同** |
| STALL（严格逐词）| **PASS** | **逐位相同** |
| STALL2（lenient）| **PASS** | **逐位相同** |

⇒ **`stat_fifo_ovf` 在我全部激励下恒 0 ⇒ F4(b) 的根因（帧尾那一拍写被静默丢弃）确实修好了** ✓
—— 这是本次修复最硬的正面结论。

## R.4 ⭐ 我新发现并已 A/B 复现的**修复引入的缺陷**：`term_pend==0` 空入 S_TERM 会白白牺牲下一帧

**现象**：`rtl/mac_rx_64.v:218-227`

```verilog
end else if (hwv && !push_ok) begin
    state <= S_TERM; hwv <= 0;                          // 无条件进 S_TERM
    stat_drop <= stat_drop + 1; stat_drop_full <= stat_drop_full + 1;
    if (first_done) begin term_pend <= 1'b1; ... end    // 但只有 first_done 才欠 TERM
```

`hwv==1 && first_done==0` ⇔ 净荷 **8..15 字节**（G=1 ⇒ 一次推入都没有）时：
**`state` 进了 S_TERM，而 `term_pend` 仍是 0** ⇒ `term_fire = term_pend && push_ok` **永假**
⇒ `:333` 的 `else if (gmii_rx_dv)` 把**下一个（空间充足、完全正常的）帧**吞掉并计为丢帧。

**复现（A/B：同一激励、同一 tready 表，修复前 vs 修复后）**：`cmd //c review_scratch\runterm.bat`

```
A1: C=64 帧 (恰好交付 8 字 => FIFO 正好满, 帧完成, term_pend=0)
A2: C=14 帧 (G=1 => 0 次推入, first_done=0)  -> NEW state=5(S_TERM) term_pend=0   <= 缺陷态
B1: 空间充足, 发一个正常的 C=200 帧
NEW: frames=1 drop=2          <= B1 被吞掉, 计成丢帧
OLD: frames=2 drop=1          <= B1 正常交付
DELTA frames (NEW-OLD) = -1   DELTA drops = +1
REVIEW_TERM_RESULT: FAIL -- NEW sacrificed a good frame the OLD delivered
```

⇒ **`rtl/mac_rx_64.v:218/220` 在 `!first_done` 场景把 S_TERM 当成 S_DROP 用，代价是白丢一帧**
（计数诚实、非静默，但比原缺陷更糟：原缺陷只丢**本该丢**的那一帧）。
**修法一行**：`state <= first_done ? S_TERM : S_IDLE;`

**触发条件与覆盖缺口**：需要净荷 **8..15 字节**（线上 12..19 字节，次最小 runt）**且** FIFO 无空位。
合规链路上不应出现这种帧 —— **但修复方自己的门永远测不到它**：
`tools/gen_f4_stim.py:47-66` 的帧尺寸最小 = **60**（`ctl`/`b*`/`a*` 全部 >= 60）
⇒ `first_done` 在任何丢帧之前必为 1 ⇒ **该分支覆盖率为 0**。
建议：改成 `state <= first_done ? S_TERM : S_IDLE;`，**并**给 `gen_f4_stim.py` 补
净荷 8/14/15 的用例（含"FIFO 先满 + 再来 runt"这一拍）。

## R.5 另两问

**`tools/parse_mac_rx.py:63-75` 的 lenient 分支会不会把 TERM 帧判成 `alien`？**
—— **本轮没有兑现，但理由不是"它安全"。** 我跑了现成门（NOSTALL/STALL/STALL2 全 PASS，
见 R.3），其中 STALL2 的 `alien=0`、`TERM(tkeep=0,tlast=1)=0`：因为**该激励下 TERM 从未真正发出**
（DUT 停在 S_TERM，见 R.2）。而 lenient 的判据是 `alien = frames not in exp_set`，
`exp_set` 来自 `gen_stim_mac.py` 生成的 `expected.memh`（**不含 TERM 形状**）⇒
**一旦某个用例的丢帧真的闭合出 TERM，那条判据立刻会报「外来帧」⇒ 假 FAIL。**
⇒ 结论：**这是"尚未引爆"的地雷** —— 修 `expected.memh` 的生成（或让 lenient 识别 TERM）
必须与该修复**同批**落地，否则**修好之后门反而变红**。
**它没有污染我此前的判读** —— §3.4 的 F4 证据用的是我自己写的 monitor（`rw/tb_rvw_macrx.v`），
不是这个脚本；我今后的判读也以自写 monitor 为准。

**W32–W35 的域归属**：**读盘时树里还没有这四个字** ——
`board/wrapper_p4.v:2537-2539` 仍是 `SNAP_NW_P6E=32 / SNAP_FE_NW=10 / SNAP_DP_NW=22`，
`rtl/snap_seq.v:51-52` 仍是 `FW=10 / DW=22`。
但域问题是确定的：修复新增的 4 个计数器都是 **`mac_rx_64` 的输出 ⇒ 前端域（`gmii_clk`）**
⇒ 若加上，必须进 **FE 束**（10 -> 14，总 36），**不能进 DP 束**（那是 `dp_clk`）。

⚠️ **而且 36 字现在装不下**，两处硬顶都在 `_proj_pcie/rtl/axi_regs.v`：

- `snap_idx = r_word[4:0] - SNAP_W0_IDX[4:0]` 只有 **5 位**（`:206-207`，上限 = 32）
- `snap_base` 只有 **`[9:0]`**（`:216`，`{35,5'b0} = 1120 > 1023`）

⇒ **读 W32..W35 会静默回绕到 W0..W3（假 PASS，不是 FAIL）**。
`:73` 的注释已经写死"上限 = 32"。扩到 36 字必须同时把 `snap_idx` 加宽到 6 位、
`snap_base` 加宽到 11 位。

**对我 S2 偏斜账的影响：没有。** 束变宽只是锁存寄存器的位数变多（并行），
链上的**拍数一个都不变** ⇒ 偏斜仍 ≈ **43.2 ns**（§3.2），与 FE 束是 10 字还是 14 字无关。

## R.6 我在本轮**撤回 / 修正**的东西（诚实清单）

| # | 我先前的判断 | 修正 |
|---|---|---|
| **a** | TEST-2 报 **36056 次 `full_next` 不一致** ⇒ 差点判"地基不稳" | **是我 TB 的采样竞争**（沿后采 `full_next`，而 `wr`/`rd` 在沿上翻转 = 坑 17）。改成沿前采样后 **0 错误**。**撤回** |
| **b** | `tb_rvw_conserve` 的 **L5「bare SOP」失败** ⇒ 差点判"帧边界律不成立" | **是我的 monitor 写错**：把 `SOP+TLAST` 同字的合法单字帧错误地留在 "open" 态。连改两版后 **bare SOP = 0**。**撤回** |
| **c** | （前一轮）F2 / F3 | 见 §0 表与文件头的时间戳说明，已撤回 / 降级 |
| **d** | F4(b) 的"帧尾那一拍"机制，我上一轮标注为**"待钉"** | 本轮**钉死**（§3.4 逐拍轨迹 + R.3 的 `ovf ≡ 0` 正面结论）⇒ **`full_next` 修法本身是对的** |
| **e** | 上一轮我把 `parse_mac_rx` 的 lenient 分支当作"将来会假 FAIL"的**推测** | 本轮**跑了**：现在**不**假 FAIL（因为 TERM 没真正发出）⇒ 降级为"尚未引爆的地雷"，并给出引爆条件 |

## R.7 本轮结论速览

| 攻击点 | 结论 |
|---|---|
| ① `full_next` 精确性 | ✅ **通过**：5376/5376 全组合 + 70752 拍滞后等价，0 错误；**两个方向都不偏** |
| ② TERM 通路 | ⚠️ **有条件通过**：W6 不被污染 ✓、S_PASS 隐患真闭合 ✓、无死锁 ✓、账目正确 ✓；**但** (i)「每 SOP 恰一 TLAST」只在消费者排空后成立（实测 STALL2 下 DUT 停在 S_TERM、`term_pend=1`、流中有未闭合的 171 字）；(ii) **W19 从此与 MAC 丢帧强耦合** ⇒ `p6b_accept.sh` 判据 5 的「W19 恒 0」要改；(iii) **`term_pend==0` 空入 S_TERM ⇒ 白丢下一帧**（A/B 实测 −1 帧 / +1 丢） |
| ③ 守恒律 | ✅ **PASS_ALL**（我自己的激励，含 8/9/14/15 字节 runt + 硬停 + 排空）；`stat_fifo_ovf ≡ 0`；**无溢出路径与修复前逐位相同** |
| `parse_mac_rx` lenient | ⚠️ 本轮未引爆（因 TERM 未真正发出），**但一旦闭合就会假 FAIL** ⇒ 必须与 `expected.memh` 的生成同批改；**未污染我此前的判读** |
| W32–W35 | 树里尚无（仍 32 字）；若加：**全部属 FE 域** ⇒ 必须进 FE 束；且 **36 字超出 `snap_idx`(5 位) / `snap_base`(10 位) 的硬顶 ⇒ 会静默回绕成 W0..W3**；**对 S2 偏斜无影响（仍 ≈43.2 ns）** |

*本节全部读数可复跑：`review_scratch/runfn.bat`、`runterm.bat`、`runcons.bat`、
`runmacrx.bat`、`runmacrx_old.bat`、`runmacrx_probe.bat`。*
*本轮同样未修改任何交付件（`rtl/`、`tb/`、`sim/`、`board/`、`_proj_pcie/` 一字未动），
未 `git add/commit/push`，未烧板，未跑综合/实现。*
