# P7B 闸 1 —— 官方 `xxv_ethernet` PCS 在真板上的第一次读数（J7↔J8 自环）

- 日期：2026-09-29
- 器件：`xcku5p-ffvb676-1-e`（-1 最慢等级）· 工具：Vivado 2025.2
- 施工目录（**本轮全部产物**）：`udp_hls_10g/_proj_10g/xxv_loop/`
- 判据来源：`P7B_SPEC.md` §5.1（闸 1）/ §6.1（A 组、C 组）/ §6.2（N1、N5）
- **本轮未改任何既有 RTL / 既有工程 / 既有文档**（除本文件）；**未写板载 QSPI**（只走 JTAG 易失烧录）；
  未动 license 文件；未执行任何 git 写操作；未碰 `D:\repo\perfv`。

### 证据强度标记（与 `P7B_SPEC.md` 同义）

| 标记 | 含义 |
|---|---|
| 【板级实测】 | 上板读数的原始文本，本文件给 `文件:行号` |
| 【已实测】 | 工具原始输出（构建日志 / 报告 / `.xci`/`.veo` 原文） |
| 【明文RTL】 | 仓库内可逐行核对的源码（AMD 明文或本仓自写） |
| 【自算】 | 本文件独立复算，算式写出 |
| 【推定】 | 逻辑推理，无直接证据 |
| 【未核实】 | 不知道。**不得当判据用** |

---

## 0. 一句话结论

**官方 `xxv_ethernet`（`CORE = Ethernet PCS/PMA 64-bit`，2 通道 X0Y4+X0Y5）的位流已产出并烧进 KU5P，
用官方 example design 的图案发生器/监视器（AMD 明文，`pcs64_pkt_gen_mon.v`，**未改一行**）
经板内光路 J7↔J8 跑通：双向 block_lock=1，官方判据 `completion_status == 1`
（`SUCCESSFUL_COMPLETION`）在**连续流约 8.5 秒（40,287,842 帧）**之后成立，
其中**判据窗口 6.6 s 内 30,056,095 帧**，窗内 **Δ`/E/` 控制字符 = 0、Δ内容失配 = 0**；把两端 `TX_DIS` 分别拉高时，
判据按预期翻成 `NO_BLOCK_LOCK(2)`、对端 `RX_LOS` 亮起、`/E/` 计数从 0 涨到 11,808
⇒ **判据有牙 + `LOS` 引脚映射被独立印证**。**

**唯一没闭合的一条**：`stat_rx_error[7:0]` 的 `_valid` **整场从未触发**（`nv0=nv1=0`，见 §5.11）
⇒ 它的"恒 0"是**"这条线没话说"**，不是"实测为 0"（R12 的形态，必须如实登记）。

---

## 1. 目标与"这一轮做了什么"

目标（用户任务书）：在真板上把**官方 `xxv_ethernet` PCS** 走通，拿到第一次真实 10G 数据穿过官方 PCS 的读数。
路线（不可改）：用**官方 example 的图案发生器/监视器**当流量源，**这一轮不写我们的 MAC**。

| # | 交付 | 状态 |
|---|---|---|
| 1 | **2 通道工程**（新目录 `xxv_loop/`，照 `xxv_probe/tcl/` 的模式写 s1/s2/s3 + run_*.bat） | ✅ 见 §3、§4 |
| 2 | **流量源** = 官方 `pcs64_pkt_gen_mon`（原文引用，sha256 记录） | ✅ 见 §2.2 |
| 3 | **构建**：综合 → 实现 → 位流，−1 时序 + 资源 + GT 回读对账 | ✅ 见 §4 |
| 4 | **板级读数**：链路起立 / 零错正证据 / 负对照 / `LOS` | ✅ 见 §5（**全部拿到**） |
| 5 | 本报告 | ✅ 本文件 |

### 1.1 相对侦察探针的两个**实质工程改动**

| # | 侦察（`xxv_probe/pcs64`） | 本轮（`xxv_loop/pcs64_2ch`） | 为什么 |
|---|---|---|---|
| A | `CONFIG.NUM_OF_CORES = 1`，`LANE2_GT_LOC = NA`，通道只有 **X0Y4** | **`NUM_OF_CORES = 2`**、`LANE1=X0Y4`、`LANE2=X0Y5` | 1 通道核**只有 SFP A 的收发**；而 AOC 把 J7 与 J8 连起来 ⇒ 要"ch0 发 / ch1 收"就必须有 X0Y5 的接收器。**这是闸 1 的硬前置**（`P7B_SPEC.md` §5.1 前置） |
| B | 无流量源（探针只验"能不能出位流"） | 例化官方 `pcs64_pkt_gen_mon`，**发生器绑 X0Y4 TX、监视器绑 X0Y5 RX** | 见 §2.2 |

**A 的副产品（回答 `P7B_SPEC.md` §11 U1）**：2 通道下端口表**全部成对出现**：`_0` = X0Y4（SFP A/J7），
`_1` = X0Y5（SFP B/J8）；共享端口只有 `sys_reset` / `dclk` / `gt_refclk_p,n` / `gt_refclk_out` /
`qpllreset_in_0`（**只有 `_0`，是 common 级的**）。端口表全文归档在 `xxv_loop/artifacts/pcs64_2ch.veo:58-157`。

---

## 2. 拓扑（画清楚：谁发、谁收、控制脚各接什么）

```
        XCKU5P (xcku5p-ffvb676-1-e)                    底板 SFP 笼
   ┌──────────────────────────────────────────┐
   │  xxv_ethernet 5.0  CORE = PCS/PMA 64-bit   │
   │  NUM_OF_CORES = 2   BASE-R   10 Gbps       │
   │  GTY quad 225,  参考钟 156.25 MHz (V7/V6)  │
   │                                            │
   │  ┌── channel 0 = GTY X0Y4 = SFP A = J7 ──┐ │
   │  │  TX ◀── 官方图案发生器  ┐              │ │      ┌──────────┐
   │  │  RX ──▶ 观测(checker0) │              │ │      │  J7 (A)  │
   │  └────────────────────────┼──────────────┘ │      └────┬─────┘
   │                           │                │           │  AOC
   │  ┌── channel 1 = GTY X0Y5 = SFP B = J8 ──┐ │           │ (板内自环)
   │  │  TX ◀── 常数 IDLE 流 (/I/ 全 lane)    │ │      ┌────┴─────┐
   │  │  RX ──▶ 官方监视器 + 观测(checker1) ──┘ │      │  J8 (B)  │
   │  └────────────────────────────────────────┘      └──────────┘
   │                                             │
   │  官方 FSM 的 completion_status 判的**就是这个方向**：
   │      X0Y4 发出 ──光纤──▶ X0Y5 收到
   └──────────────────────────────────────────────┘
   控制脚（**实测映射**，厂商两份 XDC 都错）：
     sfp1_tx_dis = C11 → 常低（= SFP A 发射开）
     sfp2_tx_dis = D9  → 常低（= SFP B 发射开）
     sfp1_rx_los = B11（输入，PULLUP）
     sfp2_rx_los = C9 （输入，PULLUP）
   两个 TX_DIS 只由 VIO 抬（负对照用）。
```

### 2.1 一个方向的"两次独立读数"

| 方向 | 谁发 | 谁收 | 观测手段 |
|---|---|---|---|
| **判据方向** | ch0（X0Y4）官方图案发生器 | ch1（X0Y5）官方监视器 | 官方 `completion_status` + 我自己的 `xgmii_rx_chk` |
| **反向（附加）** | ch1（X0Y5）常数 IDLE 流 | ch0（X0Y4）我的 `xgmii_rx_chk` | ch0 的 `block_lock/status/…` + 我自己的 checker + **`/E/` 计数** |

反向那条**不是凑数**：它给 `LOS`/`/E/` 一个"本方向健康时恒 0"的对照面，并且在负对照里当**独立证人**（§5.8）。

### 2.2 流量源：**官方 example 的模块**（闸 1 那次构建：未改一行；后续构建：参数化副本 —— 见下）

- 文件：`_proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v`
  （**明文**，145846 B，sha256 `2782d688b5ea4e676be4e984735f759d9c7be7d6ebd6a2a0ac93f095ab0e03e6`）
- ⚠️ **"不复制、不改"只对闸 1 这一次验收构建成立**（2026-09-30 订正）：
  **闸 1 的板级读数对应的就是出厂原件、未改一行** —— `logs/s2_build_FINAL.txt:251` 综合的是厂商路径那份，
  位流 sha256 `5560375b…72ee2c` 即出自那次构建（§4.1 / §8 登记值）；
  **后续构建用的是参数化副本** `xxv_loop/rtl/pcs64_pkt_gen_mon_ds.v`（`S2_STAGE = round2` 起：
  `logs/s2_build_stdout.txt:274` 综合的是副本；现役 `.xpr` 也只挂副本）。
  **副本与原件在 CRC 参数行（`CRC_POLYNOMIAL` / `init_crc`）上逐字节一致**（对这两行 `diff` 空输出）；
  实质差异只有 `pay_sel` 一条支路（`data_select = {1'b0, pay_sel}`，`pay_sel=0` 即原件行为）+ 模块改名
  （其余 ~4,758 行差异是原件 LF / 副本 CRLF 的行尾差 —— `diff -w` 后只剩 16 行）。
  ⚠️ 日志里的 `S2_COPY_DIFF_LINES = 0` **不能当"逐字节相同"的证据**：
  它是 `if {[catch {exec diff …} dout]} { set dout "" }` 的**假零**（真实 `diff` 有 4,758 行差异）。
- 图案（从该文件自己的字面量推出来，**不是猜的**）：`preamble = 64'hFB_55_55_55_55_55_55_D5`、
  `dest_addr = 48'hFF_FF_FF_FF_FF_FF`、`source_addr = 48'h14_FE_B5_DD_9A_82`、`length_type = 16'h0600`；
  `data_select = 2'b0` ⇒ **载荷是全 0**（不是 PRBS）；`insert_crc = 1'b0` ⇒ **不插 FCS**；
  `FIXED_PACKET_LENGTH = 256`（我显式传参，与 example 默认一致）。
- 判据：`completion_status[4:0]`（`pcs64_example_fsm`）——
  **`==1`（SUCCESSFUL_COMPLETION）要求：`tx_done=1`、`tx_sent_count==rx_packet_count`、
  `tx_total_bytes==rx_total_bytes`、错误计数为 0，且 `NO_DATA_SENT` 分支保证"全 0 的真空结果"
  不会被当成通过**。
- 监视器的错误计数在模块内部（不引出），因此**我另加了一个独立的 XGMII 内容检查器**（§2.3）。

### 2.3 与官方 example 的**唯一**接线改动（以及为什么它仍然成立）

官方 `pcs64_exdes.v` 把发生器与监视器**接在同一个通道上**，环回在 testbench 里用
`gt_rxp_in_0 = gt_txp_out_0` 合上——那验的是"自洽"，不是一条真实链路。
本轮**同一个模块只例化一次**，两端绑到**不同通道**（`rtl/xxv_loop_top.v` 的 `u_tgm`）：

| 模块端口 | 接到 |
|---|---|
| `gen_clk` / `tx_mii_d,c` / `stat_tx_local_fault` / `user_tx_reset` | **channel 0**（X0Y4 = 发射端） |
| `mon_clk` / `rx_mii_d,c` / `stat_rx_*` / `user_rx_reset` | **channel 1**（X0Y5 = 接收端） |

**判断"改对了"的依据**（两条，都独立于我的实现）：

1. 模块内部 `i_pcs64_TRAF_CHK2` 的"已发计数"**仍然挂在 `tx_clk`（= `tx_mii_clk_0`）上数 X0Y4 发出去的东西**，
   监视器**仍然挂在 `mon_clk`（= `rx_clk_out_1`）上数 X0Y5 收到的东西**
   ⇒ FSM 的等式判据字面意思就是"SFP A 发出去的，SFP B 全都收到了"；
2. **板上实测**：`c1_frames = 20`（= 发生器参数 `PKT_NUM`），且起帧字
   `c1_sword = 0xD5555555555555FB`（= `/S/` 在 lane0 + `55×6` + `D5`，与 `swapn` 语义逐位一致）
   ⇒ 发生器在 X0Y4、监视器在 X0Y5、字节序方向都对。见 §5.3。

### 2.4 我加的**独立** XGMII 内容检查器（`rtl/xgmii_rx_chk.v`）

官方监视器的"零错"判据面只有 **帧数/字节数守恒 + `/E/`（0xFE）扫描**，**不比对载荷内容**。
我另加了一个 word 粒度的检查器（每通道一个），它给出：

| 输出 | 语义 | 失败模式判别 |
|---|---|---|
| `o_words` | 自由跑 XGMII 字数 | **速率正证据**（×64 bit = 线速） |
| `o_frames` | 收到 `/T/` 的次数 | 帧数正证据 |
| `o_ctrl_words` | 含任一控制字符的字数 | **控制块真的在收**的正证据 |
| `o_idle_words` | 纯 `/I/` 字数 | 帧间空隙符合预期 |
| `o_e_words` | 含 `/E/` 的字数 | **零误码的最强判据面**（见 §5.8 的负对照） |
| `o_pay_words` / `o_bad_pay` | 载荷区字数 / 其中非 0 的字数 | **分母必须非 0**（防真空 0） |
| `o_bad_start` / `o_bad_hdr` | 起帧字 / 两个头字与**期望常量**不符的帧数 | 期望常量取自厂商 RTL 字面量（`rtl/xgmii_rx_chk.v` 头注释） |
| `o_bad_term` / `o_bad_len` / `o_abort` | `/T/` 不在 lane0 / 数据字数不符 / 帧内出现 idle 字 | |

**判据全等 ⇒ 逐字（word-by-word）通过；只有"起帧字全错"才是 lane 旋转/字节序问题**（可区分）。

---

## 3. IP 配置逐项（回读为准，不信 `set_property` 的即时回读）

### 3.1 顶层 8+3 项（不动点迭代，第 2 轮收敛）

| 参数 | 值 | 证据 |
|---|---|---|
| `CORE` | `Ethernet PCS/PMA 64-bit` | `artifacts/…veo` / xci |
| `LINE_RATE` | 10 | `logs/s1_prepare_stdout.txt:142`（`#2 MISMATCH_N = 0`） |
| `CLOCKING` | `Asynchronous` | 同上 |
| `BASE_R_KR` | `BASE-R` | 同上 |
| `GT_REF_CLK_FREQ` | 156.25 | 同上 |
| `GT_TYPE` | `GTY` | 同上 |
| `INCLUDE_SHARED_LOGIC` | 1 | 同上 |
| `GT_GROUP_SELECT` | `Quad_X0Y1` | 同上 |
| **`NUM_OF_CORES`** | **2** | `logs/s1_prepare_stdout.txt:138` |
| **`LANE1_GT_LOC` / `LANE2_GT_LOC`** | **X0Y4 / X0Y5** | `logs/s1_prepare_stdout.txt:140` |
| 迭代 | 第 1 轮 `MISMATCH_N = 5`（`NUM_OF_CORES=1`、`LANE2=NA`、`LINE_RATE=25`、`BASE_KR`、`161.1328125`）⇒ 第 2 轮 `= 0` | `:128` / `:142` |
| 生成后回读 | `S1_POSTGEN_MISMATCH_N = 0` | `:282` |
| `IS_LOCKED` | 0（license 在位，未加密锁死） | `:81` |
| `USED_LICENSE_KEYS` | `xxv_eth_mac_pcs@2025.05` / `xxv_eth_basekr` / `xxv_tsn_802d1cm`（均 design_linking） | `:266` |

### 3.2 GT 子核回读（**逐项与 `build_p7a.tcl` 的 `gt_10gbr` 基准对账**）

板级已验收基准 = `_proj_10g/tcl/build_p7a.tcl:76-107` 的 `gt_10gbr`（BER 上界 4.997×10⁻¹³）。
本轮回读 = 两个子核 `.xci`（**每个通道一个**：`ip_0/…_gt.xci` = X0Y4，`ip_1/…_gt_1.xci` = X0Y5）：

| 参数 | 本轮（PCS 核内 GT，ip_0 / ip_1） | `gt_10gbr`（板级已验收） | 一致？ |
|---|---|---|---|
| `CHANNEL_ENABLE` | `X0Y4` / **`X0Y5`** | `X0Y4 X0Y5` | ✅（分布在两个子核里） |
| `TX/RX_LINE_RATE` | 10.3125 / 10.3125 | 10.3125 | ✅ |
| `TX/RX_INT_DATA_WIDTH` | 64 / 64 | 64 | ✅ |
| `TX/RX_USER_DATA_WIDTH` | 64 / 64 | 64 | ✅ |
| `TX/RX_BUFFER_MODE` | 1 / 1 | 1 | ✅ |
| `TX/RX_PLL_TYPE` | QPLL0 / QPLL0 | QPLL0 | ✅ |
| `TX/RX_REFCLK_FREQUENCY` | 156.25 / 156.25 | 156.25 | ✅ |
| `TX/RX_REFCLK_SOURCE` | `X0Y4 clk0` / `X0Y5 clk0` | `X0Y4 clk0 X0Y5 clk0` | ✅ |
| `TX/RX_OUTCLK_SOURCE` | `TXPROGDIVCLK` / `RXPROGDIVCLK` | 同 | ✅ |
| `TXPROGDIV_FREQ_VAL` | 156.25 | 156.25 | ✅ |
| `RX_TERMINATION` | `PROGRAMMABLE` / 800 | 未显式设 | ⚠️ 差异（**未做 A/B**，见 §7） |
| `INS_LOSS_NYQ` | 30 | 未显式设 | ⚠️ 差异（同上） |
| **`FREERUN_FREQUENCY`** | **100.00** | **156.25** | ❌ **唯一实质差异 —— 见下** |
| `LOCATE_COMMON`（子核属性字面值） | `EXAMPLE_DESIGN` | `CORE` | ⚠️ 语义未核实（与侦察同一现象） |
| 器件实际用法 | **GTYE4_COMMON = 1，GTYE4_CHANNEL = 2** | —— | ✅ 一个 quad 一个 common，正确 |

证据：`xxv_loop/artifacts/ip_0_pcs64_gt.xci`（`:16` CHANNEL_ENABLE、`:32/:42` LINE_RATE、`:33/:43` PLL、
`:34/:44` REFCLK_FREQ、`:36/:37/:46/:47` DATA_WIDTH、`:38/:48` BUFFER_MODE、`:40/:53` OUTCLK_SOURCE、
`:56/:57` TERMINATION、`:159/:160` REFCLK_SOURCE、`:186` FREERUN_FREQUENCY）；`artifacts/ip_1_pcs64_gt_1.xci`
同（`:16` = X0Y5、`:159/:160` = `X0Y5 clk0`）；用量 `pcs64_2ch.runs/impl_1/xxv_loop_top_utilization_placed.rpt:185,186`。

#### ⭐ `FREERUN_FREQUENCY` 专项（用户点名的高危项）—— 逐条核对结论

| 核对项（`P7B_SPEC.md` §3.6 要求） | 期望 | 本轮实测 | 结论 |
|---|---|---|---|
| ① `dclk` 的 OOC 约束周期 | `10.000` ns | `artifacts/pcs64_ooc.xdc:76` = `create_clock -period 10.000 [get_ports dclk]` | ✅ 与 100 MHz 一致 |
| ② 我们送给 `dclk` 的**实际**频率 | 100.000 MHz ±1% | **电路上根本没有"送 156.25 给 dclk"这件事**：`sys_clk_p/n`（Y1 = 100 MHz 差分晶振）→ IBUFDS → BUFG → `dclk`（`rtl/xxv_loop_top.v` 顶部）。频率的**量级证据**：见 §5.6 的 `Δ` 比值（`f_rx/f_dclk = 1.56249`，标称 1.5625）与**墙钟对照**（−1.0%，落在 JTAG 读数开销的量级内） | ✅（±1% 级） |
| ③ 子核回读值 | 与 ② 一致 | `100.00` | ✅ 一致 |

⇒ **本轮没有把 156.25 MHz 喂给 `dclk`**（那正是 `P7B_SPEC.md` §3.6 要避免的）。
`FREERUN_FREQUENCY = 100.00` 是与"`dclk` = 100 MHz"**自洽**的，路径风险按 §3.6 的要求排除。
⚠️ 但"`FREERUN_FREQUENCY` 到底由谁派生"本身**仍是推断**（GT 内部加密），本轮的证据只到
"①=②=③ 三者自洽"这一层，**没有**证明 GT 内部真的用了 dclk 那个 100 MHz。

### 3.3 时钟（IP 自带 OOC XDC 原文，逐条）

| 端口 | 周期 | 证据 |
|---|---|---|
| `rx_core_clk_0` | 6.40 ns | `artifacts/pcs64_ooc.xdc:71` |
| `rx_core_clk_1` | 6.40 ns | `artifacts/pcs64_ooc.xdc:73`（**2 通道新增的**） |
| `dclk` | 10.000 ns | `artifacts/pcs64_ooc.xdc:76` |
| `gt_refclk_p` | 6.400 ns | `artifacts/pcs64_ooc.xdc:80`（+ 顶层 `synth/pcs64.xdc:65`，被我的 XDC 同名替换） |

实现后时钟树（`pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt:163-172`）：
`gtrefclk0` 6.400/156.25 → `qpll0clk_in[0]` 0.194/5156.25 → **`rxoutclk_out[0]` / `rxoutclk_out[0]_1` /
`txoutclk_out[0]` / `txoutclk_out[0]_1` 各自 6.400/156.25**、`txoutclkpcs_out[0][_1]` 6.206/161.133；
`dclk` 10.000/100.0（+ 调试核的 `USE_DIVIDER.dclk_mmcm`）。
⚠️ `rxoutclk` 是 **CDR 恢复**时钟，Vivado 却把它当同源——所以我在 impl-only XDC 里显式声明
`set_clock_groups -asynchronous`（见 §4.4），实测 **Inter Clock Table 里两域之间的端点被全部移除**。

---

## 4. 构建读数（构建 + 位流）

### 4.1 位流

| 项 | 值 | 证据 |
|---|---|---|
| 结果 | `write_bitstream Complete!` / `0 Errors` | `logs/s2_build_FINAL.txt:1853`（`S2_VERDICT = PASS_BITSTREAM`） |
| 文件 | `xxv_loop/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_loop_top.bit` | `:1847`（15,431,263 B） |
| **sha256** | **`5560375b05850387b482e869e2734166db72631846d982339a2e1ec38b72ee2c`** | `:1848` |
| `.ltx` 探针文件 | `…/impl_1/xxv_loop_top.ltx`（VIO 探针名/位偏移的来源） | `logs/s3_probe_FINAL.txt:30`（`exists=1`） |
| `[Vivado 12-1790]` | 未在本轮日志里出现（侦察时 PCS 变体有；**它不是判据**） | grep 0 命中 |
| `[Common 17-69] … not permitted` | **0 命中**（这是唯一真正的失败判据） | `S2_GREP <not permitted> = 0` |

### 4.2 −1 速度等级的时序（`Performance_ExtraTimingOpt`，与 P6a/P7a 基线同策略）

| 指标 | 值 | 说明 |
|---|---|---|
| **WNS** | **+1.404 ns** | 6.400 ns 周期上 ≈ 22% 余量 |
| **WHS** | **+0.011 ns** | ⚠️ **薄**（与 P6a `+0.012`、侦察 `+0.019`、P7a 同性质；`P7B_SPEC.md` R1） |
| **WPWS** | **+0.514 ns** | |
| setup 失败端点 / 总端点 | **0 / 25,110** | |
| hold 失败端点 / 总端点 | **0 / 25,094** | |
| pulse-width 失败端点 | **0 / 15,670** | |
| 结论行 | `All user specified timing constraints are met.` | |

证据：`pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt:151-154`；
`logs/s2_build_FINAL.txt:1791,1793`（`S2_WNS = 1.404` / `S2_WHS = 0.011`）。

### 4.3 资源

| 资源 | 用量 | 占比 | 证据 |
|---|---|---|---|
| CLB LUTs | 7,942 | 3.66% | `xxv_loop_top_utilization_placed.rpt` |
| CLB Registers | 15,419 | 3.55% | 同 |
| Block RAM Tile / URAM / DSP | **0 / 0 / 0** | 0% | 同 |
| Bonded IOB | 10 | 3.57% | 同 |
| **GTYE4_CHANNEL** | **2**（X0Y4、X0Y5） | 12.5% | `:185` |
| **GTYE4_COMMON** | **1** | 25% | `:186`（一个 quad 一个 common ✅） |
| MMCM / BUFGCE | 1 / 3 | | MMCM 是调试核的 clk divider，**不是** GT 的（HDIO/GT 都不需要） |

（`P7B_SPEC.md` §6.1 A9 的期望是"PCS-only ≈ 2.2k LUT / 3k FF / 0 BRAM / GTY=2"；本设计多出来的是
**官方图案发生器/监视器 + 两个 checker + VIO（34 个 32 位探针）**，量级仍然极轻。）

### 4.4 硬门（日志 grep，逐条 0 命中）

| 检查 | 命中 | 含义 |
|---|---|---|
| `implicitly declared` | **0** | 无隐式 1 位线（工程坑 24） |
| `Opt 31-155` / `Opt 31-67` | **0 / 0** | 无 driverless net（侦察坑 1 的形态） |
| `Route 35-54` / `Route 35-7` | **0 / 0** | 无不可布引脚（侦察坑 2 的形态） |
| `AVAL-326` | **0** | 本轮 2 通道核的 IP XDC 把 IBUFDS_GTE4 定住了 ⇒ 侦察坑 3 **不再出现** |
| `NSTD-1` / `UCIO-1` | **0 / 0** | 所有端口有 LOC/IOSTANDARD |
| `12-4739` | **0** | **impl-only XDC 的 `set_clock_groups` 没有被静默丢弃** |
| `multiple driver` | **0** | |

证据：`logs/s2_build_FINAL.txt:1714,1726`（synth/impl 两份 runme.log 各一次全量统计）。
**约束生效的正面证据**：`logs/s2_build_FINAL.txt:1806,1808` 打印了两组时钟内容
（`dclk`+`USE_DIVIDER.dclk_mmcm` vs `gtrefclk0` 及其 9 个派生时钟，**不重叠**），
且 `timing_summary_routed.rpt` 的 **Inter Clock Table 里两组之间一个端点都没有**。

### 4.5 观测通道：VIO over JTAG（`P7B_SPEC.md` §10 的五个坑，逐条踩过）

- **坑 1（`.ltx` 必须关联）**：`s3_probe.tcl` 先 `set_property PROBES.FILE/FULL_PROBES.FILE` 再 `program`；
  实测 `get_hw_probes` 返回 **40 个探针**（34 `probe_in` + 6 `probe_out`），不是空表。
- **坑 2（探针名 = RTL 网名）**：`probe_in0..33` 的名字是 `oi00..oi33`；
  ⚠️ **输出探针被 OBUF 改名**：`cmd_sfp1_tx_dis`/`cmd_sfp2_tx_dis` 实际叫
  **`sfp1_tx_dis_OBUF` / `sfp2_tx_dis_OBUF`**（`logs/s3_probe_FINAL.txt:85`）。
  这条是本轮新踩的坑：按 RTL 网名找不到，**症状是脚本报 "probe not found" 而 VIO 明明在**。
- **坑 4（`INPUT_VALUE` 是 HEX 字符串）**：`vget` 按 `INPUT_VALUE_RADIX` 转换。
- **坑 5（`OUTPUT_VALUE` 要补位宽）**：1 位探针 ≥1 字符。
- **脉冲型控制自己加边沿检测**：RTL 侧把 `cmd_restart`/`cmd_sysreset`/`cmd_snap` 的**上升沿**
  换成定长脉冲 / 翻转（`rtl/xxv_loop_top.v` 的 `restart_cnt` / `sysrst_cnt` / `snap_req_tgl`）。
- ⭐ **大数不用 `format`**：`logs/s3_probe_FINAL.txt:38` 实测 `format %d 3000000000 = -1294967296`
  （**32 位截断，正是用户点名的那个坑**）；`expr` 正常（`:35` 打印 `1<<40 = 1099511627776`）。
  ⇒ 本报告里所有大数都是**字符串插值**出来的。

---

## 5. 板级读数（**逐字，带文件 + 行号**）

- 位流 sha256（本次烧的）：`5560375b…72ee2c`（`logs/s3_probe_FINAL.txt:28`）
- 烧录：`S3_PROGRAMMED 1`（`:79`）—— **JTAG 易失烧录，未碰 QSPI**
- 备用日志：`logs/s3_probe_FINAL.txt`（= 定稿那次的 stdout 全量，含 Tcl 源码回显行）

### 5.0 取数纪律的自证（每轮读数前必发快照）

14 次快照请求，每次都打 `S3_SNAP_GEN before=N after=N+1 delta=1`（首条 `:248`）⇒ **每次读数都是
新快照后的值，不存在"拿一个值和它自己比"**。快照机制的正确性有**两条独立证据**：
① `Δc1_words == Δrx1_free`（`:329` 与 `:328`）——同一个 rx1 域里"检查器数的字"与"自由计数"
在 6.6 s 窗口内**恰好相等**（1,021,907,221）⇒ 保持寄存器确实被刷新了；
② 快照值随时间单调增长且与 `Δdclk` 一致（§5.6）。

### 5.1 链路起立（**双向都起**）

```
# logs/s3_probe_FINAL.txt
250:S3_ST ch0 bits(15..0)=1100000000000111 gtpg=1 blocklock=1 status=1 hiber=0 rlocalfault=0 framing=0 badcode=0 errvalid=0 fifoerr=0 txlocalfault=0 los=0
254:S3_ST ch1 bits(15..0)=0000000000000111 gtpg=1 blocklock=1 status=1 hiber=0 rlocalfault=0 framing=0 badcode=0 errvalid=0 fifoerr=0 txlocalfault=0 los=0
```

| 判据（`P7B_SPEC.md` §6.1 C 组） | ch0 = X0Y4（收 ch1 的 IDLE 流） | ch1 = X0Y5（收 ch0 的帧流） |
|---|---|---|
| C1 `gtpowergood` = 1 | **1** | **1** |
| C2 `stat_rx_block_lock` = 1 | **1** | **1** |
| C3 `stat_rx_status` = 1 | **1** | **1** |
| C4 `stat_rx_hi_ber` = 0 | **0** | **0** |
| C5 `rx_local_fault`/`tx_local_fault` = 0 | **0 / 0** | **0 / 0** |
| C6 `stat_rx_framing_err` = 0 | **0**（且 8 位计数器 `ferr0` 终场 = 0） | **0**（`ferr1` = 0） |
| C7 `bad_code`/`rx_error…`/`fifo_error` = 0 | `bcd0` = 0、`ffe0` = 0（`rx_error` 见 §5.11 的缺口） | `bcd1` = 0、`ffe1` = 0 |
| C8 `stat_rx_valid_ctrl_code` | 8 位计数器**饱和在 255**（`:555` 的 `CNT0 = 4278779648` → 0xFF000000） | 同上（`CNT1` 同） |
| `sfp1_rx_los`（B11）/ `sfp2_rx_los`（C9） | **0**（模块在位、有光） | **0** |
| 原始 HEX（st0/st1，可逐位复核） | `000dc007` / `00000007`（`:252`） | 同 |

⚠️ **`valid_ctrl_code` 的 8 位计数器饱和后只能当"≥255 次"用**；**精确的控制块证据**用我自己的
计数（`c1_ctrl` / `c0_ctrl`）：ch0 方向在 6.6 s 窗口内 **Δc0_ctrl = +1,021,907,221**（`:340`，
且与 `Δc0_words` 逐数相等 ⇒ 该方向 100% 是控制字 = `/I/`）；判据方向 `c1_ctrl` 跨三次快照单调增长
**216,213,831 → 439,403,531 → 683,242,759**（`:260` → `:277` → `:393`）⇒ **非 0 且持续增长** ✅。

### 5.2 官方 FSM 的第一次判决（**上电后自带的那一轮**）

```
256:S3_COMPLETION_STATUS_STEP1 14
277:S3_STEP2_C1 words 439404151 frames 20 ctrl 439403531 e 81 pay 580 badpay 0 badstart 0 badhdr 0 badterm 0 badlen 0 abort 0
281:S3_STEP2_C0 words 439404151 ctrl 439404151 idle 439403554 e 0 frames 0
```

- **`completion_status = 14`（`LBUS_PROTOCOL`）**，不是 1。原因**不是链路错**：FSM 的
  `rx_errors` 是**粘滞**的（`rx_error_count` 一旦非 0 就保持 ⇒ 见 §5.4 的 81 个 `/E/`），
  而这 81 个 `/E/` 落在"**上电 → 首轮判据**"这一段里（我的 `/E/` 计数器只被 `user_rx_reset_1` 清，
  所以它们就在这段窗口内；**具体时刻未归因**，见 §7 U3）。长窗（restart 之后）Δ`/E/` = 0
  ⇒ 它们**不是稳态行为**，但确实污染了首轮那个粘滞判据。
  **证据**：`S3_STEP2_ERRW hex 0 acc0 0 nv0 0 acc1 0 nv1 0`（`:287`）—— `stat_rx_error` 从未有效。
- 同时这一轮给出了**内容判据全绿**：`badpay = badstart = badhdr = badterm = badlen = abort = 0`，
  `frames = 20`（**恰好等于发生器的 `PKT_NUM`**），`frames`/`pay` 的比值 = 580/20 = **29.0**（见 §5.5）。
- ch0 方向：`ctrl == words`（**100% 的字都是控制字**，正是 `/I/` 全 lane），`e = 0`，`frames = 0` ✅

### 5.3 字节序/lane 落位（`P7B_SPEC.md` §3.3 的高危点，**板级直接读出来**）

```
549:S3_FINAL_SWORD hi 3579139413 lo 1431655931     (同一值在 :260 的首轮读数里也是这对)
```

`c1_sword = {hi, lo} = 0xD5555555_555555FB` —— 即
**lane7..lane0 = `D5 55 55 55 55 55 55 FB`**，**`/S/(0xFB)` 落在 lane0**，
`55×6` 在后、`D5` 在 lane7 ⇒ 与厂商 `swapn` 的语义（lane0 = 帧内首字节）**逐位一致**。

> ⚠️ **判别力声明（照抄 `P7B_SPEC.md` §3.3）**：本方向是"官方发 → 官方收"，**对称**，
> 所以这条**不能**裁定绝对字节序。它证明的是"**这一轮的数据确实以官方约定的 lane 布局到达**"，
> 即"我们这一轮没有引入任何 lane 旋转"。真正的非对称裁决仍然要等闸 1c / 闸 2。

### 5.4 起动瞬态的 `/E/`（一个必须说清的现象）

| 观测 | 值 | 出处 |
|---|---|---|
| 上电到首轮判据之间，ch1 收到的 `/E/` 字数 | **81** | `:260`（`e 81`） |
| 其中在**判据方向**长窗内新增的 | **0**（Δ = 0） | `:332` |
| ch0（纯 IDLE 方向）在**健康期**的 `/E/` | **0** | `:281`（`c0_e = 0`） |
| ch0 在**被负对照打断**（SFP2 TX_DIS 拉高 2 s）后的 `/E/` | **11,808** | `:553` |

⇒ 三条一起读：**`/E/` 计数不是真空 0**——链路被故意打断时它立刻涨（11,808），
健康长窗里它一动不动（Δ = 0）。那 81 个落在"上电 → 首轮判据"的窗口里（`user_rx_reset_1` 之后、`restart` 之前），
**具体时刻没有归因干净** —— 这是本轮唯一没归因干净的读数（见 §7 U3）。

### 5.5 长窗零错（**本轮的第二个核心产出**）

长窗：`send_cont=1` + `restart` 重新武装 ⇒ 连续流 **6.6 s**（墙钟 `:347`），
窗口两端的快照（`:303`/`:316`）与逐项 Δ（`:326-343`）：

```
330:S3_LONG_DELTA c1_frames 30056095
332:S3_LONG_DELTA c1_e 0
335:S3_LONG_DELTA c1_badpay 0        （badstart/badhdr/badterm/badlen/abort 同为 0，:333-338）
342:S3_LONG_DELTA c0_e 0            （另一方向的 /E/ 也是 0）
329:S3_LONG_DELTA c1_words 1021907221
```

| 判据 | 期望来源 | 实测 | 结论 |
|---|---|---|---|
| **帧数（正证据）** | `o_frames` 非 0 且与线速自洽 | **30,056,095 帧**（`:330`）/ 6.5402 s = **4,595,563 帧/s**；墙钟独立口径 4,547,752/s（`:378`，−1.04%，见 §5.6） | ✅ **非真空** |
| **`/E/` 增量** | 恒 0 | **Δ = 0**（1,021,907,221 个字里一个都没有） | ✅ |
| **内容失配** | `bad_start/bad_hdr/bad_pay/bad_term/bad_len` 恒 0 | **全 0** | ✅ |
| **载荷分母（防真空 0）** | `pay_words` 必须非 0 | `Δc1_pay = 871,626,746`（`:331`） | ✅ |
| **载荷字数/帧（自算：wpos 3..31 ⇒ 29）** | 29.000 | **28.9999997** | ✅ |
| **XGMII 字数/包周期（自算：33 帧字 + 1 空闲字 = 34）** | 34.000 | **33.9999997** | ✅ |
| **线速** | 156.25 M 字/s × 64 bit = **10.000 Gbps** | **9,999.94 Mbps**（`:361`） | ✅ −0.0006% |

### 5.6 三个新时钟域的频率（`P7B_SPEC.md` §6.1 C9）

时间基 = **同一次快照**里锁存的 `dclk_snap`（`:345`），窗口 6.6 s（< 20 s，避开 32 位回绕）：

```
356:S3_LONG_FREQ rx1_free mhz 156.2491362227605
     （tx0_free / rx0_free 同一行值：156.2491362227605）
```

| 域 | 实测（相对 `dclk`） | 标称 | 偏差 |
|---|---|---|---|
| `tx_mii_clk_0`（QPLL0 派生） | **156.24914 MHz** | 156.25 | −0.0006% |
| `rx_clk_out_0`（CDR 恢复） | **156.24914 MHz** | 156.25 | −0.0006% |
| `rx_clk_out_1`（CDR 恢复） | **156.24914 MHz** | 156.25 | −0.0006% |
| `dclk`（Y1 100 MHz → IBUFDS/BUFG） | 时间基（= 100 MHz 假定的分母） | 100 | —— |

**墙钟交叉核对**（把 `dclk` 假设成 100 MHz 后，用主机时钟反推同一段窗口）：

| 量 | 计数法（快照时间基 `Δdclk_snap` = 654,024,237 → 6.5402 s，`:344`） | 墙钟（`dt` = 6.609 s，`:347`） | 偏差 |
|---|---|---|---|
| 帧率 | 4,595,563 /s | **4,547,752 /s**（`:378`） | **−1.04%** |
| XGMII 字数率 | 156.249 MHz（`:356`） | **154.624 MHz**（`:379`） | −1.04% |

两个口径差 **1.04%**，且都落在"两次墙钟时间戳之间夹着若干次 JTAG 事务"
（`readall` 每次要读 34 个探针）的开销量级内 ⇒ **方向正确、量级自洽**，支持"`dclk` = 100 MHz ±1%"。
⚠️ 这条**不是**精密测频：它只把时间基的不确定性压到 ~1% 量级（正好是 `P7B_SPEC.md` §6.1 C9 的门槛）。
（更硬的时间基对照见 `P6B_ACCEPT.md` B2b：Y1 经 MMCM 后实测 156.2585 MHz。）

### 5.7 官方判据 `SUCCESSFUL_COMPLETION`（**用长窗重判**）

```
389:S3_STEP4_COMPLETION_STATUS 1
393:S3_STEP4_C1 words 1932165861 frames 40287842 ctrl 683242759 e 81 pay 1168347418 badpay 0
397:S3_STEP4_ERRW hex 0 acc0 0 nv0 0 acc1 0 nv1 0
401:S3_ST  ch0 … blocklock=1 status=1（余同 §5.1）
403:S3_ST  ch1 … blocklock=1 status=1（余同 §5.1）
```

**`completion_status = 1 = SUCCESSFUL_COMPLETION`** —— 这是厂商 FSM 在
"连续流约 8.5 s / 40,287,842 帧"之后给出的判决，按它自己的判据链，成立意味着：
`tx_done=1`、`tx_sent_count == rx_packet_count`、`tx_total_bytes == rx_total_bytes`、
`rx_errors == 0`（该轮从 `restart` 起算，没有瞬态污染），且 **`NO_DATA_SENT` 分支保证计数非 0**。
配合 §5.5 的独立检查器（Δ`/E/`=0、Δ内容失配=0、29/34 的几何比值）⇒ **零错是"有分母的零"**。
（`40,287,842` 是**该轮 restart 之后**的累计帧数：`restart_tx_rx` 会把厂商监视器与我的检查器一起清零
——上电自带的那 20 帧不在这个数里，见 §5.10 的 `frames = 40` 对照。）

### 5.8 负对照（三条，全部按期望翻转 —— `P7B_SPEC.md` §6.2 的 N1/N5）

#### 负对照 ①：拉高 `SFP1_TX_DIS`（C11）—— 杀掉判据方向的发射

```
413:S3_STHEX F 00042007 00000411
415:S3_ST  ch0 … blocklock=1 status=1 los=0       ← 反向不受影响
417:S3_ST  ch1 … blocklock=0 status=0 rlocalfault=1 los=1   ← 判据方向掉链 + 对端 LOS 亮
```

| 期望 | 实测 | 证明什么 |
|---|---|---|
| ch1 `block_lock = 0` | **0** | 杀发射 ⇒ 收端掉块锁（判据有牙） |
| **`sfp2_rx_los`（C9）拉高** | **1** | ⭐ **独立证人**：SFP A 的发射一关，**SFP B 的模块**报 LOS ⇒ ① 光纤拓扑（J7→J8）确实如此、② `C9 = SFP2_RX_LOS` 的**实测引脚映射**正确、③ LOS 是**活信号**不是常量 |
| ch0 不受影响 | `blocklock=1, los=0` | 两个方向确实独立 |

⚠️ 此段的 `S3_NEG1_FRAMES_DELTA_WHILE_DEAD`（`:429`，值 4,254,679,454 = **2³²−40,287,842**）
**不能按字面读**：掉链时核会拉 `user_rx_reset_1`（`S3_ST` 的 `userrxrst` 位在下一拍已回 0），
我的 checker 与厂商监视器**同拍被清 0** ⇒ 跨"掉链事件"的 Δ 是无意义的（帧计数被复位，不是"发了 42 亿帧"）。
**这一段的有效证据是电平判据**（block_lock/status/local_fault/LOS），以及下面 ② 的判决翻面。

#### 负对照 ②（**核心**）：链路黑着的时候**用同一条 `restart` 重新武装**

```
450:S3_NEG1_REARM_COMPLETION_STATUS 2       ← NO_BLOCK_LOCK
478:S3_RECOV_COMPLETION_STATUS 1            ← 恢复供电 + restart ⇒ 又回 SUCCESSFUL_COMPLETION
502:S3_STHEX L 000c2411 00000007            ← 镜像负对照（SFP2_TX_DIS）
504:S3_ST  ch0 … blocklock=0 rlocalfault=1 los=1
506:S3_ST  ch1 … blocklock=1 status=1 los=0
514:S3_NEG2_C1_WORDS_DELTA_STILL_FLOWING 578890843
516:S3_NEG2_C1_FRAMES_DELTA 0
```

- **同一条刺激（`restart`），链路健康时给 1（§5.7），链路黑着时给 2（`NO_BLOCK_LOCK`）**
  ⇒ **判据既不是恒真、也不是恒假**，它有判别力。
- 单向恢复后再 `restart` ⇒ 又回 **1**（`:478`，`RECOV`）——**可复现、可恢复**。
- 镜像负对照：拉高 `SFP2_TX_DIS`（D9）⇒ **ch0 掉块锁 + `SFP1_RX_LOS`（B11）亮**，
  而 **ch1 依旧 `blocklock=1` 且字数还在涨（+578,890,843）** ⇒ 两个方向真的独立。
  （`FRAMES_DELTA = 0` 是因为此时发生器停在 `S7`，抬 `send_cont` 电平**不会**重新武装它——
   这是我脚本的一处已知局限，不是链路问题；见 §7 U4。）

### 5.9 `LOS` 状态（用户点名）

| 状态 | 健康自环（J7↔J8 两条通道都有光） | 关 SFP A 发射 | 关 SFP B 发射 |
|---|---|---|---|
| `sfp1_rx_los`（B11） | **0**（`:250`） | 0（`:415`） | **1**（`:504`） |
| `sfp2_rx_los`（C9） | **0**（`:254`） | **1**（`:417`） | 0（`:506`） |

⇒ 自环下**两条通道的 LOS 都是 0**（模块在位、有光），并且在关掉**对端**发射时精确翻转。

### 5.10 恢复后的终态（可复现收尾）

```
539:S3_FINAL_COMPLETION_STATUS 1
547:S3_FINAL_C1 words 1372319854 frames 40 e 66 badpay 0 badstart 0 badhdr 0 badterm 0 badlen 0 abort 0 pay 1160
553:S3_FINAL_C0 words 343092822 ctrl 343092822 idle 231462623 e 11808 frames 0
555:S3_FINAL_CNT0 4278779648 CNT1 4280626944
557:S3_FINAL_ERRW hex 0 acc0 0 nv0 0 acc1 0 nv1 0
```

- `frames = 40` = **两轮 20 帧**（第一次上电自带 + 恢复后被 `restart` 触发的那次）⇒ 与厂商
  `PKT_NUM=20` 的语义完全吻合；
- 内容判据仍然**全 0**；
- ch0 的 `e = 11808` 全部来自 §5.8 的负对照窗口（见 §5.4 的解释链）。

### 5.11 ⚠️ **没闭合的一条**：`stat_rx_error[7:0]`

`nv0 = nv1 = 0`（`:397`、`:557`）——`stat_rx_error_valid_N` **整场（含两次故意打断）一次都没触发**。
⇒ 我对 `stat_rx_error[7:0]` 的**累计粘滞或**（`acc_err0/acc_err1`）恒 0，但那是**"这条线没话说"**，
不是"测到 0"（`P7B_SPEC.md` R12 的形态）。**C7 的这一条按"未测"登记**，不当 PASS 用。
（同一份 bundle 里 `bad_code` / `framing_err` / `fifo_error` 的 8 位计数器**有明确的触发机会**：
两次故意打断里 `block_lock`/`local_fault`/`LOS` 都精确翻了，而它们仍保持 0（`:555`）⇒ 这几条的
"恒 0"比 `rx_error` 那条强。⚠️ 但 8 位计数器是**饱和型**（不回绕），所以它只能证"没到 255"，
不能证"一次都没发生"——本报告不把它当精确计数用。）

---

## 6. 与 `P7B_SPEC.md` 闸 1 判据的**逐条对账**

### 6.1 §5.1 闸 1 的分条

| 闸 | 判据 | 本轮 | 结论 |
|---|---|---|---|
| **1a**（GT 内部环回） | `gt_loopback_in` 进环回 ⇒ 自发自收 + 状态位 | **未做**（本轮改走 1b/1c 的同一目的更强路线：真光纤） | 未测 |
| **1b**（板内光路 J7↔J8） | 2 通道核 + 双向跑固定时长 + 帧数守恒 + 逐字节 + `/E/` 恒 0 + `valid_ctrl_code` 涨 | **判据方向**：30,056,095 帧、Δ`/E/`=0、Δ内容失配=0、`c1_ctrl` 单调增长到 683,242,759；**反向**：Δ控制字 +1,021,907,221；**反向**：纯 IDLE 流 `block_lock=1`、`e=0`（"逐字节相等"由 §5.3 的起帧字 + 内容检查器承担，**不是**两端的同一份实现自比 ⇒ 见 §5.3 的判别力声明） | ✅ **PASS** |
| **1c**（非对称：与厂商明文 monitor 对接） | 厂商 monitor 的图案比对必须通过 | **本轮把 1c 和 1b 合成了一次实验**：官方发生器 + 官方监视器跨通道对接，`completion_status = 1`（§5.7） | ✅ **PASS**（但见 §5.3：字节序的**绝对**裁决仍待闸 2） |

### 6.2 §6.1 的 A 组（静态，16 条）

| # | 判据 | 本轮结果 |
|---|---|---|
| A1 | 8 个 `CONFIG.*` 不动点收敛 | ✅ `S1_ROUND #2 MISMATCH_N = 0`（`:142`） |
| A2 | `CHANNEL_ENABLE` 含 X0Y4 与 X0Y5 | ✅ 两个子核分别 `X0Y4`/`X0Y5`（`artifacts/ip_*.xci:16`） |
| A3 | `.veo` 端口表按新配置重读归档 | ✅ `artifacts/pcs64_2ch.veo`（sha256 在 `artifacts/SHA256SUMS.txt`） |
| A4 | GT 子核 8 项逐项相符 | ✅ §3.2（**两处差异**：`FREERUN_FREQUENCY` 见 §3.2 专项；`INS_LOSS_NYQ`/`RX_TERMINATION` 为**未做 A/B 的差异**） |
| A5 | `FREERUN_FREQUENCY` 与 `dclk` 实际频率对账 | ✅ §3.2 专项（①=②=③ 自洽；⚠️"派生关系"仍是推断） |
| A6 | OOC XDC 三个时钟周期 | ✅ `6.40`/`10.000`/`6.400`（`artifacts/pcs64_ooc.xdc:71,73,76,80`） |
| A7 | **0 失败端点** | ✅ setup/hold/pulse-width **全 0**（§4.2） |
| A8 | hold 余量记录数值 | ✅ **+0.011 ns（薄）** |
| A9 | 资源量级 + GTY 通道数 = 2 | ✅ 7,942 LUT / 15,419 FF / 0 BRAM / **GTY 2**（含流量源与 VIO；PCS 本体仍是 2.2k/3.0k 量级） |
| A10 | `AVAL-326` 允许但记录 | ✅ **本轮 0 命中**（2 通道 IP XDC 已定住 IBUFDS_GTE4） |
| A11 | `rx_reset_0/tx_reset_0/user_*_reset` 全被驱动/消费 | ✅ 日志 `Opt 31-155`/`31-67` **0 命中**；接线见 `rtl/xxv_loop_top.v`（4 个 reset 输入分别由模块输出或常数 0 驱动，`user_*_reset` 进观测 bundle） |
| A12 | `rxrecclkout`/`gt_refclk_out` **未被消费** | ✅ 声明为悬空网（不接逻辑），`Route 35-54/35-7` **0 命中** |
| A13 | `write_bitstream completed successfully` + `0 Errors` | ✅ §4.1 |
| A14 | lint：`implicitly declared` = 0 · `10-3091` = 0 | ✅ **四个 runme.log（synth_1 / impl_1 / pcs64_synth_1 / vio_0_synth_1）里 `implicit` 字样命中 0**（`logs/s2_build_FINAL.txt:1714,1726`）。⚠️ 这是**日志事实**，不能反推"设计里没有隐式网"：厂商明文模块内部有若干只写不读的 `assign`（`ctl_tx_enable`/`ctl_local_loopback`/`ctl_FEC_*`），本轮 Vivado 也没有为它们产生任何 implicit 字样。`10-3091` **未单独统计**，见 §7 的登记 |
| A15 | 无 `NSTD-1`/`UCIO-1` | ✅ 0/0；且 `get_files` 回读确认两个 XDC 都在 constrs_1（`logs/s2_build_FINAL.txt` 的 `S2_CONSTR` 两行） |
| A16 | 位流 sha256 + 大小 + 指纹 | ✅ `5560375b…72ee2c` / 15,431,263 B（§4.1）；**本轮没有 `BUILD_ID` 概念**（那是 PCIe 快照窗口的东西，本设计不用它） |

### 6.3 §6.1 的 C 组（PCS/链路，9 条）

| # | 判据 | 本轮结果 |
|---|---|---|
| C1 | `gtpowergood = 1` | ✅ 两通道 |
| C2 | `block_lock = 1` | ✅ 两通道（健康期） |
| C3 | `rx_status = 1` | ✅ 两通道 |
| C4 | `hi_ber = 0` | ✅ 两通道（⚠️ 按规范不当零误码证据） |
| C5 | `rx_local_fault`/`tx_local_fault` = 0 | ✅ 健康期 0；负对照时 `rx_local_fault` 精确翻 1（§5.8）⇒ **是活线** |
| C6 | `framing_err` 恒 0 | ✅（电平 + 8 位计数器均 0） |
| C7 | `bad_code`/`rx_error[7:0]`/`fifo_error` 恒 0 | ⚠️ **部分**：`bad_code`、`fifo_error` = 0（有机会触发而仍 0）；**`rx_error[7:0]` 的 `_valid` 从未触发 ⇒ 按"未测"登记**（§5.11） |
| C8 | `valid_ctrl_code` **持续增长** | ✅ 精确计数：ch0 方向 **Δc0_ctrl = +1,021,907,221**（`:340`）；`c1_ctrl` 跨快照 216,213,831 → 683,242,759（`:260`→`:393`）；核自己的 `vcc` 计数器两通道都饱和（≥255，`:555`） |
| C9 | 三个新域自由计数 Δ/墙钟 = 标称 ±1% | ✅ `156.24914 MHz`（相对同一快照的 `dclk`，`:356`），墙钟独立口径 −1.04%（§5.6） |

### 6.4 §6.2 的负对照

| # | 负对照 | 期望 | 本轮 |
|---|---|---|---|
| N1 | `TX_DIS` 强拉高 | 链路全黑 | ✅ **按期望 FAIL**（两向各做一次；且对端 `LOS` 精确响应，§5.8） |
| N5 | 环回断开 | 闸 1 判据 FAIL | ✅ **用 `TX_DIS` 代替拔线**：`completion_status` 由 1 → **2**，恢复后回 1 |
| N8 | 状态线钉常量 | 判据 FAIL | ⚠️ **未做**（需要仿真或改 RTL；本轮以"负对照期间电平确实翻转"作为弱替代） |

### 6.5 与**用户任务书**四条交付的对照

| 用户要求 | 结果 |
|---|---|
| 1. 两个方向各自的 `block_lock/hi_ber/local_fault/status/framing_err/rx_error[7:0]` | ✅ 全部读到（`rx_error[7:0]` 见 §5.11 的登记）；**每通道一份**，逐位在 `S3_STHEX` 行 |
| 2. 零错证据 + **正证据** | ✅ 30,056,095 帧 / Δ`/E/`=0 / Δ内容失配=0 / 载荷 871,626,746 字的分母 / 线速 9,999.94 Mbps（§5.5） |
| 3. 负对照（≥1 条） | ✅ **三条**：SFP1_TX_DIS（判据翻面 1→2→1）、SFP2_TX_DIS（方向独立性 + 另一侧 LOS）、以及 `/E/` 计数在打断时 0→11,808 的**判别力**证明（§5.4/§5.8） |
| 4. `LOS` 状态 | ✅ 自环下 0/0；关对端发射时各自精确翻 1（§5.9） |

---

## 7. 未核实清单（**严禁当结论用**）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| U1 | **`FREERUN_FREQUENCY` 的派生路径** | 只有"①OOC 周期=10.000 ②我们给 dclk 的是 Y1 的 100 MHz ③回读 100.00"三者自洽；**GT 内部加密，看不到** | 读 GT 生成的 `.v` 端口连接，或 placer 时钟报告；本轮**没有**做 |
| U2 | **`dclk` 的绝对频率**（精度） | 只到 ±1%（墙钟对照）；分频器/晶振本身没量 | 用板外频率计或 P7a 那种长窗对照（P6b 的 156.2585 MHz 是同类证据） |
| U3 | ⭐ **起动瞬态 81 个 `/E/` 的机理** | 只在"上电/RX 重锁"窗口出现（长窗 Δ=0）；**未归因** | 加 ILA/mark_debug 抓 RX 侧头 100 µs；或把 `user_rx_reset` 与首帧的时刻关系测出来 |
| U4 | `restart_tx_rx` 与 `send_continuous_pkts` 的**组合语义** | 实测：发生器停在 `S7` 后，**单抬 `send_cont` 电平不会重新武装**（§5.8 的 `FRAMES_DELTA = 0`） | 读 `pcs64_mii_pkt_gen` 的 `S7`/`q_en` 退出条件（**已读**：`S7: state <= |q_en ? S7 : S0`，即必须让 `q_en` 掉一次）；本轮脚本按"先 restart 再 stream"规避 |
| U5 | `stat_rx_error[7:0]` 与 `_valid` 的**触发条件** | **整场未触发**（§5.11）⇒ 该状态线无观测面 | 需要仿真（官方 example 的 tb）或人为造坏码才能在板上看到 |
| U6 | `INS_LOSS_NYQ=30` / `RX_TERMINATION=PROGRAMMABLE 800` 与 `gt_10gbr` 的差异对 BER 的影响 | 只回读到值，**未做 A/B** | 要贴官方工作点再做（`P7B_SPEC.md` X10） |
| U7 | `align_status` 单独观测 | 不是端口（★ `P7B_SPEC.md` §11 U2）⇒ 本轮**没测** | mark_debug / ILA |
| U8 | 官方核的**内部统计计数**（`tx_sent_count`/`rx_total_bytes` 的**数值**） | 它们**不引出**；只能靠 `completion_status==1` 反推"相等且非 0" | 若要看数值，需要改官方明文模块（**本轮纪律不允许**）或在核外加等价计数 |
| U9 | 帧的**绝对长度**（我最初从厂商 RTL 数成 33 个数据字 + 1 个终止字 = 34 字；实测是 32 + 1 = 33 字） | 已由板级实测钉死（pay/frame = 29.0、words/frame = 34.0，±3×10⁻⁷）；**我最初从厂商 RTL 推导时数错了 1 个字**（`rtl/xgmii_rx_chk.v` 的 `LAST_DW` 曾写 33，实测后改 32） | 若要逐字节复核，需在仿真里跑官方 example |
| U10 | **`/E/` 之外的数据完整性** | 载荷是**全 0**（厂商 `data_select=0`）⇒ 检查器只能证明"全 0 且长度对"，**证明不了"任意图案不错"** | 闸 1c/闸 2 用带图案的流量源（或自写 MAC 时换图案） |
| U11 | **长时间稳定性（soak）** | 最长一次连续流 6.6 s（30 M 帧） | 按 `P7A_RESULT.md` §7 的口径加长 |
| U12 | `10-3091`（拼接位宽不匹配）计数 | **本轮没有单独统计**（`S2_GREP` 的关键字表里没有它） | 在 `s2_build.tcl` 的 `keys` 里加一条即可 |
| U13 | 厂商明文模块里只写不读的 `assign`（`ctl_tx_enable`/`ctl_local_loopback`/`ctl_FEC_*`） | Vivado 本轮**没有**为它们报警（四个 runme.log 的 `implicit` 命中均为 0）；为何不报**未核实** | 不必补：它们不在我们的判据面上 |

---

## 8. 证据索引（文件 + 行号）

| 内容 | 位置 |
|---|---|
| 2 通道门面（端口表全文） | `xxv_loop/artifacts/pcs64_2ch.veo:58-157`（sha256 见 `artifacts/SHA256SUMS.txt`） |
| GT 子核回读（X0Y4 / X0Y5） | `xxv_loop/artifacts/ip_0_pcs64_gt.xci:16,32-57,159,160,186`；`artifacts/ip_1_pcs64_gt_1.xci` 同 |
| IP 的 OOC 三个时钟 + 通道 LOC | `xxv_loop/artifacts/pcs64_ooc.xdc:71,73,76,80`；`artifacts/ip_0_pcs64_gt.xdc:57`（`LOC GTYE4_CHANNEL_X0Y4`）、`artifacts/ip_1_pcs64_gt_1.xdc:57`（X0Y5） |
| 配置不动点收敛 | `xxv_loop/logs/s1_prepare_stdout.txt:128,138,140,142,144,282` |
| 构建/时序/位流/grep | `xxv_loop/logs/s2_build_FINAL.txt:163,1714,1726,1791,1793,1806,1808,1847,1848,1853` |
| 路由后时序表（−1） | `xxv_loop/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_loop_top_timing_summary_routed.rpt:151-154,163-172` |
| 资源（含 GTY 2 / COMMON 1） | `…/impl_1/xxv_loop_top_utilization_placed.rpt:185,186` |
| **板级读数（定稿那一次的全量 stdout）** | `xxv_loop/logs/s3_probe_FINAL.txt`（sha256 `:28`、探针表 `:85`、快照自证 `:248`、链路 `:250,254`、首轮 `:256,277,281`、长窗 `:303,316,326-343,361,369,377,378`、判据 `:389-403`、负对照 `:413-456`、镜像负对照 `:502-524`、终态 `:539-557`、Tcl 大数坑 `:38`） |
| 板级脚本（可重跑） | `xxv_loop/tcl/s3_probe.tcl` + `tcl/run_s3.bat`（重烧 + 快照协议 + 负对照 + 恢复） |
| 构建脚本 | `xxv_loop/tcl/s1_prepare.tcl`（建工程 + 2 通道配置 + 端口表归档）、`tcl/s2_build.tcl`（RTL/XDC/VIO + 全流程 + 硬门 grep） |
| RTL（本仓自写，`xxv_loop/rtl/`） | `xxv_loop_top.v`（顶层/接线/VIO 打包）、`xgmii_rx_chk.v`（独立内容检查器）、`obs_util.v`（`cdc_sync2`/`snap_hold`/`obs_reg`） |
| 约束 | `xxv_loop/xdc/xxv_loop.xdc`（引脚 + 时钟）、`xxv_loop/xdc/xxv_loop_impl.xdc`（`set_clock_groups -asynchronous` + 调试核频率） |
| **厂商明文流量源（未改一行）** | `_proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v`（145846 B，sha256 `2782d688…b0e03e6`） |
| 板级已验收的 GT 基准（对账右列） | `_proj_10g/tcl/build_p7a.tcl:76-107` |

---

## 9. 本轮**没有**做的事（边界声明）

- ❌ **没有写我们的 MAC**（用户明确要求这一轮不做）；本设计里唯一的自写 RTL 是**观测**用的
  内容检查器与 VIO 快照件，**不在数据通路上**（它们只读 XGMII 的观测副本）。
- ❌ 没有动厂商的任何文件；`pcs64_pkt_gen_mon.v` 按**绝对路径引用**，sha256 已记录。
- ❌ 没有改既有工程/文档；没有 git 写操作；没有碰 QSPI；没有动 license。
- ❌ 没有做 GT 内部环回（1a）与 `stat_*` 钉常量的负对照（N8）。

---
---

# 第二轮补充（2026-09-29 晚）—— 闭合自报缺口 + 给 64 位 XGMII MAC 的接口合同

> 本节是**追加**，不重写第 1 部分。第 1 部分里被本轮实测**订正**的结论集中在 §10.14。
> 本轮新增位流：sha256 **`2acafb1f4c48c2ff22fcf78ce6fca079f5c3aae98695a49a8206427c7b767f0a`**，
> `WNS +1.870 / WHS +0.006`，`write_bitstream Complete!`（`logs/s2d_run_output.txt`）。
> 板级两个会话：`logs/s7_probe2_FINAL.txt`（48 探针全量）与 `logs/s11_probe3_FINAL.txt`（环回 + 60 s 频率）。

## 10.1 A1——**闸 1a（GT 内部环回）已补测，PASS**

做法：把 `gt_loopback_in_0`（通道 0 的 GT 环回选择）接到 VIO 输出 `vio_gt_loopback[2:0]`，
发生器开着连续流，逐档切换模式，看**通道 0 自己的接收器**是否收到"自己发的帧"（判据 = 我自己的
`xgmii_rx_chk` 在 ch0 上的 `c0_frames` 增长 + 内容判据全 0）。

```
# logs/s11_probe3_FINAL.txt（每档先读 t0、2 s 后再读，差值为窗口内增量）
153:S11_A mode=0 t0: ch0 blk=1 status=1 los=0 frames=0 …            ← 000 = 无环回（负对照基线）
155:S11_A mode=0 WIN: d_c0_frames 0 …                              ← 负对照：不发不收
157:S11_A mode=1 t0: ch0 blk=1 status=1 los=0 frames=4055525 e=9 e_pre0=9 sw_lo=1431655931
159:S11_A mode=1 WIN: d_c0_frames 17572669 d_c0_e 0 d_c1_frames 17572669 d_c1_e 0
163:S11_A mode=2 WIN: d_c0_frames 11945493 …
167:S11_A mode=4 WIN: d_c0_frames 0 …
171:S11_A mode=6 WIN: d_c0_frames 0 …
183:S11_A_RESTORED ch0 blk=1 c0_frames=43716385 c1_frames=128401099
```

| 模式 `gt_loopback_in_0[2:0]` | 窗口内 ch0 收到的帧 | 窗口内 ch1 收到的帧 | 结论 |
|---|---|---|---|
| `000`（无环回，**负对照**） | **0** | 12,316,524 | 判据**不是恒真** ✅ |
| `001` | **17,572,669** | **17,572,669** | ✅ **PASS** |
| `010` | **11,945,493** | 11,945,493 | ✅ **PASS** |
| `100` | 0 | 11,969,325 | ❌ 不成立 |
| `110` | 0 | 11,935,831 | ❌ 不成立 |
| `000`（再关，负对照） | **0** | 11,942,156 | ✅ 判据可重复 |

- **闸 1a 判据成立**：模式 `001`/`010` 下 ch0 收到自己发的帧，且
  **内容判据全 0**（`d_c0_e = 0`，起帧字低 32 位 `sw_lo = 0x555555FB` = 期望常量 `W_START` 的低半 ✓）。
- ⭐ **两个方向的计数逐数相等**（17,572,669 == 17,572,669）——环回把 TX 数据复制给 ch0 的 RX，
  **同时光纤仍把同一份数据送到 ch1** ⇒ 两个接收器同步推进。这条**独立佐证**了环回确实在
  "发端数据"那一点接入，而不是别的地方。
- **负对照（`P7B_SPEC.md` §5.1a 要求"关掉环回必须 FAIL"）**：`000` 三次窗口都是 0 帧 ✓。
- ⚠️ **U6 仍未核实**：我只知道**哪些**编码可用（001/010），**不知道它们的语义**
  （PCS 级/PMA 级、环路点在哪）——本地没有 UG578。若要精确，需查文档或做更细的 A/B。

## 10.2 A2——起动瞬态 `/E/` 的归因（**能给的都给了；机理仍未确证**）

新仪器：`xgmii_rx_chk` 的 `/E/` 计数按"**是否已收到过第一帧**"分成两桶
（`o_e_pre` / `o_e_post`，`rtl/xgmii_rx_chk.v`）。

| 观测 | 值 | 出处 |
|---|---|---|
| ch0（纯 IDLE 方向）本轮的 `/E/` 总数 | **9** | `:157`（`e=9 e_pre0=9`） |
| 其中"**首帧之前**"的 | **9**（= 全部） | 同上：`e_pre0 == e_total` |
| ch0 在环回窗口内的 `/E/` 增量 | **0**（共 6 个窗口） | `:159,163,167,171` 的 `d_c0_e` |
| ch1（判据方向）本轮上电后的 `/E/` 总数 | **199** | `:132` |
| **各次上电的同一读数** | **0**（第三轮 s7 会话）、**9**（ch0，s11）、**47 / 81**（第一轮） | `logs/s7_probe2_FINAL.txt:170`（`e=0`）等 |

⇒ **归因**：所有测到的 `/E/` 都落在 **"上电 → 首帧被收到"** 这个窗口里（ch0 是**严格等于**：
`e_pre0 == e_total`），**且次数不可复现**（0 / 9 / 47 / 81 / 199 五次上电）⇒ 它是**接收链锁定瞬态的
产物，不是链路质量的指示**。
**排除掉的**（有证据）：① 稳态行为（所有健康长窗 Δ`/E/` = 0，本轮 1.41 G 个 rx 周期零增量，`:332` 系）；
② 物理链路质量（同一块板、同一根 AOC，重锁之后 30 M 帧零 `/E/`）；
③ "必然发生"（第三轮 s7 会话 `c1_e` 全程 **0**，`:170`）。
**没有确证的**：到底是环回 FIFO 的时钟校正、`align_status` 未建立期间的解码、还是别的路径产生的 `/E/`
——需要 ILA/`mark_debug` 抓 RX 侧头 100 µs（未做）。
⚠️ **给下一轮的工程结论**：`/E/` 计数**必须在块锁建立之后再开始计**（或块锁建立时清零），
否则厂商那种"粘滞错误位"会把起动瞬态记成链路错误——**第一轮的 `completion_status = 14` 就是这么来的**
（`P7B_GATE1.md` §5.2）。

## 10.3 A3——`dclk` 绝对频率：比值精度提到 6×10⁻⁶，绝对值锚定仍是 ~1%

方法改进：五个快照、**墙钟时间戳紧贴快照之后**（不是读完 48 个探针之后）、
32 位计数器**显式展开回绕**（每次变小 = 一次 wrap），窗口 63.8 s。

```
# logs/s11_probe3_FINAL.txt
214:S11_B k=0 wall_ms=1790687310344 dclk_snap=3422831317 rx1_free=1051476058 tot_d=0 tot_r=0
218:S11_B k=4 wall_ms=1790687373576 dclk_snap=1155131428 rx1_free=2339977741 tot_d=6322234703 tot_r=9878436275 wraps_d=2 wraps_r=2
222:S11_B_WALL_SECONDS 63.767 TOT_D 6322234703 TOT_R 9878436275
224:S11_B_RX_OVER_DCLK 1.5624912296141942
226:S11_B_DCLK_MHZ_IF_RX_IS_156250000 100.00056130784222
230:S11_B_DCLK_MHZ_FROM_WALLCLOCK 99.14587016795521
```

| 量 | 读数 | 精度/含义 |
|---|---|---|
| `f(rx1)/f(dclk)`（**同一次快照锁存**，回绕已展开） | **1.5624912296** | 标称 1.5625 ⇒ **−6×10⁻⁶**；这是**比值**的精度 |
| 若 `dclk` = 100.000 MHz（Y1 晶振，P6b 交叉印证 +5 ppm） | `f(rx1)` = **156.2491 MHz** | ⇒ 线速 9,999.94 Mbps |
| 只用我自己的墙钟（63.767 s）反推 `dclk` | 99.146 MHz（**−0.85%**） | ⚠️ 与上面**差 0.85%**，未消解 |

⚠️ **诚实结论**：**比值**已经是 6×10⁻⁶ 级（两个计数器由同一次请求锁存，窗口 63.8 s、展开 2 次回绕）；
**绝对刻度**只到 **±0.85%**——我的墙钟口径自己与"Y1 = 100 MHz"这条硬件事实差 0.85%，
差异来源未定位（最可能是 JTAG commit/读数在时间戳两侧的系统性偏移），**列为未核实**。
⇒ 因此"`dclk` = 100 MHz ±1%"这条（§5.6 / §6.3 C9）**维持不变**，只是比值那一半从 ±1% 提到了 6×10⁻⁶。
**对下游 CDC 余量估算的含义**：下一轮 MAC 的两个跨界点（DP↔TX-MII、RX↔DP）要用到的量是
**频率比**；本设计里 TX 与 RX 两个 156.25 MHz 都来自**同一个 QPLL0** ⇒ 本地比值 = 1（实测 6×10⁻⁶ 内）。
但这**不能**当成"余量足够"：与**第三方对端**对接时 10GBASE-R 允许每端 ±100 ppm ⇒ 跨界结构仍必须按
**±200 ppm** 设计（`P7B_SPEC.md` §3.4 的硬规则不变）。本读数只排除了"本地时钟标称值有 1% 级错误"。

## 10.4 A4——非平凡载荷：**已跑通**（0xFFFFFFFF 载荷，10,033,916 帧零失配）；并揭出一个真缺陷

官方 example 的载荷在 as-instantiated 下是**全 0**（`assign data_select = 2'b0`，硬编码，无运行时开关）。
本轮做了**参数化副本** `rtl/pcs64_pkt_gen_mon_ds.v`（与厂商原文的**完整 diff 只有 6 处**，见下），
把 `data_select` 接成 `{1'b0, pay_sel}`，`pay_sel` 由 VIO 选 **0x00 / 0xFF** 两档载荷。

```
# logs/s7_probe2_FINAL.txt
294:S7_S5_WIN frames=10033916 paywords=290983586 badpay=0
296:S7_S5_PAYWORDS_PER_FRAME 29.000002192563702 (expect 29.0)
302:S7_S5_CS 1 (0x1F = never ran, 2 = no block lock, 1 = SUCCESSFUL)
321:S7_S6_CS 1
```

| 载荷档 | 判据 | 实测 | 结论 |
|---|---|---|---|
| **全 1（0xFFFFFFFF）** | `o_bad_pay`（与全 1 不符的载荷字数）恒 0 | **0 / 290,983,586 字 / 10,033,916 帧** | ✅ **逐字通过** |
| 同上 | 头字判据 `o_bad_hdr`（含 word2 的两个载荷 lane） | **0** | ✅ |
| 同上 | 载荷字数/帧 | **29.000002** | ✅ 几何不变 |
| 同上 | 官方 FSM 判决 | `completion_status = 1` | ✅ |
| 回切全 0 | `badpay/badstart/badhdr` | **全 0**（`:321` 的 S7_S6 行） | ✅ 可逆 |

⚠️ **本轮揭出的真缺陷（值得单列）**：第一次参数化时我漏了**中间层** `pcs64_mii_traffic_gen_mon`
的端口声明 ⇒ 那一层的 `pay_sel` 成了**隐式 1 位线（悬空）** ⇒ 发生器侧的 `data_select` 恒为常量、
**载荷根本没换**（板上表现为：`pay_sel=1` 时"每一个载荷字都失配"，而 `pay_sel=0` 时零失配）。
- **发现手段 = 仿真**：`sim/tb_pay_sel.v` 直接探 `pkt_gen` 内部，读到 `data_select = 2'b0z`
  （悬空）与 `d_sel = 0z` ⇒ `case` 落到 `default` 分支 ⇒ 载荷走 PRBS。**5 分钟定位**（板上查这个要几轮）。
- **更值得记的是门漏了它**：Vivado 2025.2 对隐式网打的是
  `INFO: [Synth 8-11241] undeclared symbol 'pay_sel', assumed default net type 'wire'`
  —— 而我的硬门关键字是 **"implicitly declared"**（本仓旧措辞）⇒ **门报 0，设计里却真有一个隐式网**。
  这正是本工程最忌讳的"真空门"形态。**已修**（`tcl/s2_build.tcl` 的门现在同时匹配
  `8-11241` / `undeclared symbol` / `does not have driver` / `unconnected or has no load`）；
  修好后重跑：`pay_sel` 相关消息 **0 命中**，剩下 10 条 `undeclared symbol` **全部来自厂商文件自身**
  （`ctl_tx_enable`/`clear_count`/`rx_mii_clk`/`stat_rx_status` 等，写多读少），我的 RTL 贡献 0。

**副本 vs 厂商原文的完整 diff（6 处，逐处必要）**：模块改名 `pcs64_pkt_gen_mon_ds`；顶层加
`input pay_sel`；顶层向 traffic_gen_mon 传 `.pay_sel`；traffic_gen_mon 加 `input pay_sel`（**这一处第一次漏了**）；
traffic_gen_mon 向 pkt_gen 传 `.pay_sel`；pkt_gen 加 `input pay_sel` 并把
`assign data_select = 2'b0` 改成 `{1'b0, pay_sel}`。⇒ **`pay_sel = 0` 时与厂商行为逐位相同**
（已由板上"全 0 载荷 30 M 帧零失配"与第一轮读数一致佐证）。

## 10.5 A1b——C7 复闭合：framing/bad_code/fifo 现在是**精确 0**；`rx_error` 仍未测

新仪器：**同一组 `stat_*` 信号在 dclk 与 ch1 恢复域各计一遍**（32 位、不回绕、不清零；
`rtl/xxv_loop_top.v` 的 `s_*_d`/`s_*_r`），读数在 `in36..in47`。

```
# logs/s7_probe2_FINAL.txt（8.79 s 窗口；`:225/:226` 是本行里的两个域计数）
225:S7_S3_D vcc_d 885011279
226:S7_S3_D vcc_r 1412908411
227:S7_S3_D ferr_d 0        228:S7_S3_D ferr_r 0
229:S7_S3_D bcd_d 0         230:S7_S3_D bcd_r 0
231:S7_S3_D ffe_d 0         232:S7_S3_D ffe_r 0
233:S7_S3_D errv_r 0
238:S7_S3_DD 904266410
```

| 判据（§6.1 C6/C7） | 观测周期数 | dclk 域 | ch1 恢复域 | 结论 |
|---|---|---|---|---|
| `stat_rx_framing_err`（+`_valid`） | 0.90 G dclk + 1.41 G rx | **0** | **0** | ✅ **精确 0**（不回绕计数器，任一脉冲都会被记到） |
| `stat_rx_bad_code`（+`_valid`） | 同上 | **0** | **0** | ✅ 精确 0 |
| `stat_rx_fifo_error` | 同上 | **0** | **0** | ✅ 精确 0 |
| `stat_rx_error_valid` | 同上 | —（未在 dclk 计） | **0** | ⚠️ **仍未触发** ⇒ `stat_rx_error[7:0]` 依旧是"没话说"，**C7 这一条按未测登记** |
| `stat_rx_valid_ctrl_code` | 同上 | 885,011,279 | 1,412,908,411 | ⚠️ **它是电平不是脉冲**（见下） |

⭐ **顺带纠正一个语义**：`stat_rx_valid_ctrl_code` 在两个域里都**几乎每拍为 1**
（rx 域计数 1,412,908,411 ≈ Δrx 时钟数 1,412,908,411 **逐数相等**）⇒ 它是
**"当前收块是合法控制块"的电平**，不是"每收到一个控制码脉冲一次"。
⇒ 第 1 部分 §5.1 里"`valid_ctrl_code` 8 位计数器饱和 ⇒ 非 0 且持续增长"要**改口径**：
它是**电平**，只能当"链路活着时该状态线为高"用；**"控制块真的在收"的精确证据仍然是
我自己的 `c1_ctrl`/`c0_ctrl`**（§5.1 那段的后半句）✓。
**对下一轮的忠告**：`valid_ctrl_code` **不能计事件数**（会等于时钟数）；要么当电平采，要么不用。

## 10.6 B 节——六个接口未知项的直接答案（全部出自**本周期的工程与生成物**）

### B1（= `P7B_SPEC.md` U1）端口 `_0`/`_1` 的语义：**是通道索引**，2 通道时两套齐全

`artifacts/pcs64_2ch.veo:58-157`（本次生成的实例化模板，逐行可核）+ 我工程的例化：
`tx_mii_d_0[63:0]`/`rx_mii_d_0[63:0]` 与 `tx_mii_d_1[63:0]`/`rx_mii_d_1[63:0]`
是**两个独立通道**（`_0` = X0Y4 = SFP A = J7；`_1` = X0Y5 = SFP B = J8）。
**不是位宽拼接**。共享端口**只有一个副本、且不带 `_1`**：`sys_reset` / `dclk` /
`gt_refclk_p,n` / `gt_refclk_out` / `qpllreset_in_0`。
每通道各自一套的：`gt_rxp/rxn_in_N`、`gt_txp/txn_out_N`、`tx_mii_clk_N`、`tx_mii_d/c_N`、
`rx_clk_out_N`、`rx_core_clk_N`、`rx_mii_d/c_N`、`gtpowergood_out_N`、`rxrecclkout_N`、
`rx_reset_N`/`tx_reset_N`、`user_rx_reset_N`/`user_tx_reset_N`、全套 `stat_*_N`、
`ctl_tx_*_N`、`ctl_rx_*_N`、`txoutclksel_in_N`/`rxoutclksel_in_N`、
`gtwiz_reset_{tx,rx}_datapath_N`、`gt_loopback_in_N`、`ctl_rx_wdt_disable_N`。
**证据等级**：`.veo` 明文 + 我工程里 48 个探针在 2 通道上的**实测差异**（两个方向的计数独立推进）。
⚠️ 通道**号**与**球号**的对应由核内 XDC 的 LOC 决定：`artifacts/ip_0_pcs64_gt.xdc:57` =
`LOC GTYE4_CHANNEL_X0Y4`，`artifacts/ip_1_pcs64_gt_1.xdc:57` = `X0Y5`。

### B2（= U4）`sys_reset` 配方：**我给的就是这段，逐行抄回**

`rtl/xxv_loop_top.v:110-137`（**顶层自己产生**，与厂商 example 把 `sys_reset` 当外部输入一致）：

```verilog
    reg [19:0] por_cnt = 20'd0;                 // :110
    wire       por_n   = &por_cnt;              // :111
    always @(posedge dclk) if (!por_n) por_cnt <= por_cnt + 20'd1;   // :112  ~10.5 ms POR

    reg  cmd_restart_d = 1'b0;                  // :122
    reg  cmd_sysrst_d  = 1'b0;                  // :123
    reg [15:0] restart_cnt = 16'd0;             // :124  ~10 us
    reg [19:0] sysrst_cnt  = 20'd0;             // :125  ~10 ms
    always @(posedge dclk) begin                // :127
        cmd_restart_d <= vio_cmd_restart;       // :128
        if (vio_cmd_restart && !cmd_restart_d) restart_cnt <= 16'd1000;   // :129 边沿→脉冲
        else if (restart_cnt != 16'd0)         restart_cnt <= restart_cnt - 16'd1;
        cmd_sysrst_d <= vio_cmd_sysreset;       // :132
        if (vio_cmd_sysreset && !cmd_sysrst_d) sysrst_cnt <= 20'hFFFFF;
        else if (sysrst_cnt != 20'd0)          sysrst_cnt <= sysrst_cnt - 20'd1;
    end
    wire sys_reset     = ~por_n | (sysrst_cnt != 20'd0);   // :136 高有效
    wire restart_tx_rx = (restart_cnt != 16'd0);           // :137
```

- **极性/语义**：`sys_reset` **高有效**；`restart_tx_rx` 是**用户级重启**（它进厂商模块，
  `mii_reset = user_*_reset | restart_tx_rx`，会清发生器/监视器计数并让 FSM 重跑）。
- **`gtpowergood`/QPLL lock/tx,rx active 的先后**：**不在用户侧**——核只有 `sys_reset` 一个总复位入口，
  `gtpowergood_out_N` 只是**状态输出**（我接进观测）；GT 的复位序列（powergood → QPLL lock →
  tx/rx resetdone）由**核内 reset controller** 自己走（`INCLUDE_SHARED_LOGIC=1`）。
  **实测证据**：POR 释放后 ~10.5 ms 内两个通道都起（第一轮 §5.1），
  且 FSM 的 45 ms 起始窗内块锁已建立（θ `completion_status=1`）。
- **厂商 example 的对照**：`pcs64_exdes_tb.v` 在仿真里把 `sys_reset` 拉高 20 个 dclk 后释放
  （我这里是 2²⁰ 个 dclk，因为板上还要等 GT/PLL）。
- ⚠️ **未核实**：`sys_reset` 的**最小宽度**要求（我只知道 10.5 ms 一定够）。

### B3（= U9/U10）`user_*_reset` 与 `rx,tx_reset_N` 的**域与语义**（网表实证）

用路由后网表读**同步器目的端的 FDRE 时钟脚**（`tcl/s8_rst_clk.tcl`，只读）：

```
# logs/s8_rst_stdout.txt
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_tx_resetdone_0/s_out_d2_cdc_to_reg REF=FDRE CLK=txoutclk_out[0]
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_tx_resetdone_1/s_out_d2_cdc_to_reg REF=FDRE CLK=txoutclk_out[0]_1
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_rx_resetdone_0/s_out_d2_cdc_to_reg REF=FDRE CLK=rxoutclk_out[0]
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_rx_resetdone_1/s_out_d2_cdc_to_reg REF=FDRE CLK=rxoutclk_out[0]_1
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_rxreset_1/s_out_d2_cdc_to_reg       REF=FDRE CLK=rxoutclk_out[0]_1
S8_USER user_tx_reset_0 DUT/inst/i_pcs64_core_cdc_sync_gt_tx_resetdone_0/user_tx_reset_0_INST_0 REF=LUT1 SEQ=0
S8_USER user_tx_reset_1 DUT/inst/…tx_resetdone_1/user_tx_reset_1_INST_0 REF=LUT1 SEQ=0
S8_STATSYNC DUT/inst/i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_1/s_out_d2_cdc_to_reg CLK=dclk
```

| 信号 | 方向 | **域（实证）** | 语义 | 能不能硬接 0 |
|---|---|---|---|---|
| `user_rx_reset_N` | **out** | **`rx_core_clk_N` = `rxoutclk_out[0]_N`**（由 `..._gt_rx_resetdone_N` / `..._gt_rxreset_N` 这两个 CDC 的目的域产生） | 核告诉用户"RX 数据通路刚复位/正在复位" | —— （是输出；**应当消费**：我把它当 chk_N 的同步复位 + 进观测 bundle。悬空会让核内读它的 LUT 悬空，侦察坑 1 实测 `opt_design` 直接失败） |
| `user_tx_reset_N` | **out** | **`tx_mii_clk_N` = `txoutclk_out[0]_N`**（由 `..._gt_tx_resetdone_N` 产生） | 同上，TX 侧 | —— |
| `rx_reset_N` | **in** | 用户侧请求（核内被 `..._gt_rx_resetdone_N`/`rxreset_N` 那块逻辑读） | "用户请求复位核的 RX 数据通路"【推定】 | **能，而且我就是这么接的**：`ch0` 的 `rx_reset_0` = 常数 `1'b0`（`:assign rx_reset_0 = 1'b0;`），`ch1` 的 `rx_reset_1` = 厂商模块的常数 0 输出 |
| `tx_reset_N` | **in** | 同上（TX 侧） | 同上 | **能**：`tx_reset_0` = 厂商模块输出的常数 0；`tx_reset_1` = 常数 `1'b0` |

⚠️ **给下一轮的用法**：**要用 `user_rx_reset_N` 当自写 MAC 的 RX 复位源**（它天然在 RX 域、
且会把 MAC 的 FSM 和核内状态对齐）；**绝不要**在用户侧"造"复位去猜核的时序。
`rx_reset_N`/`tx_reset_N` 只在你**故意**要重启核数据通路时用；默认 0。

### B4（= U8）`stat_*` 的时钟域：**block_lock 实证 = dclk；其余"域未确证"，但给出了打法**

```
# logs/s8_rst_stdout.txt
S8_STATSYNC DUT/inst/i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_0/s_out_d2_cdc_to_reg CLK=dclk
S8_STATSYNC DUT/inst/i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_1/s_out_d3_reg     CLK=dclk
```

| 状态 | 域 | 依据 |
|---|---|---|
| **`stat_rx_block_lock_N`** | **dclk** ✅ | 核内名为 `i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_N` 的四级同步器，**目的端 FDRE 的时钟脚 = `dclk`**（网表实证） |
| `stat_rx_status` / `hi_ber` / `local_fault` / `framing_err(_valid)` / `bad_code(_valid)` / `error[7:0](_valid)` / `fifo_error` / `valid_ctrl_code` / `tx_local_fault` | **未确证**（核内加密，网表里查不到生产者；`tcl/s6_stat_cells.tcl` 的 `ncells=0`） | 双域计数实验**没能判别**它们（见下） |

**为什么没判别出来**（如实登记）：判别需要一个**脉冲**信号——rx 域 6.4 ns 脉冲会被 dclk 采样漏掉约 1/3，
dclk 域 10 ns 脉冲则两个域都 100% 收到。但本轮窗口里**这些信号一个脉冲都没有**
（framing/bad_code/fifo/error_valid 全 0，见 §10.5），而唯一非零的 `valid_ctrl_code` 是**电平**
⇒ 电平在两个域里都"每拍为 1"，比值只会告诉你时钟比（实测 1.596 ≈ 1.5625，被实时读的偏斜抬高），
**判别不了域**。
**给下一轮的可操作结论**（不依赖"域确证"）：
1. **`block_lock` 可以直接在 dclk 采**（实证）；
2. 其余状态位**一律按"可能异步"处理**：每位一个 2FF 同步器（电平）/ 或**快照+握手**（多比特如 `rx_error[7:0]`），
   **绝不做多比特直接两级同步**（`P7B_SPEC.md` §3.2 硬规则）；
3. **`valid_ctrl_code` 按电平采**，不要计事件（§10.5 的语义纠正）；
4. 想**真的**确证域：造一个已知脉冲源（例如故意在链路里打一个坏块）再跑同一条双域计数实验——
   本轮没做。
**实测反证"按 dclk 采它们不会出事"**：第一轮 30 M 帧 + 本轮 41.5 M 帧的健康窗口里，
这些信号在 dclk 域的读数与我在 rx 域的独立检查器（`c1_*`）**处处自洽**，没有出现位混值/抖动。

### B5（`FREERUN_FREQUENCY = 100.00`）它对运行**无影响**；**顶层不可改**

- **对运行无影响（实测）**：链路正常、块锁 = 1、`completion_status = 1`，
  线速 **9,999.94 Mbps**（§5.5/§5.6），环回/图案/负对照全部按预期 ⇒ 这个参数在**有参考钟**的
  工作模式下不参与数据通路。它是"**不依赖参考钟的自由运行**"模式（GT 用自由运行时钟来复位/校准）
  才用到的频率标称值。
- **可不可改**：**顶层 IP 上根本没有这个属性**——`tcl/s10_misc_query.tcl` 直接回读：
  ```
  S10_PROP CONFIG.GT_DRP_CLK = 100.00
  S10_TRY CONFIG.FREERUN_FREQUENCY rc=1   ← get_property 失败：属性不存在
  S10_TRY CONFIG.GT_DRP_CLK       rc=0 val=<100.00>
  S10_TRY CONFIG.GT_REF_CLK_FREQ  rc=0 val=<156.25>
  ```
  ⇒ **用户能设的是 `CONFIG.GT_DRP_CLK`（= 100.00）**，子核的 `FREERUN_FREQUENCY` 是**派生**出来的
  （它与 `dclk` 的 OOC 约束 `create_clock -period 10.000 [get_ports dclk]` 一致，§3.2 专项）。
  ⇒ 结论：**不需要也无法单独把它改成 156.25**；只要 `dclk` 真的是 100 MHz（本轮实测支持，±1%），
  它就是对的。**不要把 156.25 喂给 `dclk`**（那会让复位/DRP 定时器快 1.56×，`P7B_SPEC.md` §3.6）。

### B6（`[DRC AVAL-326]`）是什么规则；本轮 0 次是否预期

- **规则本体**（原文，来自侦察期日志，`P7B_XXV_OFFICIAL.md` §5.4 坑 3）：
  ```
  CRITICAL WARNING: [DRC AVAL-326] Hard_block_must_have_LOC: The hard block IBUFDS_GTE4 cell
  DUT/inst/IBUFDS_GTE4_GTREFCLK0_INST is missing a valid LOC constraint …
  ```
  ⇒ **规则名 `Hard_block_must_have_LOC`**：硬块（GT 相关原语）**必须有有效的 LOC 约束**。
  它在 `AVAL` 这个 DRC 族里，级别是 **Critical Warning**（实测**不拦位流**：侦察期 PCS 变体带着它
  `Bitgen Completed Successfully`）。
- **本轮 0 次**：`logs/s2_build_stdout.txt` 的 `S2_GREP <AVAL-326> = 0`（synth 与 impl 两份 runme.log），
  且 `xxv_loop_top_drc_routed.rpt` 里也 0 命中。
- **是否预期**：**现象是 0，但机理未核实**——`tcl/s10_misc_query.tcl` 查询显示**路由后网表里
  根本没有 `IBUFDS_GTE4` 这个名字的 cell**（`S10_IBUFDS_N = 0`；参考钟缓冲在核内的
  `*_common_wrapper` 里，加密区不可见）⇒ 规则"找不到 IBUFDS_GTE4"自然不报。
  为什么侦察期能看到而本轮不能，**没有查清**（可能与 1 通道 vs 2 通道下 common/IBUFDS 的层次命名有关）。
  ⚠️ 因此本报告**不把"0 次"当成"IBUFDS 有 LOC 了"**——只能说**位流生产全程没有这条告警**，
  且**两次（侦察 + 本轮）都没有拦住位流**。

## 10.7 C 节——**给 64 位 XGMII MAC 的接口合同**

### C.1 我工程实际用到的端口（名/位宽/方向/域/语义/证据）

| 端口 | 位宽 | 方向 | 时钟域 | 语义（下一轮直接用） | 证据 |
|---|---|---|---|---|---|
| `gt_refclk_p/n` | 1 | in | — | 156.25 MHz 差分参考钟（V7/V6） | `.veo:84-85`；`artifacts/pcs64_ooc.xdc:80` |
| `gt_refclk_out` | 1 | out | — | **不要消费** | `.veo:86`；侦察坑 2 |
| `dclk` | 1 | in | — | 100 MHz DRP/控制域（我喂 Y1） | `.veo:79`；`pcs64_ooc.xdc:76` |
| `sys_reset` | 1 | in | 异步 | 高有效总复位（§B2） | `.veo:78` |
| `qpllreset_in_0` | 1 | in | — | 恒 0 | `.veo:155` |
| `txoutclksel_in_N` / `rxoutclksel_in_N` | 3 | in | — | 恒 `3'b101`（厂商注释"不可改"） | `.veo:68-71` |
| `gtwiz_reset_{tx,rx}_datapath_N` | 1 | in | — | 恒 0 | `.veo:72-75` |
| `gt_loopback_in_N` | 3 | in | — | GT 环回（闸 1a 用；`001`/`010` 实测可用） | `.veo:153-154`；§10.1 |
| `ctl_rx_wdt_disable_N` | 1 | in | — | 恒 0 | `.veo:156-157` |
| `gt_rxp_in_N`/`gt_rxn_in_N` | 1 | in | — | GT 串行入（球号由通道 LOC 推导） | `.veo:58-61` |
| `gt_txp_out_N`/`gt_txn_out_N` | 1 | out | — | GT 串行出 | `.veo:62-65` |
| **`tx_mii_clk_N`** | 1 | **out** | — | **XGMII TX 时钟 = `txoutclk_out[0]{,_1}` = 156.25 MHz（实测 156.2491）** | `.veo:80-81`；`timing_summary_routed.rpt` 时钟树；§10.3 |
| **`tx_mii_d_N`** | **64** | **in** | `tx_mii_clk_N` | XGMII TX 数据，**lane0 = 帧内首字节 = `d[7:0]`** | `.veo:133-134`；§C.2 的板级反推 |
| **`tx_mii_c_N`** | **8** | **in** | `tx_mii_clk_N` | XGMII TX 控制位，**`c[l]` 对应 lane l = `d[8l+7:8l]`**（1 = 控制字符） | `.veo:135-136`；§C.3 |
| **`rx_clk_out_N`** | 1 | **out** | — | **恢复时钟 = `rxoutclk_out[0]{,_1}` = 156.25 MHz（CDR）** | `.veo:82-83`；时钟树 |
| **`rx_core_clk_N`** | 1 | **in** | — | **必须由用户供 156.25**；厂商 example 用 `rx_clk_out_N` 自环（我照做，`:156-157`） | `.veo:66-67`；`pcs64_exdes.v:98` |
| **`rx_mii_d_N`** | **64** | **out** | `rx_core_clk_N` | XGMII RX 数据，lane0 = 首字节 | `.veo:93-94` |
| **`rx_mii_c_N`** | **8** | **out** | `rx_core_clk_N` | XGMII RX 控制位 | `.veo:95-96` |
| `gtpowergood_out_N` | 1 | out | — | GT 就绪（=1） | `.veo:87-88` |
| `rxrecclkout_N` | 1 | out | — | **不要消费** | `.veo:76-77` |
| `user_rx_reset_N` / `user_tx_reset_N` | 1 | **out** | **RX / TX-MII 域**（§B3 实证） | **当自写 MAC 的复位源** | `.veo:91-92,131-132`；§B3 |
| `rx_reset_N` / `tx_reset_N` | 1 | **in** | （核内） | 默认**硬接 0**（§B3） | `.veo:89-90,129-130` |
| `stat_rx_block_lock_N` | 1 | out | **dclk**（实证） | 块锁 = 1 | `.veo:111-112`；§B4 |
| `stat_rx_status_N` | 1 | out | 未确证（按 dclk 采 + 2FF） | RX 链路健康 = 1 | `.veo:115-116` |
| `stat_rx_hi_ber_N` | 1 | out | 同上 | 高误码 = 0（**不当零误码证据**） | `.veo:117-118` |
| `stat_rx_local_fault_N` / `stat_tx_local_fault_N` | 1 | out | 同上 | = 0（对端没在发 `/Q/`） | `.veo:109-110,137-138` |
| `stat_rx_framing_err_N` + `_valid_N` | 1+1 | out | 同上 | `_valid` 限定那拍计数；**恒 0**（精确，§10.5） | `.veo:105-108` |
| `stat_rx_valid_ctrl_code_N` | 1 | out | 同上 | ⚠️ **电平**（§10.5） | `.veo:113-114` |
| `stat_rx_bad_code_N` + `_valid_N` | 1+1 | out | 同上 | **恒 0**（精确） | `.veo:119-122` |
| `stat_rx_error_N` + `_valid_N` | **8**+1 | out | 同上 | ⚠️ **`_valid` 从未触发 ⇒ 无观测面** | `.veo:123-126` |
| `stat_rx_fifo_error_N` | 1 | out | 同上 | **恒 0**（精确） | `.veo:127-128` |
| `ctl_tx_*_N`（7 根：`test_pattern`/`_enable`/`_select`/`data_pattern_select`/`seed_a[57:0]`/`seed_b[57:0]`/`prbs31_enable`） | 1/58 | in | — | 测试图案控制；**我全接常数 0** | `.veo:139-152` |
| `ctl_rx_*_N`（4 根：`test_pattern`/`data_pattern_select`/`test_pattern_enable`/`prbs31_enable`） | 1 | in | — | 同上 | `.veo:97-104` |

> ⚠️ **`tx_mii_clk_N` 的边沿关系**：核输出的是**与数据同域的时钟**，用于对 `tx_mii_d/c` 采样；
> 下一轮 MAC 里**必须**用它（或它的派生）驱动 TX 侧，**不要**用 dclk 或自造时钟。
> ⚠️ `tx_mii_clk_N` / `rx_clk_out_N` 都是核的输出 ⇒ **用户侧只能 BUFG 后使用**（我这样做，
> 时钟树里以 `txoutclk_out[0]`/`rxoutclk_out[0]_N` 出现）。

### C.2 ⭐ XGMII 字 → 我们帧流合同的**逐字节镜像表**（并用板级读数反推验证）

**两侧事实**：官方 XGMII = **lane0 首发**（`mii_d[7:0]` = 帧首字节，证据见 §5.3 与
`pcs64_pkt_gen_mon.v` 的 `swapn`）⇔ 本仓冻结合同 = **`tdata[63:56]` = 帧首字节**
（`rtl/mac_rx_64.v:2-8`）。⇒ **8 字节镜像（`bswap64`），纯连线 0 逻辑**：

| 合同位（左对齐） | ← XGMII 位（lane0 在最低位） | 帧内字节号 |
|---|---|---|
| `tdata[63:56]` | `mii_d[7:0]` | byte0（首发） |
| `tdata[55:48]` | `mii_d[15:8]` | byte1 |
| `tdata[47:40]` | `mii_d[23:16]` | byte2 |
| `tdata[39:32]` | `mii_d[31:24]` | byte3 |
| `tdata[31:24]` | `mii_d[39:32]` | byte4 |
| `tdata[23:16]` | `mii_d[47:40]` | byte5 |
| `tdata[15:8]`  | `mii_d[55:48]` | byte6 |
| `tdata[7:0]`   | `mii_d[63:56]` | byte7 |

> 一般式：`tdata[(7-l)*8 +: 8] = mii_d[l*8 +: 8]`，`l = 0..7`（TX 方向同一张表反用）。

**用板级读数反推验证（链式三步，每一步都有文件行号）**：

1. **板级捕获的起帧字**：`S3_FINAL_SWORD hi 3579139413 lo 1431655931`
   （`logs/s3_probe_FINAL.txt:549`；第三轮同值：`logs/s7_probe2_FINAL.txt` 的 `S7_S2 sword_hi/lo`）
   ⇒ 拼接得 `mii_d = 0xD5555555_555555FB`。
2. **按字节拆开**（MSB→LSB）：`D5 | 55 | 55 | 55 | 55 | 55 | 55 | FB`
   ⇒ `mii_d[7:0] = 0xFB`；`mii_d[63:56] = 0xD5`。
   而**厂商明文**说这一帧的前 8 个字节应当是 `/S/(0xFB) + 0x55×6 + D5`
   （`preamble = 64'hFB_55_55_55_55_55_55_D5` + `swapn`）⇒ **`0xFB`（首发字节）确实落在 `mii_d[7:0]`** ✓
   ⇒ 表的第一行 `tdata[63:56] ← mii_d[7:0]` 成立 ✓（即 `/S/` 会出现在我们合同的**首字节**位置）。
3. **判据全等**：我的检查器把 `mii_d == 64'hD5555555555555FB && c == 8'h01` 当作"帧首字"
   （期望常量从厂商字面量手推、**不由 DUT 生成**），在板上**40 M 帧以上全部匹配**：
   `S7_S3_D c1_badstart 0`（`logs/s7_probe2_FINAL.txt:220`，同窗口 `Δframes = 41,556,130`，`:216`）
   ⇒ **镜像表的两端（首字节位置）都被独立验证**。
   ⚠️ 判别力声明（§5.3 同）：本方向是"官方发 → 官方收"，**对称**，
   所以它证明的是"**本轮数据的 lane 布局 = 官方约定**"，
   **不能**裁定"绝对字节序"——那一票仍归闸 2 的真网卡。

### C.3 `mii_c[7:0]` 各位 ↔ 字节 lane 的对应

- **结论**：`mii_c[l]` 是 **lane `l` = `mii_d[l*8 +: 8]` = byte `l`** 的控制位（1 = 该 lane 是控制字符）。
- **板上佐证**（三条，互相独立）：
  1. **帧首**：检查器要求 `c == 8'h01` 且 `d[7:0] == 0xFB`（即**只有 lane0 是控制位、且是 `/S/`**）
     —— 40 M+ 帧 `badstart = 0` ⇒ `c[0] ↔ lane0` ✓；
  2. **帧尾**：`/T/`（0xFD）被要求**落在 lane0**（检查器的 `o_bad_term` 为 0，
     `logs/s3_probe_FINAL.txt` 的起帧字/终止字判据同批为 0）⇒ 控制位与 lane 的绑定成立 ✓
     （⚠️ 本轮没打印 `o_t_lane` 的原始值，所以这一条是**由判据间接得到**，不是直接读到的；
     第一轮的 `o_t_lane` 读数为 0 记录在 `logs/s3_probe_FINAL.txt` 的 `S3_FINAL_MISC` 行）
  3. **空闲**：厂商发生器的空闲字是 `d = 0x0707070707070707`（全 lane `/I/`）**且 `c = 8'hFF`**
     —— 我的检查器以"`c == 8'hFF && d == 0x0707…07`"识别空闲字，ch0 方向实测
     `c0_idle ≈ c0_ctrl`（§5.1 的 idle/ctrl 计数）⇒ **8 个 lane 的控制位都在 `c` 里** ✓。
- ⚠️ **下一轮注意**：`/T/` 之后**同一个字里剩下的 lane**（厂商发生器给的是 `/I/`，而 `mii_c` 里那几位是 1）
  属于**下一帧的领地**；我们的 MAC 不能把它们算进本帧（`/T/` 是本帧最后一个有效字节）。

### C.4 帧几何（本轮实测钉死的常量，下一轮 MAC 的自检可以用）

| 量 | 值 | 证据 |
|---|---|---|
| 每帧 XGMII 字数 | **33**（32 个数据字含首字 + 1 个终止字） | `S7_S3_D`/`S3_LONG_WORDS_PER_FRAME = 34.000`（含 1 个帧间空闲字） |
| 每包周期字数 | **34** = 33 + 1 空闲 | 同上 |
| 载荷字数/帧 | **29** | `S7_S3_RATE c1_pay per_dclk` → ×(1/0.04595) ≈ 29 ✓；`S7_S5_PAYWORDS_PER_FRAME 29.000002` |
| 帧内容（全 0 载荷档） | 首字 `64'hD5555555555555FB`(c=1) → `64'hFE14FFFFFFFFFFFF` → `64'h00000006829ADDB5` → 29 个全 0 字 → 终止字(`/T/` 在 lane0, c=0xFF) | `rtl/xgmii_rx_chk.v` 的常量 + 40 M 帧零失配；**仿真独立复现**（`sim/tb_pay_sel.v` 的 `TBCASE psel=0 word 18204 d=fe14ffffffffffff`） |
| 帧内容（全 1 载荷档） | 同上，但第 3 字起为全 1：`64'hFFFF0006829ADDB5` → 29×`64'hFFFFFFFFFFFFFFFF` | §10.4（10 M 帧零失配） |
| 线速 | 156.25 M 字/s × 64 bit = **10.000 Gbps** | §5.5 |

## 10.8 下一轮（自写 64 位 XGMII MAC）的**施工要点**（从本轮实测直接得出）

1. **字节序**：MAC 与 PCS 之间**必须**做 §C.2 的 8 字节镜像（TX/RX 各一次）。
2. **RX 时钟**：`rx_core_clk_N` 是**用户输入**（核不产生），必须用 `rx_clk_out_N` 驱动（自环），
   且它是 **CDR 恢复**时钟 ⇒ 与 TX/DP 一律按**异步**处理（`set_clock_groups -asynchronous` 已验证有效，
   `logs/s2_build_FINAL.txt:1806/1808` + Inter Clock Table 为空）。
3. **复位**：RX MAC 用 `user_rx_reset_N`（RX 域）、TX MAC 用 `user_tx_reset_N`（TX-MII 域）；
   `rx_reset_N`/`tx_reset_N` 接 0；`sys_reset` 自己产生（≥10.5 ms POR 实测够）。
4. **`/E/` 与统计**：`/E/` 计数**在块锁建立后再开始**（否则起动瞬态污染判据，§10.2）；
   `valid_ctrl_code` 是电平不是脉冲（§10.5）；`stat_rx_error[7:0]` **没有观测面**（`_valid` 不触发），
   下一轮**不要**把它的"0"当判据。
5. **TX 空闲**：空闲必须**持续**发 `/I/`（全 lane `0x07` + `c = 8'hFF`），一拍都不能停
   （我说 10GBASE-R 需要连续块流；本轮的 ch1 方向就是这么做的，ch0 的接收器 30 M 帧零 `/E/` ✓）。
6. **GT 环回**：调试期可用 `gt_loopback_in_0 = 3'b001`（或 `010`）做**单通道自环**，
   免光纤、免第二通道（§10.1 实测可用 + 负对照）。
7. **别信"隐式网"这个词**：Vivado 2025.2 打 `[Synth 8-11241] undeclared symbol`，
   旧措辞 `implicitly declared` **不会出现**（§10.4 的坑）。新增文件后**必须**用新关键字过门。

## 10.9 未核实清单（第二轮新增）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| U14 | `gt_loopback_in_0` 各编码的**语义**（001/010 可用，但不知是 PCS 级还是 PMA 级、环路点在哪） | 只测到"哪些可用" | 查 UG578（本地没有） |
| U15 | 起动瞬态 `/E/` 的**产生路径** | 已定位到"首帧之前"、非确定性；产生源未确证 | RX 侧 ILA/`mark_debug` 抓上电头 100 µs |
| U16 | `dclk` 的**绝对**频率 | 比值 6×10⁻⁶；绝对只到 ±0.85%（我的墙钟口径与"Y1 = 100 MHz"差 0.85%，差异未定位） | 板外频率计；或把时间戳机制换成硬件触发 |
| U17 | `stat_rx_status/hi_ber/local_fault/framing_err/bad_code/error/fifo_error/valid_ctrl_code` 的**时钟域** | `block_lock` = dclk 实证；其余无脉冲可判别 | 造一个已知脉冲（故意打坏块）重跑双域计数；或 ILA |
| U18 | `[DRC AVAL-326]` 本轮 0 次的**机理** | 规则名/语义/不拦位流 = 已知；"为什么 1 通道会报、2 通道不报"未查清 | 对比两版 netlist 里 IBUFDS_GTE4 的归属 |
| U19 | 副本与厂商原文的**行为等价性**只在 `pay_sel=0` 下验证过（全 0 载荷） | 全 0 档逐位一致（40 M 帧）；全 1 档是新增行为，无厂商对照 | 若要严格，用厂商原文件再跑一遍全 0 档做 A/B（本轮未做——原文件无法选图案） |
| U20 | `stat_rx_error[7:0]` 的**触发条件** | 两轮、两次故意打断、2.3 G 周期都未触发 | 仿真（官方 example tb）或人为造坏码 |

## 10.10 本轮新增/改动的文件（全部在 `_proj_10g/xxv_loop/`）

| 文件 | 作用 |
|---|---|
| `rtl/pcs64_pkt_gen_mon_ds.v` | 厂商明文流量源的**参数化副本**（6 处 diff，§10.4；`pay_sel=0` 等价原文） |
| `rtl/xgmii_rx_chk.v` | 加 `pay_sel` 期望载荷选择、`o_e_pre`/`o_e_post`、`LAST_DW` 订正为 32 |
| `rtl/xxv_loop_top.v` | 加 `vio_gt_loopback[2:0]`/`vio_pay_sel`、双域 `stat_*` 计数器、48 探针打包 |
| `sim/tb_pay_sel.v` + `sim/run_sim_pay.bat` | 只测流量源本身的 xsim 台（**就是它抓到了隐式网**） |
| `tcl/s4..s8,s10_*.tcl` | 只读网表/属性查询（域、通道、IBUFS、FREERUN、fanout） |
| `tcl/s7_probe2.tcl` / `s11_probe3.tcl` + `run_s7/s11.bat` | 第二轮板级会话（48 探针 / 环回 / 60 s 频率） |
| `logs/s7_probe2_FINAL.txt` / `logs/s11_probe3_FINAL.txt` / `logs/s2d_run_output.txt` / `logs/s8_rst_stdout.txt` / `logs/s10_misc_stdout.txt` | 本节引用的全部原始日志 |

## 10.11 本轮**没有**做的

- ❌ 没有写我们的 MAC（仍在做接口合同与 PCS 验证）。
- ❌ 没有动厂商文件（副本是**新文件**；原文件 sha256 未变 `2782d688…b0e03e6`）。
- ❌ 没有 git 写操作；没有碰 QSPI；没有动 license；没有碰 `D:\repo\perfv`。
- ❌ 没有做 `stat_*` 钉常量的负对照（N8），也没有造脉冲确证 `stat_*` 域（U17）。

## 10.12 对第 1 部分的三处**订正**（诚实登记）

| # | 第 1 部分的说法 | 本轮实测后的正确说法 |
|---|---|---|
| 1 | §5.11 括注"8 位计数器是**饱和型**（不回绕），所以只能证'没到 255'" | ❌ **错**。饱和计数器**读 0 = 精确零事件**（只增不减、到 255 封顶）⇒ 当时那句把判据说弱了。本轮又用**32 位不回绕**计数器 + **双域**各计一遍，把 framing/bad_code/fifo 的"0"升级成**精确 0**（§10.5） |
| 2 | §4.4/§6.2 A14"`implicitly declared` = 0 ⇒ 无隐式网" | ⚠️ **门的关键字错了**：Vivado 2025.2 用 `[Synth 8-11241] undeclared symbol`。本轮设计**真的含一个隐式网**（副本的 `pay_sel`）而旧门报 0。已修门 + 修设计；现在报的 10 条**全部来自厂商文件自身**（§10.4） |
| 3 | §5.1 C8"`valid_ctrl_code` 持续增长（控制块在收的正证据）" | ⚠️ **口径要改**：该信号是**电平**（实测两个域都≈每拍为 1，rx 域计数逐数等于时钟数）⇒ 只能当"链路活着时该线为高"。**"控制块真的在收"的精确证据**是 `c0_ctrl`/`c1_ctrl`（我自己的计数器） |
