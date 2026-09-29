# P6B_INTEGRATION_REVIEW — P6b 集成的独立审查（只审不改）

> **审查对象**：P6b 集成 agent 的交付（`rtl/snap_seq.v`、`board/ku5p_p6b_sysclk.xdc`、
> `board/ku5p_p6b_cdc.xdc`、`board/build_p6b_ku5p.tcl`、`board/wrapper_p4.v`、
> `_proj_pcie/rtl/axi_regs.v`、以及同批并入的 F4 修复 `rtl/mac_rx_64.v` / `rtl/fifo_sync.v`）。
> **原则**：不信自述。每条结论都给**我自己跑出来的**原始证据（命令 + 读数 + file:line）。
> **我写过的路径**：只有本文件 + `int_scratch/`（未改动 `rtl/` `board/` `tb/` `_proj_pcie/` `sim/`
> 下任何既有文件；未 commit、未烧板、未跑综合/实现）。
> 时间：2026-09-29。工具：`C:\AMDDesignTools\2025.2\Vivado\bin\{xvlog,xelab,xsim}.bat`（仅仿真）。

---

## 0. 发现清单（按严重度）

| # | 严重度 | 一句话 | 我的原始证据 |
|---|---|---|---|
| **G1** | 🔴 **高（元问题，方案本身失效）** | **`bash sim/p4sim/run_matrix_p4dfix.sh` 从本仓跑 = 空门**：runner 把 `B=` 与 `OUT=` 都硬编码成 `D:\repo\ECO\udp_hls_10g\...`，9 个门 bat 又各自 `cd /d %~dp0` + 硬编码 ECO 源码路径 ⇒ 它测的是**另一个仓**，而且**把日志写进另一个仓**。⇒ 本仓里那份 `matrix_p4dfix.log` 是 **Sep 27 的陈旧副本**，而 09-29 03:58–04:23 那次"16 门全过"的日志落在 ECO 仓（见 §5） | `sim/p4sim/run_matrix_p4dfix.sh:3,5,18-35`；`sim/p4sim/run_tb_p4_chain.bat:19,24,28-32`；`stat` 两份同名日志 mtime = `09-27 13:01`（本仓）vs `09-29 04:23`（ECO） |
| **G2** | 🟠 **中（回归证据不成立）** | 用忠实的"本仓镜像"重跑的那次 16 门（09:50:05–10:15:24，日志 16×`EXIT=0`）**跑在编辑窗口里**：`rtl/fifo_sync.v` 09:54、`board/wrapper_p4.v` 10:17、`_proj_pcie/rtl/axi_regs.v` 10:18、`rtl/snap_seq.v` 10:19、**`rtl/mac_rx_64.v` 10:30（在矩阵结束之后）** ⇒ **当前工作树的 P4 默认构建回归没有被任何一次运行覆盖** | `stat` 各文件 mtime；`sim/p4sim_p6b/matrix_p4_p6b.log` 首末行时间戳 |
| **G3** | 🟠 **中（自述与事实不符，方向是好的）** | 施工方自述"`tools/parse_mac_rx.py` 未改" —— **实际已改**（+17/−3，加了 TERM 字/aborted 帧分类）。同批的 `gen_stim_mac.expected_words` 需同改的告警已写进该文件 `:80-82` | `git diff --stat -- tools/parse_mac_rx.py` |
| **G4** | 🟡 **中低（默认构建不是"逐位不变"）** | "P4 默认构建逐位等价"**作为一句话是错的**：同批并入的 **F4 修复**改了默认构建的 `rtl/mac_rx_64.v`（82 行**不在任何 ifdef 内**的代码：新端口 + TERM 字 + 4 个守恒计数）。**P6b 自己**的改动确实全在 ifdef 内 | 我自己的预处理比对（§4）；`git diff -- rtl/mac_rx_64.v` |
| **G5** | 🟡 **中低（历史坑：写了没生效）** | P6b 构建用的 `board/ku5p_p6a_t8p0.xdc:87,90` 两条 `FORCE_MAX_FANOUT`（`*u_retx/rpe*`、`*u_retx/nbeats*`）在**每一个实现阶段**都报 `[Common 17-55] set_property expects at least one object` ⇒ 5 条里只有 3 条在实现阶段真的生效。**非 P6b 回归**（P6e 构建同样报），且时序仍达标 | `p6b_build_console.log:3124,3126,4138,4140`（综合阶段**无**此警告） |
| **G6** | 🟡 **低（门文案/覆盖不自洽）** | `sim/snapcdc/run_tb_snap_cdc.bat:13` 印 `NW=36`，实际编译宏是 `-d TB_NW_32`（TB 默认 32）⇒ 这门跑的是 **{32, 24}**；且 **32 与 36 都不是集成时的实际束宽（FE=14 / DP=22）** | 该 bat `:13,16,24`；`tb/tb_snap_cdc.v:31-41` |
| | ✅ **已修（2026-09-29）** | 覆盖扩到 **5 个宽度 `14/22/24/32/36`**；且**声明改由 TB 自己打印**（`` `TB_NW `` 宏推出的 `TB_NW_SEL: NW=.. NB=.. MACRO=..`）并由 bat `findstr` 断言"声明==实际"，不再有两处人工维护的文案。变异 `nwbug`（删 36 分支 = 本缺陷的忠实复现）**只有 NW=36 那一遍 FAIL、其余 4 遍 TB 自己打 PASS_ALL** ⇒ 证明"没有新断言就会静默通过"。证据 `sim/snapcdc/gate_nw*.txt` + `mut5_nw/` |
| **G7** | 🟡 **低（空读数陷阱）** | `sim/f4sim/F4_GATE_new.log`、`F4_MUT_mut.log`、`F4_MUT_nogate.log` 都是 **0 字节**（判词在 `.txt` 里）—— 谁按"日志里没有 FAIL"读就会把空文件读成通过 | `ls -la sim/f4sim/*.log`；`tail sim/f4sim/F4_GATE_new.txt` |
| **G8** | 🟡 **低（漏网的时间常数）** | `TX_GAP`（`rtl/app_udp_pattern.v:86`，用 `board/wrapper_p4.v:2012` 例化）是**拍数**限速器，现在跑在 dp 域，**没有 `DP_156MHZ` 守卫**；当前值 0 ⇒ 无影响，但一旦非 0，实际速率会静默 ×1.25 | `grep TX_GAP`；§2 末 |
| **G9** | ⚪ **低（清理项）** | R9（`reset_n` 加 `set_false_path`）未做。我的判定：**低**——它不是"功能缺陷"而是"方法论告警未消"（`no_input_delay` 6 个端口，HIGH）。0 失败端点、`async_default` 9 组 WHS +0.113..+0.269、`unconstrained_internal_endpoints=0` | `board/p6b_ku5p_timing.rpt:85-89,104-108,234-242` |

**没有发现**：36 字窗口的映射错误、`snap_idx`/`snap_base` 位宽错误、链序反了、两个 FIFO 的位宽截断、
宏组合编不过、`set_clock_groups` 静默失效、闸 G 的 16 条 HDIO 违例回归。

---

## 1. ⭐ 36 字窗口映射 —— 逐字读回 + 我自己做的负对照

### 1.1 我自己的门（不复用施工方的 TB）

* TB：`int_scratch/tb_int_axr36.v`（自己写；直连 `_proj_pcie/rtl/axi_regs.v`，假快照源把
  **第 i 个字**写成 `32'hC0DE0000+i`，触发后逐字 AXI 读回）。
* 运行：`int_scratch/sim_axr36/`（唯一命名，避开 `xsim.dir` 文件锁）。
* 结果（44 笔读）：

```
INFO C1 MAGIC    = 50360001 OK          INFO C1 BUILD_ID = 00000006 OK      (BUILD_ID=6 ✓)
INFO C1 MARKER   = deadbeef OK          INFO C4 STATUS(t0) = 00000068 (fe=101 lk=1)
INFO C5 STATUS(t1) = 0001006e (gen=1 seen=1 done=1)
INFO C2 36 字逐字读回全对 (含 W32..W35 @0xA0..0xAC)
INFO C3 0xB0 = SLVERR, data=00000000 OK
INFO C3b 0xAC = c0de0023 OK (对照: 边界两侧行为不同)
PASS_ALL tb_int_axr36 (reads=44)
```

⇒ 36 字窗口（0x20..0xAC）、未实现地址 **0xB0**、`SNAP_STATUS` 位域（`[2]seen [1]done [0]busy
[5:3]fe_state [6]locked_axi`）全部**逐字**成立。

### 1.2 ⭐ 证明这条判据"有牙"（两个负对照，都在副本里改）

| 变异体 | 文件 | 结果 |
|---|---|---|
| **`snap_idx` 改回 5 位**（`wire [4:0] snap_idx = r_word[4:0] - 5'd8;`） | `int_scratch/neg5/axi_regs.v` | **FAIL**：`W32@0xa0 got=c0de0000 (=W0)`、`W33→W1`、`W34→W2`、`W35→W3`（+`C3b 0xAC` 连带 FAIL）= **5 条** |
| **`snap_base` 改回 10 位**（`wire [9:0] snap_base`） | `int_scratch/negbase/axi_regs.v` | **FAIL**：同样的 W32..W35 → W0..W3，5 条 |

两条变异的 `xvlog` **位宽告警 `10-3091` 计数都是 0、`implicitly` 计数也是 0** (⚠️ 后者 2026-09-29 实测已是**死关键字**, 0 命中 = 无话可说, 不能当证据; 见 `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md`)
⇒ 这正是那条"lint 全程沉默、只有例化真 DUT 逐字读回才抓得到"的静默回绕。**判据有区分能力。**

### 1.3 每个字的**生产者节点**与**域归属**（逐字核，不是 wrapper 导线）

`board/wrapper_p4.v:2738-2773` 的两条拼接逐项读出（我也用脚本数过顶层项数 = **FE 14 / DP 22**）：

| 束 | 槽 | 快照字 | 生产者（file:line） | 域 |
|---|---|---|---|---|
| FE | fe[0..5] | W0..W5 | `rx_stat_frames/bytes/{16'd0,wl_last}/crc_err/drop/gmii_free`：前 5 个来自 `mac_rx_64 u_u_mac_rx`（`.clk(gmii_clk)` `:392`，端口 `:405-408`）；`wl_last` 是 wrapper 自己的 `posedge gmii_clk` 寄存器（`:340-351`）；`gmii_free` 同域 always（`:2682-2688`） | gmii_clk |
| FE | fe[6],fe[7] | **W21**,**W20** | `tx_stat_abort`/`mac_tx_frames` ← `mac_tx_64 u_u_mac_tx`（`.clk(gmii_clk)` `:2227`，端口 `:2237-2238`） | gmii_clk |
| FE | fe[8],fe[9] | **W27**,**W26** | `{16'd0,rxcdc_occ_max}` / `rxcdc_full_cycles` ← `posedge gmii_clk` always（`:2682-2692`）；源 = `u_rxcdc` 的**写域**探针 `rxcdc_occ_w` / `rx_fifo_full`（`:430-440`，写侧 = gmii_clk） | gmii_clk |
| FE | fe[10..13] | W32..W35 | `rx_stat_{drop_partial,orphan_bytes,drop_full,fifo_ovf}` ← `mac_rx_64 u_u_mac_rx`（`:412-415`，F4 新增） | gmii_clk |
| DP | dp[0..13] | W6..W19 | `srx_stat_commit`/`srx_stat_drop` ← `slow_rx_adp u_slow_rx`（`.clk(dp_clk)` `:1883`）；`stx_stat_frames`/`purge` ← `slow_tx_adp u_slow_tx`（`:1928`）；`udpapp_*` ← `app_udp_pattern u_app_udp`（`:2013`）+ `app_status_uart` 镜像；`tx_stat_frames/bytes` ← `tcp_tx_frame`（`:1663-1664`）；`srx_hls_bytes`/`hr_cnt` ← `posedge dp_clk` always（`:2696-2710`） | dp_clk |
| DP | dp[14..17] | W22..W25 | `rx_stat_pass/nonmatch` ← `tcp_rx u_tcp_rx`；`{31'd0,mmcm_locked_sr_dp[1]}` ← `posedge dp_clk`（`:2723`）；`dp_free` ← 同块 `:2712` | dp_clk |
| DP | dp[18..21] | W28..W31 | `{16'd0,txcdc_occ_max}`/`txwire_stall_cycles` ← `posedge dp_clk`（`:2714-2716`）；`rxcdc_out_frames/bytes` ← 同块 `:2718-2720`（源 = `u_rxcdc` **读侧** AXIS，属 dp 域） | dp_clk |

⇒ **14 个字全在 `gmii_clk` 域、22 个字全在 `dp_clk` 域**；每个字都能追到生产者节点，
没有一个是"wrapper 上的悬空导线"。`snap_cdc` 的束宽也与项数一致（`.NW(SNAP_FE_NW)=14` `:2778`、
`.NW(SNAP_DP_NW)=22` `:2789`）。

### 1.4 链式顺序（`rtl/snap_seq.v`）—— 我自己独立做的

* TB：`int_scratch/tb_int_snapseq.v`。**映射表是我手工写死的 36 行**（来源 = 上面 §1.3 从 wrapper
  拼接**逐项读出**的结论），**不复用** `snap_seq` 自己的 `fe_idx_of/dp_idx_of`（自带 TB 复用它们
  ⇒ 抄错会跟 DUT 一起错）。顺序判据用**墙钟时间戳**（假 CDC 模型在各自 b 域捕获 `$time`）。
* 假 CDC 模型 = **忠实照抄 `rtl/snap_cdc.v` 的 toggle 握手**（`toggle_a` 电平翻转 + 3FF 同步 +
  `tog_sync_b^tog_sync_b` 边沿检测 + `ack_b` 回送 + `done_a=(ack_sync[2]==toggle_a)`）。
* 结果（41 代快照）：

```
INFO M1 映射错字数 = 0
INFO M2 样本 41 代: 顺序成立 41 / 违反 0 ; 偏斜(ps) min=36 max=41
INFO M3 req 连续高: fe=0 dp=0 (必须 0)        ← 硬契约① req 恰好 1 拍
INFO M4 valid 连续高: fe=0 dp=0 (必须 0)
INFO M5 触发 42 次 / 完成 41 次               ← 背靠背那一发被丢 (契约③)
PASS_ALL tb_int_snapseq (样本=41)
```

* **负对照（我自己重做，不是照抄施工方的 1188/1142.4）**：副本 `int_scratch/mutseq/snap_seq.v`
  把 FSM 改成 **DP 先 → FE 后**（`S_IDLE→req_dp→S_WDP→req_fe→S_WFE→assemble`），装配仍用
  `assemble(dout_fe,dout_dp)`（只反转顺序，隔离变量）：

```
INFO M1 映射错字数 = 0
INFO M2 样本 41 代: 顺序成立 0 / 违反 41 ; 偏斜(ps) min=-46 max=-39
FAIL_TOTAL tb_int_snapseq errors=1
```

⇒ 顺序判据**只在 FE 先时成立**：正例 41/41 偏斜 **+36..+41 ns**，反例 41/41 偏斜 **−46..−39 ns**。
（⚠️ 这组 ns 数是**我的模型**的往返延迟，不是对真设计 43.2ns 上界的测量——见 §7。）

### 1.5 我自己犯过的一个错（留痕，因为它差点变成假 FAIL）

我的第一版假 CDC 模型用"**脉冲 + b 域边沿检测**"⇒ 4ns 宽的 `req` 脉冲会被 8ns 的 gmii 时钟**整个漏掉**
（现象：`req_fe` 高过、`valid_fe` 永不来、`busy` 卡死、0 代完成）。**那不是 DUT 缺陷**：真
`rtl/snap_cdc.v:75-79` 用的是 **toggle 电平**（`req_a && !busy_a ⇒ toggle_a <= ~toggle_a`），
电平一直保持到被 b 域同步到 ⇒ 结构上不会漏窄脉冲。改成 toggle 模型后全部通过。
（教训：**"门红了先怀疑自己的激励"**，与工程坑 3/17 同族。）

---

## 2. §5 频率相关常数：逐条独立验算

施工方声称 8+ 处常数按"同一墙钟"重算。我把仓库里**全部** `ifdef DP_156MHZ` 守卫的常数挖出来逐条算：

| # | 文件:行 | 常数 | 旧值 | 新值 | 旧墙钟 = 值×8ns | 新墙钟 = 值×6.4ns | 误差 |
|---|---|---|---|---|---|---|---|
| 1 | `rtl/app_status_uart.v:56` | BIT_LAST | 13020 | 16275 | 104160 ns | 104160 ns | **0**（且新值更贴 9600：156.25e6/16276=9600.03 vs 125e6/13021=9599.11） |
| 2 | `rtl/app_status_uart.v:57` | GAP_TICKS | 250,000,000 | 312,500,000 | 2.000000 s | 2.000000 s | **0** |
| 3 | `board/uart_dbg.v:147` | BIT_LAST | 13020 | 16275 | 同上 | 同上 | **0** |
| 4 | `board/uart_dbg.v:206` | GAP_LAST | 624,999,999 | 781,249,999 | 5.000000 s | 5.000000 s | **0**（0.25 拍取整 ≈ 1.6ns/5s） |
| 5 | `rtl/app_pattern.v:292` | ACT_TMR_INIT | 200,000 | 250,000 | 1.600000 ms | 1.600000 ms | **0** |
| 6 | `rtl/slow_rx_adp.v:28` | WDOG | 2,097,152 | 2,621,440 | 16.777216 ms | 16.777216 ms | **0** |
| 7 | `rtl/slow_rx_adp.v:35` | RST_CNT | 64 | 80 | 512 ns | 512 ns | **0** |
| 8 | `rtl/tcp_tx_frame.v:171` | RTO_LIM | 48828 | 61035 | 390.624 µs | 390.624 µs | **0** |
| 9 | `rtl/app_ctrl.v:228` | FIN_TO_LIM | 195313 | 244141 | 195313×256×8 = 400.001024 ms | 244141×256×6.4 = 400.000614 ms | −0.41 µs（**1.0e-6**，195313×1.25=244141.25 取整） |
| 10 | `rtl/app_ctrl.v:241` | FIN_GRACE | 4 | 5 | 4×256×8 = 8.192 µs | 5×256×6.4 = 8.192 µs | **0** |
| 11 | `board/wrapper_p4.v:2300` | BOOT_HALF | 25,000,000 | 31,250,000 | 0.200000 s | 0.200000 s | **0** |
| 12 | `board/wrapper_p4.v:2333` | BLK_HALF | 31,250,000 | 39,062,500 | 0.250000 s | 0.250000 s | **0** |
| 13 | `board/wrapper_p4.v:2400` | UART_SW | 2^29 | 671,088,640 | 4.294967296 s | 4.294967296 s | **0** |

**误差为 0 的：11 条；非 0 的：2 条**（#9 差 0.41µs/1.0e-6；#4 差 0.25 拍）——两条都是
"×1.25 除不尽"的取整，量级 1e-6 ~ 3e-10，可接受。另外 #1/#3 的"值×周期"精确相等，
但真正决定波特率的是 **(值+1)×周期**，那上面差 1.6ns/1.5e-5，方向是**更准**。

### 2.1 ⭐ 重点怀疑的那一条：`uart_sel` —— **怀疑不成立**

> 任务给的推理是"位测试给 50% 占空比，幅值比较给 37.5%"。

**实测代码（`git diff` 逐字）**：

```
旧: always @(posedge gmii_clk ...) if (!reset_n) uart_sel<=0; else if (!uart_sel[29]) uart_sel <= uart_sel + 1;
    assign uart_txd = uart_sel[29] ? app_uart_txd : p4_uart_txd;
新: always @(posedge dp_clk ...)   if (!dp_rst_n) uart_sel<=0; else if (uart_sel < UART_SW) uart_sel <= uart_sel + 1;
    assign uart_txd = (uart_sel >= UART_SW) ? app_uart_txd : p4_uart_txd;
```

关键在 `else if (!uart_sel[29])` —— **旧写法也是自饱和的**：`uart_sel` 数到 2^29 就**停住**
（不是自由回绕的计数器）⇒ 它是**一次性切换**（"前 4.295s 发 P4 诊断行，之后常切到 app 状态行"，
与 `:2389-2392` 的注释一致），**没有占空比/周期可言**。新写法 `uart_sel < UART_SW` 同样是
**一次性饱和**，切换点 671,088,640 拍 ×6.4ns = 4.294967296 s = 旧 2^29×8ns **逐位同墙钟**。
⇒ **原意（一次性、4.295s 后永久切换）被完整保住**；"占空比 37.5%/周期不同"的分析**前提
（计数器回绕）在这份实现里不成立**。
附：默认构建（无 `DP_156MHZ`）取 `UART_SW = 30'h2000_0000 = 2^29`，与旧位测试**语义等价**
（唯一差别是计数器停在 2^29 而不是继续数到 2^30 再回绕——旧写法也停在 2^29）。

### 2.2 漏网的时间常数（G8）

`TX_GAP`（`rtl/app_udp_pattern.v:86`，`board/wrapper_p4.v:2012` 例化）是**帧间空闲拍数**限速器，
模块已搬到 dp 域但**没有 `DP_156MHZ` 守卫**。当前例化值 `16'd0`（全速）⇒ **今天无影响**；
但若有人为了复现 `peer --rate-mbps` 而设非 0 值，**同一行代码的实际速率会静默 ×1.25**。
建议：要么加守卫，要么在参数处写明"单位 = dp 拍"。
另：HLS 侧的时间常数（如 `hls/.../udp_echo.v:8418` 的 `32'd100000000` 拍）**没有改** ——
这与 `P6B_SPEC §5.3` 的"只记录不改"一致，但墙钟后果要写清：**该常数从 800ms@125MHz 变成 640ms@156.25MHz（−20%）**。

---

## 3. XDC 与约束

### 3.1 `board/ku5p_p6b_sysclk.xdc`

| 检查项 | 结果 | 证据 |
|---|---|---|
| `create_clock -period 10.000` | ✅ | 文件 `:36`；`board/p6b_ku5p_clocks.rpt:29` `sys_clk_100  10.000  {0.000 5.000}  P  {sys_clk_p}` |
| IOSTANDARD = `DIFF_SSTL12` | ✅（TL 裁决已落地） | 文件 `:40`；构建日志 `:158` `Parameter IOSTANDARD bound to: DIFF_SSTL12`。反方证据（厂商 MIG 用 POD12 实测能跑）与退路（改回 `DIFF_POD12_DCI` 重建）都写在 `:21-25` |
| 数据面时钟自动推导 = 6.400ns | ✅ | `board/p6b_ku5p_clocks.rpt:40` `g_hw.clk_out0 6.400 {0.000 3.200} P,G,A {u_clkgen/g_hw.u_mmcm/CLKOUT0}` —— 与"不手写 `create_generated_clock`"的纪律一致 |
| 参数与约束同值 | ✅ | `board/wrapper_p4.v:306` `CLKIN1_PERIOD_NS(10.000)`；`:307-309` MULT=12.500/DIV=1/CLKOUT0=8.000 ⇒ VCO 1250MHz |

### 3.2 `board/ku5p_p6b_cdc.xdc` —— **只在实现阶段应用**（本工程的历史坑）

✅ **成立**。两条独立证据：
1. `board/build_p6b_ku5p.tcl:107-108` 先 `add_files` 再 `set_property used_in_synthesis false`；
2. **综合日志里根本没有解析它**：`p6b_build_console.log:1089-1108` 综合阶段解析的 XDC 依次是
   `xdma_0_in_context.xdc / ku5p_p6a_t8p0.xdc / ku5p_p6e_pcie.xdc / ku5p_p6b_sysclk.xdc` —— **没有 cdc.xdc**；
   它只在实现阶段被解析（`:3136`、`:4150`）。
3. `Vivado 12-4739` 在本次构建日志里 **0 次命中**（`grep -c` = 0，`p6b_build_console.log` / `vivado_build_p6b.log`）。

### 3.3 `set_clock_groups` 是否**真的生效**（不是"写了没生效"）

✅ **生效**，且有直接证据：`board/p6b_ku5p_timing.rpt` 的 **Inter Clock Table**（`:217-227`）里
**只剩两条**内部路径：

```
pipe_clk        pcie_axi_aclk   2.241  0 fail   3 endpoints
pcie_axi_aclk   pipe_clk        2.694  0 fail   1 endpoint
```

**`phy1_rxc/gmii_clk` ↔ `g_hw.clk_out0` ↔ `pcie_axi_aclk` 之间一条跨域路径都没有** —— 这正是
三组 `-asynchronous` 生效的形状。三组的时钟名 `phy1_rxc` / `sys_clk_100` / `pcie_axi_aclk`
在 `report_clocks` 里都存在（`:28,29,41`），`-include_generated_clocks` 把 `gmii_clk` 与
`g_hw.clk_out0` 一并覆盖。**覆盖是全的。**

### 3.4 ⚠️ 新发现：两条"写了没生效"的约束（G5）

`board/ku5p_p6a_t8p0.xdc` 的 5 条 `FORCE_MAX_FANOUT`（P4c 时序修复）里，**`:87`（`*u_retx/rpe*`）
与 `:90`（`*u_retx/nbeats*`）在实现阶段找不到对象**：

```
CRITICAL WARNING: [Common 17-55] 'set_property' expects at least one object. [.../ku5p_p6a_t8p0.xdc:87]
CRITICAL WARNING: [Common 17-55] 'set_property' expects at least one object. [.../ku5p_p6a_t8p0.xdc:90]
（p6b_build_console.log:3124,3126,4138,4140；p6e_build_console.log 同样 2 条/阶段）
```

综合阶段**没有**这条警告（⇒ 那 5 条在综合时全部匹配成功）。定性：**非 P6b 回归**（P6e 构建
逐条相同），时序仍达标（WNS +0.373 / 0 失败端点），但它是**"看起来写了其实没生效"的典型**，
而且正好指向 P4c 修复点名的那两条最差网（`rpe` 是 282 个 BRAM 地址脚的最差网）⇒ 值得单独核实
"这两条属性到底有没有作用到目标网"（做法：`get_nets -hier -filter {NAME =~ "*u_retx/rpe*"}` +
`get_property FORCE_MAX_FANOUT`，在 opt_design 之后查）。

### 3.5 时序读数复核（我自己跑闸）

`python board/check_p6b_timing.py board/p6b_ku5p_timing.rpt --expect dual` → `rc=0`，
WNS **+0.373**、WHS **+0.010**、WPWS **+0.000**、失败端点 **0/220748**、
`All user specified timing constraints are met.`、时钟族 = `~8.000ns` + `~6.400ns`。

**闸 G 那 16 条 HDIO Min-Period 违例**：✅ 消失（在"违例"的意义上）——`board/p6b_ku5p_failing_endpoints.txt`
是 **0 字节**；`p6b_ku5p_timing.rpt:1040-1043` 的 `IDDRE1/C Min Period` 现在是 **slack 0.000**。
⚠️ 但要说精确：**要求 8.000ns、达成 8.000ns ⇒ 余量恰好为 0**（与 P6a t8p0 基线的 WPWS=0.000 同形），
**不是"有余量"**。P6b 的既定方案（前端留 125MHz）让这条从 −1.600 回到 0，但**这条器件上限一直是贴边**。
施工方自己的工具也把这个 WARN 出来了（判据 3d）。

### 3.6 我自己做的时序闸负对照（证明它不是"永远 PASS"）

| 变异（在 `int_scratch/mut/` 的副本上做） | 结果 |
|---|---|
| (a) 总表 setup 失败端点 `0 → 1` | `rc=1` `TIMING-FAIL: FAIL=2` ✅ 有牙 |
| (b2) **彻底删掉数据面时钟**（所有含 `clk_out0` 的行 + 全部 `6.400`） | `rc=1`，判据2 `FAIL 缺 ~6.400ns 域 (数据面 156.25MHz) —— 数据面**没搬到**新域` ✅ 有牙 |
| (c) `IDDRE1/C Min Period` slack `0.000 → -1.600` | `rc=1` `FAIL=1` ✅ 有牙 |
| 正例（真报告） | `rc=0` `PASS=8` ✅ |

（⚠️ 我第一次做 (b) 只把 23 处 `6.400` 改了 1 处 ⇒ 工具报 PASS，我一度以为判据 2 有洞。
**那是我变异不彻底**，重做后 FAIL。留痕以免后人误读。）

---

## 4. 宏分离（F1 的修复）

### 4.1 四种宏组合都 lint + elab 通过（我自己跑的）

固定 `APP_MODE=1 DEV_USP=1`，变 `{PCIE_OBS, DP_156MHZ}` 的 2×2（顶层 = 真 `wrapper_p4`，
含 `xdma_0_sim_stub.v` + `glbl.v`，`-L unisims_ver`）：

```
[none]      xvlog rc=0  10-3091=0 implicit=0 xvlogERROR=0 | xelab rc=0
[pcieobs]   xvlog rc=0  10-3091=0 implicit=0 xvlogERROR=0 | xelab rc=0
[dp156]     xvlog rc=0  10-3091=0 implicit=0 xvlogERROR=0 | xelab rc=0
[both]      xvlog rc=0  10-3091=0 implicit=0 xvlogERROR=0 | xelab rc=0
```

⇒ 四种组合**全部编过且能 elaborate**（四组合都没报 undeclared / implicit / 位宽）。
  ⚠️ **2026-09-29 订正**: 这里的 "implicit" 是**死关键字** ⇒ 该项实际只能证 "没有**表达式形式**的未声明"，**不能证 "没有隐式网"**（端口连接形式在 xvlog 里全静默）。见 `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md`。
`int_scratch/mac/files.f` 是 211 个文件的清单；每个组合在 `int_scratch/mac_<tag>/` 独立目录跑（避文件锁）。

### 4.2 "P4 默认构建与 P6b 之前逐位相同" —— **我能证到什么程度（不含糊）**

我做的**独立方法**：把两份源码（`git show HEAD:file` vs 工作区）各做一遍**宏预处理**
（`ifdef/ifndef/else/endif` 求值，取默认构建 = 无宏分支），再比对**非注释代码行**：

| 文件 | 默认分支（P4）代码行差异 | 定性 |
|---|---|---|
| `board/uart_dbg.v` | **0** | 默认分支**逐字节不变** |
| `rtl/app_ctrl.v` | 4 | 只有**行尾注释**变（参数值 195313 / 4 未动）⇒ **行为无变化** |
| `rtl/tcp_tx_frame.v` | 2 | 同上（48828 未动） |
| `rtl/app_pattern.v` | 3 | `act_tmr <= 20'd200_000` → `act_tmr <= ACT_TMR_INIT`，默认值仍 `20'd200_000` ⇒ **等价改写** |
| `rtl/slow_rx_adp.v` | 5 | `rst_cnt <= 7'd64` → `rst_cnt <= RST_CNT`，默认仍 `7'd64` ⇒ **等价改写** |
| `rtl/app_status_uart.v` | 10 | `gap` 寄存器 **28 位 → 29 位**（`28'd0 → 29'd0`）：取值上限 250,000,000 < 2^28，比较/减法都不变 ⇒ **行为等价，但寄存器位宽不同 ⇒ 网表不保证逐位** |
| `board/wrapper_p4.v` | 177 | `wire dp_clk = gmii_clk; wire dp_rst_n = reset_n;` 两条**纯别名** + 所有新逻辑（FIFO/快照/新端口）在 `ifdef PCIE_OBS`/`DP_156MHZ` 内；别名不产生逻辑 ⇒ **逻辑等价，但我没做网表对比** |
| `rtl/fifo_sync.v` | 7 | **纯增量**：新增 2 个输出端口 `full_next`/`ovf_pulse`（组合 assign）+ 注释，**既有读写逻辑一行未改** ⇒ 既有例化行为等价 |
| `rtl/mac_rx_64.v` | **82** | 🔴 **默认构建的行为被有意改了**：F4 修复（新增 4 个 `stat_*` 端口 + 整帧中止补 **TERM 字** + `fpushed/term_pend`）。见 §4.3 |

**结论（明确版）**：
* **P6b 自己引入的改动**：默认构建下**源文本层面**除注释/等价改写/`gap` 位宽外**没有变化**，
  新增逻辑全在 `ifdef` 内 ⇒ **行为级回归 = ✓（16 门 + 我自己的 4 宏 lint/elab）**；
  **网表位级 = ✗（未证）** —— 要证必须对两版源码各综合一次再比网表，**这超出本次授权**（禁跑综合）。
  `gap` 的 28→29 位与 wrapper 的别名是"行为等价但网表不保证逐位"的两处，若有人要严格网表等价，
  这是仅有的两个候选点。
* **同批并入的 F4 修复改变了默认构建**（G4）⇒ **"P4 默认构建与 P6b 之前逐位相同"作为一句话不成立**。
  正确的说法是："P6b 不改默认构建；**F4 改**（`rtl/mac_rx_64.v`），它有自己的门
  （`sim/f4sim/`：`F4_GATE` PASS_ALL、`BITEXACT` 交付词流逐位相同、3 个变异体 FAIL、`MACREG_*` 三档 PASS）"。

### 4.3 F4 修复的独立观察（**我没重跑它的门**，只核了代码与日志）

* `git diff` 显示 `mac_rx_64.v` 的 82 行改动**不在任何 ifdef 里** ⇒ 所有构建（含 P4 默认）都变。
* `rtl/fifo_sync.v` 只加端口、不改已有逻辑（所以"FIFO 写被静默丢弃"的**根因仍在**：`wr && !full` 才落笔，
  无背压无计数；修复的做法是**让生产者用 `full_next` 空间门 + 用 `ovf_pulse` 自检**，合同写在
  `rtl/fifo_sync.v:5-17`）。这是"记录合同而非改语义"的选择——合理，但**依赖生产者自觉**。
* `sim/f4sim/BITEXACT.log`：`BITEXACT-RESULT: PASS (交付词流逐位相同)` —— 支持"严格档不受影响"。
* 我**没有**独立重跑 `sim/f4sim/` 与 `sim/f4chain/`（它们在 10:44 仍在被写）。

---

## 5. ⭐ P4 矩阵的"空门"问题 —— 核实结果与"历史证据是否受影响"

### 5.1 事实链（全部可复跑）

1. **runner 的路径是硬编码的另一个仓**：
   `sim/p4sim/run_matrix_p4dfix.sh:3` `B=/d/repo/ECO/udp_hls_10g/sim/p4sim`；
   `:5` `OUT=/d/repo/ECO/udp_hls_10g/sim/p4sim/matrix_p4dfix.log`；
   `:18-35` 每个门都 `cmd //c "$B\\run_tb_....bat"` 或显式 `D:\\repo\\ECO\\...`。
   9 个门 bat 自身 `cd /d %~dp0`（= ECO 目录）并硬编码 ECO 的 `rtl/ tools/ tb/ hls/` 路径
   （例：`sim/p4sim/run_tb_p4_chain.bat:19,24,28-32`）。
   ⇒ **从本仓执行这条命令，编的是 ECO 的源码，日志写进 ECO 的仓。**
2. **日志的两个 mtime 就是铁证**：
   * 本仓 `sim/p4sim/matrix_p4dfix.log` = `P4d-fix matrix start Sun Sep 27 12:36:48`，mtime **09-27 13:01**
     （= 本仓被拷贝时带过来的**陈旧副本**；内容是 ECO 的 Sep 27 那次全跑）；
   * ECO `D:\repo\ECO\udp_hls_10g\sim\p4sim\matrix_p4dfix.log` = `start Tue Sep 29 03:58:35` /
     `MATRIX DONE Tue Sep 29 04:23:11`，mtime **09-29 04:23**；
   * 提交 `a31c86b`（**09-29 04:27**）的标题写着 **"P4 默认构建矩阵 16 门全过"**。
   ⇒ 那次"16 门全过"的**物证躺在另一个仓**，本仓里看起来"什么都没跑"。
3. **另一个仓的树不是本仓的树**：`git -C /d/repo/ECO/udp_hls_10g log` = 干净工作区 @
   **`a719030`（09-28 21:09，本仓 HEAD 的第 27 代祖先）**；本仓 HEAD = `a31c86b`。
4. **逐文件比对（用 git blob，消除 `core.autocrlf` 的行尾噪声）** ——
   P4 各门编译的 **23 个源文件**（`rtl/*.v` + `tools/gen_stim_*.py`）：
   **22 个 blob 相同，1 个不同** = `rtl/frame_fifo.v`（本仓 HEAD `fbb93a14` ≠ ECO `c9194133`，
   差 `229efee` 那个 P6a 提交）。HLS 输出目录 **176/176 完全相同**。
5. **真正需要被回归的 4 个文件根本没进那次运行**：本仓工作区相对 HEAD 改了
   `rtl/fifo_sync.v`、`rtl/mac_rx_64.v`、`rtl/slow_rx_adp.v`、`rtl/tcp_tx_frame.v`
   —— ECO 那棵树里是**改动前**的版本。

### 5.2 判断（明确版）

* **这一次（09-29 03:58–04:23）的"16 门全过"是空门**：它跑的是 `a719030` 的树（其中
  `frame_fifo.v` 比本仓还旧一版），**完全没覆盖**那 4 个被改的文件 ⇒ 它**不能**作为
  "P4 默认构建没被碰过"的证据。
* **历史（P6b 之前）的 P4 矩阵证据不受影响**：在被拷贝之前（≤09-28 21:09），
  `D:\repo\ECO\udp_hls_10g` **就是**当时的开发树，`PORT_NOTES.md:2694` 也把命令写成
  `bash /d/repo/ECO/udp_hls_10g/sim/p4sim/run_matrix_p4dfix.sh` —— 那时它不是空门。
  受影响的**只有**"拷贝之后仍然引用这条命令"的说法 ⇒ 就是提交 `a31c86b`，
  以及本仓里那份**看起来是证据、实际是 09-27 陈旧数据**的 `matrix_p4dfix.log`（更毒：
  谁去读它，读到的是别的仓两天前的读数）。
* **镜像脚本忠实**（我自己用**逆向路径替换**重算，不复用生成脚本的函数）：
  9 个镜像 bat 全部 **逆向还原后与原件逐字节相同**；镜像里 `XCKU5PMini` 出现 26/26/26/26/26/3/1/3/1 次，
  **ECO 残留 0 处** ⇒ 是原件本身，不是被削弱的版本。
* **镜像矩阵的结果**：`sim/p4sim_p6b/matrix_p4_p6b.log`（09:50:05→10:15:24）= **16 门全 `EXIT=0`**，
  每门命令行都指向 `/d/repo/XCKU5PMini/...`（链门 `P4 CHAIN OK`、9 门 `BURST OK`）。
  **但（G2）**这个窗口**与编辑重叠**：`rtl/fifo_sync.v` 09:54、`wrapper_p4.v` 10:17、
  `axi_regs.v` 10:18、`snap_seq.v` 10:19、**`rtl/mac_rx_64.v` 10:30（晚于矩阵结束 10:15:24）**
  ⇒ 这 16 门**无法绑定到任何一个冻结的修订**，**当前工作树的 P4 回归仍未成立**。

### 5.3 修法建议（有序）

1. **runner 自定位**：把 `B=$(cd "$(dirname "$0")/../.." && pwd)` 与 `OUT=$B/sim/p4sim/...`
   写进 `run_matrix_p4dfix.sh`（bat 里同理用 `%~dp0..\..\`），**并把解析出的 root 打到日志第一行**；
2. **加"路径越界"守卫**：每门 `xvlog` 之后 grep 日志里的源文件路径，出现 `D:\repo\ECO` 即硬失败
   （本工程已有隐式网制定例；⚠️ **2026-09-29 订正**: 不要照抄旧的 `findstr implicit` —— 它在 2025.2 下恒 0 命中, 而且只 grep xvlog 日志时**结构性拓不到端口连接形式**。用 `sim/p4gates/implicit_gate.bat` 的 5 键表, 并保证判据跑在 `xelab`/`synth_design` 日志上）；
3. **回归要冻结修订**：跑之前把要测的源码树 `cp` 到临时目录（或至少把关键文件的 md5 打一行进日志），
   跑完核对；**施工纪律同款**："构建期间不得改动被构建的源码"；
4. 本仓的 `sim/p4sim/matrix_p4dfix.log` 应标为**废弃/陈旧**（或在 adopt 新 runner 后重跑覆盖它）。

---

## 6. 其它

### 6.1 两个 FIFO 的 `.WIDTH` 与实际拼接位数（自己数，不看注释）

| 例化 | 参数 | 我数的拼接 | 结论 |
|---|---|---|---|
| `board/wrapper_p4.v:430` `u_rxcdc` | `.WIDTH(76)` | `din = {rxsrc_tdata(64), rxsrc_tkeep(8), rxsrc_tuser(1), rxsrc_tlast(1), rxsrc_tcrs(1), rxsrc_terr(1)}` = **76** | ✅ 相符；`dout` 的顺序与 `din` **逐项同序**（`:432` vs `:435`）⇒ 无位错位 |
| `board/wrapper_p4.v:2205` `u_txcdc` | `.WIDTH(73)` | `din = {txsrc_tdata(64), txsrc_tkeep(8), txsrc_tlast(1)}` = **73** | ✅ 相符；`dout` 同序（`:2207` vs `:2209`） |

顺带核了"侧带有没有被静默丢掉"：`tuser/tcrs/terr` 一路上都有消费者
（`rx_tuser→vlan_strip.s_axis_tuser:478`、`tcrs:479`、`terr:480`，再经 `u_classify` 的
`m_slow_*:517-519` → `udp_split.p_axis_*:1770-1772` → `slow_rx_adp.s_axis_*:1890-1892`）。
**没有侧带被丢**。F6（规格书写 77）确实是规格书的算术错，实现取 76 是对的。

### 6.2 施工方自认未做的四条，我的严重度判定

| 项 | 我的判定 | 理由（原始证据） |
|---|---|---|
| **R9** `reset_n` 加 `set_false_path` | **低（清理项）**，不是功能缺陷 | `reset_n` 是纯输入端口且**没有 input delay** ⇒ 根本没被时序分析（`check_timing`：`unconstrained_internal_endpoints 0`；`**async_default**` 9 组、失败端点 0、WHS +0.113..+0.269）。加 false_path 的价值是消掉 `no_input_delay (6) HIGH` 这条方法论告警 |
| **`tools/parse_mac_rx.py` "未改"** | **自述不实（方向是好的）** | `git diff --stat` = `17 insertions(+), 3 deletions(-)`，加的正是 P6B_REVIEW 建议 (e) 的 TERM 帧分类（`:65-74`）。**它改了** |
| **`tb_snap_cdc` 的 `SKEW_STEP_NS` 被改过** | **可接受（TB 自纠）** | 旧值 0.15 是硬编码 ⇒ NW=32 时整束偏斜 4.8ns > `clk_b` 半周期 4.55ns ⇒ 判据 2 假 FAIL（TB 自身越界）。新式 `3.6/NW` 在 NW=24 时**恰好还原 0.15**（对旧结论零影响），NW=32 时 0.1125。属激励修正，**不动 DUT** |
| **`sim/snapcdc/run_tb_snap_cdc.bat:13` 文案不符** | **低，但我升级半级** | `:13` 印 `NW=36`，`:16` 用的是 `-d TB_NW_32`，TB 默认 = **32** ⇒ 实际跑的是 **{32, 24}**。更值得说的是：**32 与 36 都不是集成时的实际束宽（FE=14、DP=22）** ⇒ 那条"证明本模块不依赖具体字数"的主张应改写成"在 {32,24} 上成立"，且**这个单元门从未测过真实例化值**（与工程坑 11"门绿而板红"同族，尽管 snap_cdc 是纯参数化逻辑、风险很低） |

### 6.3 资源/身份（顺手核）

* `board/wrapper_p4.v:2883` `.BUILD_ID_V(32'h00000006)` ⇒ **BUILD_ID = 6** ✅ 与自述一致（我的门也读回 6）。
* `board/p6b_ku5p_util.rpt` 存在（14KB），本次未做逐项资源对比（P6b 的资源结论不在我的必核清单里）。

---

## 7. 我没能验证的 / 我自己的误判（诚实清单）

**未能验证**：
1. **网表位级等价**（P4 默认构建）：需要综合两版源码再比网表 —— 本次明确禁跑综合/实现。
   我只能证到"源文本默认分支逐字节不变 / 仅等价改写"（§4.2），**不能证网表逐位**。
2. **真 wrapper 全链**：我的 36 字门例化的是 `axi_regs` + **我的**假快照源；`snap_seq` 门用的是
   **我的**假 CDC 模型。**施工方的 `sim/p6e_pcie/tb_p6e_pcie_wrapper.v`（真 wrapper + XDMA stub）
   我没有跑**。所以"`fe_src`/`dp_src` 的项数与顺序 vs `snap_seq` 的表"这条**三重一致性**，
   我的证据 = **逐项读源码 + 我自己的表**，**不是**端到端 wrapper 仿真。
3. **板级**：未烧板（授权禁止）。
4. **镜像矩阵是否跑在同一份冻结源码上**（G2）—— 由 mtime 只能证明"不能证明"，不能证明"一定错"。
5. **ECO 那次运行的其他输入**（`.memh` 刺激文件、生成器脚本、tcl）我只比了 23 个 `.v/.py` + HLS 目录。
6. **F4 自身的门**（`sim/f4sim/`、`sim/f4chain/`）我没有独立重跑（那些目录到 10:44 还在被写）。
7. **HLS 内部时间常数的墙钟影响**：只做了静态识别（§2.2），没有测量。
8. **`p6b_accept.sh` 的 9 条板级判据**：未跑（要板）。

**我自己的误判（撤回/更正，留痕）**：
1. **假 CDC 模型用脉冲+边沿检测** ⇒ 漏掉 4ns 窄脉冲，一度让 `snap_seq` 门"全线 TIMEOUT"。
   真 `snap_cdc` 用 toggle ⇒ **不是 DUT 缺陷**（§1.5）。
2. **时序闸负对照 (b) 第一次变异不彻底**（23 处 `6.400` 只改 1 处）⇒ 误以为判据 2 有洞。
   重做后 FAIL（§3.6）。
3. **"ECO 与本仓有 3 个源文件不同"是我的行尾噪声假象**：改用 `git show HEAD:` 的 blob 比对后，
   真差异只有 `rtl/frame_fifo.v` **1 个**（`core.autocrlf=true` 下工作区是 CRLF、blob 是 LF；
   `.gitattributes` 只对 `*.sh` 强制 `eol=lf`）。**这条更正很重要，否则会冤枉另外两个文件。**

---

## 附录 A：我跑过的命令（可复跑）

```bash
# 1) 36 字窗口逐字读回 (+ 两个负对照)
cd D:/repo/XCKU5PMini/udp_hls_10g/int_scratch/sim_axr36   # 及 sim_neg5 / sim_negbase
xvlog.bat -work xil_defaultlib ../neg5/axi_regs.v ../tb_int_axr36.v
xelab.bat -debug typical xil_defaultlib.tb_int_axr36 -s tb_int_axr36
xsim.bat  tb_int_axr36 -runall

# 2) snap_seq 链序 (+ DP-first 变异体)
cd ../sim_snapseq                                          # 及 sim_snapseqneg
xvlog.bat -work xil_defaultlib ../../rtl/snap_seq.v ../tb_int_snapseq.v && xelab ... && xsim ...

# 3) 2×2 宏矩阵 (真 wrapper 顶层)
cd ../mac_both                                             # none/pcieobs/dp156/both
xvlog.bat -work xil_defaultlib <defines> -d APP_MODE -d DEV_USP -i <rtl -i <board> -f ../mac/files.f
xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s wrap_both

# 4) 时序闸 + 我自己的 3 个负对照
python board/check_p6b_timing.py board/p6b_ku5p_timing.rpt --expect dual          # rc=0
python board/check_p6b_timing.py int_scratch/mut/a_setupfail.rpt --expect dual     # rc=1
python board/check_p6b_timing.py int_scratch/mut/b2_nodp.rpt     --expect dual     # rc=1 判据2 FAIL
python board/check_p6b_timing.py int_scratch/mut/c_iddre.rpt     --expect dual     # rc=1

# 5) 镜像忠实性 / P4 空门取证
python int_scratch/chk_mirror.py        # 9 个 bat 逆向还原 == 原件 -> MIRROR_FAITHFUL
python int_scratch/chk_p4files.py       # (行级版; blob 版见 §5.1.4)
git -C /d/repo/ECO/udp_hls_10g log --oneline -2 ; git -C ... status --short
```

## 附录 B：我写过的路径（全部新增，未改任何既有文件）

```
P6B_INTEGRATION_REVIEW.md          ← 本文件
int_scratch/tb_int_axr36.v         tb_int_snapseq.v   probe_seq.v
int_scratch/chk_mirror.py          chk_p4files.py     scan_consts.py
int_scratch/neg5/axi_regs.v        negbase/axi_regs.v mutseq/snap_seq.v
int_scratch/mut/{a_setupfail,b_no6p4,b2_nodp,c_iddre}.rpt
int_scratch/mac/files.f   int_scratch/sim_*/   int_scratch/mac_*/
```

**未做**：`git add/commit/push`、烧板、跑综合/实现、修改任何既有文件、碰 `D:\repo\perfv`。
