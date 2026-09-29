# P7B_SPEC.md —— 10G 数据面施工规格书（官方 `xxv_ethernet` PCS/PMA 64-bit + 自写 64 位 XGMII MAC）

- 日期：2026-09-29
- 性质：**施工规格书**。本文件是本次任务**唯一**写入的文件 —— **未改任何 RTL / XDC / tcl / 脚本 / 其它文档**，
  **未烧板**、**未跑 Vivado**、**未执行任何 git 写操作**、**未触碰 `D:\repo\perfv`**。
- 上游输入（全部只读）：`_proj_10g/notes/P7B_XXV_OFFICIAL.md`（**本次核心依据**）、
  `P7B_DATAPATH_CONTRACT.md`、`P7B_RXCLASSIFY_AUDIT.md`、`P7B_BASER_TABLES.md`、
  `P7B_PHY_IFACE.md`、`P7B_LIB_SURVEY.md`（后两份的**路线部分已作废**，只作背景/对照）。
  现役观测表 `P6E_OBS.md`；风格与结构仿 `P7A_SPEC.md`。
- 器件：`xcku5p-ffvb676-1-e`（Kintex UltraScale+，**-1 最慢速度等级**）。工具：Vivado 2025.2。
- 构建根 = 本仓根 = `D:\repo\XCKU5PMini\udp_hls_10g`（git 根）。

### 证据强度标记（全文使用；**严禁把任一等级写成比它更高的等级**）

| 标记 | 含义 |
|---|---|
| 【已实测】 | 本次/前次**工具原始输出**或**静态回读**（`.xci`/`.veo`/报告/日志原文），本规格书给出 `文件:行号` |
| 【板级实测】 | 上板读数的原始文本（P6b 验收 / P7a 验收） |
| 【明文RTL】 | 仓库内的 **AMD 明文源码**（example design / monitor）或**本仓自己的 RTL**，逐行可核 |
| 【转述自 X】 | 我只读过别人（另一路侦察）的笔记，**没有独立复核原始文件** |
| 【推定】 | 逻辑推理，无直接证据；本规格书给出推理链 |
| 【未核实】 | 就是不知道。**不得当判据用** |

> ⚠️ 本规格书里凡标【转述自 …】的条目，**采信前应回原始文件核一遍**（本工程的历史教训：转述会积累漂移）。

---

## 0. 一页结论（TL;DR）

| 问题 | 结论 |
|---|---|
| 走哪条路？ | **`CORE = Ethernet PCS/PMA 64-bit`（XGMII 出）+ 自写 64 位 XGMII MAC**。这不是偏好，是**唯一能出位流**的一条：`CORE = MAC+PCS/PMA` 的 `write_bitstream` 被 **license 分级拒绝**（两次复现，原文见 §3.6）。 |
| 位流能出吗？ | ✅ **能**（侦察已产出 `probe_pcs64_top.bit`，15,431,266 B，sha256 `86fe9c7b…6a905`，`Bitgen Completed Successfully` / `0 Errors`）；⚠️ **但从未上板** —— "能生成位流" ≠ "板上能用"，这是**本规格书最薄的一环**（§9 R4）。 |
| −1 速度等级收敛吗？ | ✅ 侦察实测收敛且宽松：PCS-only `WNS +2.337 / WHS +0.019 / 0 失败端点`。**唯一薄处是 hold**（§9 R1）。 |
| 下游要改吗？ | ❌ **不用**。数据面每个下游模块入口都是 `tdata[63:0]+tkeep[7:0]`、每拍一个字（逐模块核对见 `P7B_DATAPATH_CONTRACT.md` §C.2）⇒ **新 MAC 只要复刻同一份帧流合同，下游零改动**。 |
| 最危险的一条是什么？ | ⚠️⚠️ **字节序相反**：官方 XGMII 是 **lane0 = 首字节**（`tx_mii_d[7:0]`），我们的合同是 **`tdata[63:56]` = 首字节** ⇒ 新 MAC **必须做 64 位字节翻转**。漏了它 = **安静失效**（链路照锁、每帧全错），且**自环回对它零判别力** ⇒ 必须有一条**专门判据**（§3.3 / 判据 D1、E3）。 |
| 最贵的一处施工是什么？ | **快照窗口从"两束"扩成"多束"**（新增 TX-MII / RX / dclk 三个域）—— 现役 `snap_seq` 的"两束链式触发 + 手写索引表"这套结构假设被打破（§7.4）。 |
| 必须先做的一件事？ | ⭐ **把 `CHANNEL_ENABLE` 从 1 通道改成 2 通道（`X0Y4 X0Y5`）** —— 侦察用的 1 通道配置**做不了闸 1 的 J7↔J8 自环**（自环需要"一个端口发、另一个端口收"，见 §5.1 前置）。改完**必须重读 `.veo`**：端口 `_0` 后缀的语义未核实（§11 U1）。 |
| 判据表有多少条？ | **66 条正判据（A16/B11/C9/D16/E5/F5/G4）+ 9 条负对照**（§6），每条都有「期望来源」栏。 |

---

## 1. 目标与范围

### 1.1 目标（本轮要交付的三件事）

1. **① 官方 PCS/PMA 接入**：把 `xxv_ethernet`（`CORE = Ethernet PCS/PMA 64-bit`，XGMII 出）接进本仓，
   配好引脚/时钟/复位，**把它的全部块级状态接到可观测面上**，并**在板上跑通**（位流从未上板，这是硬缺口）。
2. **② 64 位 XGMII MAC**：**整体替换** `rtl/mac_rx_64.v` / `rtl/mac_tx_64.v`，产出与现役**逐条相同**的帧流合同
   （`P7B_DATAPATH_CONTRACT.md` §A.1.2 的 9 条）⇒ `vlan_strip → rx_classify → udp_split/tcp_rx → …` **零改动**。
3. **③ `rx_classify` 收发解耦**：把 `rtl/rx_classify.v` 的"FILL/DRAIN 同 FSM 不重叠"改成**收字与决策解耦**，
   抬掉它的硬吞吐天花板（TCP 路径 `8/14 = 57.1%`）—— **10G 下必然触发**，且"加深上游 FIFO 修不了"。

**三件事的依赖是硬的**：②的验收依赖①能通（没有 802.3 对端就验不了 MAC）；③的验收依赖②能跑满 1 字/拍
（1G 口径的门看不见③的缺陷）。

### 1.2 非目标（**这一轮明确不做**）

| # | 不做的事 | 为什么/边界 |
|---|---|---|
| N1 | **不做官方 MAC（`CORE = MAC+PCS/PMA`）** | 位流被 license 拒绝（**可复现**，§3.6）。设计**不得**建立在"将来会拿到更高 license"之上。 |
| N2 | **不做 P7a 路线的任何一层**（自己写加扰器/块锁/gearbox/`txheader`/`rxgearboxslip`） | 路线已由官方核提供。⚠️ 见 §2.2："这些**一件都不要写**"。 |
| N3 | **不改 `app_udp_pattern` 的 RX 图案校验器**（现为 **1 字节/拍**，自报天花板 = 1G 线速） | `rtl/app_udp_pattern.v` 自述"10G 必须改成 8 路并行"。本轮**只用它作功能判据，不用它当速率判据**（否则会把 app 天花板误读成 MAC 缺陷）。 |
| N4 | **不做 HLS 慢路径的 10G 化** | `slow_rx_adp`/`slow_tx_adp` 是 64 位字 ⇄ 9 位字节、**1 字节/拍**（封顶 ≈ 1.25 Gbps），HLS 本身更低。10G 验收只跑 fast path。 |
| N5 | **不因 10G 而重调 TCP 时标/窗口/重传**（RTO、`WIN_POOL`、`ACC_MARGIN`） | "能不能通"不需要；"跑多快"留后续。⚠️ 但**已知**：`DP_156MHZ` 已把 8 个模块的时间常数按 156.25 MHz 重标（`P7B_DATAPATH_CONTRACT.md` §D.3 ④），本轮**不动**它们。 |
| N6 | 不做多端口聚合/链路聚合、不做 100G、不做 jumbo（>1518/1522）、不做 VLAN 双 tag | MAC 层按 802.3 基本帧与 Q-tag 帧实现即可。 |
| N7 | **不做 SFP 的 I2C/DOM**（读模块型号/温度/光功率） | 底板上未引出（`XCKU5PMini/CLAUDE.md`），物理上做不到。 |
| N8 | **绝不写板载 QSPI** | 板上存着厂商 XDMA+DDR4 设计。只走 JTAG 易失烧录（`XCKU5PMini/CLAUDE.md` 纪律 ①）。 |
| N9 | 不做 10GBASE-R 的自协商/AN/LT | 802.3 的 10GBASE-R 无自协商；本轮不做 KR/AN/LT。 |
| N10 | **不迁移厂商 Demo 的参考设计** | 它是 K7 套壳、8 位数据通路，MAC 层往下不可复用（`XCKU5PMini/CLAUDE.md`）。 |

### 1.3 "做完了"的定义

①②③ 各自**在闸 4（板级验收）上有一次完整、可复现、带位流 sha256 的读数**，且 §6 的判据表**全 PASS**、
负对照**全部按期望 FAIL**、§8 的未覆盖项**逐条显式登记**。少一条都不算完。

---

## 2. 架构

```
                          ┌──────────────── 本规格书新建 ────────────────┐
  156.25 MHz 差分参考钟   │                                              │
  (Y2 → V7/V6, MGTREFCLK0_225)                                           │
        │                 │                                              │
        ▼                 │                                              │
 ┌──────────────────┐     │                                              │
 │ xxv_ethernet 5.0 │     │        ┌──────────────┐                      │
 │ CORE = Ethernet  │     │        │ 新: XGMII MAC│                      │
 │  PCS/PMA 64-bit  │     │        │  (TX 侧)     │                      │
 │                  │ tx_mii_clk_0 (156.25 MHz, QPLL0 派生)              │
 │  gt_rxp/n_in_0 ◀─┼─────┼────────┤              │                      │
 │  gt_txp/n_out_0 ─┼─►SFP A (J7 = X0Y4)                               │
 │                  │     │        └──────▲───────┘                      │
 │  tx_mii_d_0[63:0]│◀────┼── [64 位字节翻转] ◀── tx_mii_c_0[7:0]        │
 │  tx_mii_c_0[7:0] │     │               │                              │
 │  rx_core_clk_0   │◀────┼── 自环 = rx_clk_out_0（恢复时钟）            │
 │  rx_clk_out_0    │─────┼──┐            │                              │
 │  rx_mii_d_0[63:0]│─────┼─┐│   ┌────────┴───────┐                      │
 │  rx_mii_c_0[7:0] │     │ ││   │ 新: XGMII MAC  │                      │
 │  stat_* / ctl_*  │◀───▶│ ││   │  (RX 侧)       │                      │
 │  sys_reset/dclk  │     │ ││   └────────┬───────┘                      │
 └──────────────────┘     │ ││            │  (RX 域 = 恢复时钟)          │
   SFP B (J8 = X0Y5) ─────┼─┘│            ▼                              │
   （第 2 个端口；闸 1 自环用）│      fifo_async (W=76, D=256, FWFT)  ← 复用 rtl/fifo_async.v
                          │   │            │  ← 替代现役 u_rxcdc 的角色  │
                          │   │            ▼                              │
                          │   │      ┌───────────────────────────────┐    │
                          │   │      │  已冻结的 64 位帧流合同        │    │
                          │   └─────▶│  tdata[63:56]=首字节 / tkeep  │    │
                          │          │  高位有效 / TLAST 上 tcrs,terr│    │
                          │          └──────────────┬────────────────┘    │
                          │                         │  dp_clk = 156.25 MHz│
                          │                         │  (Y1 100MHz × 1.5625)│
                          │          ╔══════════════▼══════════════════╗  │
                          │          ║ vlan_strip → rx_classify ③      ║  │
   TX 方向:               │          ║   → udp_split / tcp_rx / …       ║  │
   tx_arb → udp_tx_frame  │          ║   ← tcp_tx_frame / udp_tx_frame  ║  │
   → fifo_async (W=73)    │          ║   ← tx_arb                       ║  │
   ← 替代现役 u_txcdc 角色 │          ╚══════════════════════════════════╝  │
                          └──────────────────────────────────────────────┘
```

### 2.1 三点必须写清楚

1. **字节序翻转在 MAC 与 PCS 之间**（两侧各一次：TX 进 PCS 前、RX 出 PCS 后）—— 见 §3.3。
2. **两个异步边界**：DP↔TX-MII（TX 方向）、RX 恢复域↔DP（RX 方向）。位置与现役 `u_txcdc`/`u_rxcdc`
   **在数据面上的位置完全相同**，只是"另一侧"的时钟从 `gmii_clk`(125 MHz) 换成官方核的两个 156.25 MHz
   （§3.4）。⇒ **不需要重新论证弹性预算的位置，但必须重新论证深度/宽度**（§3.4 有算式）。
3. **PCS 层（加扰/块锁/gearbox/XGMII 编码）在官方核里**；我们只写 **XGMII 的"帧语义"那一层**
   （S/T/I/E 控制码、前导、FCS、IFG、帧长、pad、统计）。

### 2.2 ⚠️ 路线变更带来的"**反向要求**"（P7a 路线的东西，一件都不要写）

| P7a 路线要求我们做的 | P7b 的正确做法 | 再次自加会怎样 |
|---|---|---|
| 自己写 **58 位加扰器/解扰器**（`1+x³⁹+x⁵⁸`） | **绝对不要写** —— 官方核内部负责 | 双重加扰：链路**照锁**（块锁与内容无关），但每一帧 FCS 全错 ⇒ **安静失效** |
| 自己写 **块同步 FSM + `rxgearboxslip` hunt** | **绝对不要写** | 与核内 FSM 抢 `rxgearboxslip` ⇒ 随机滑位、间歇掉链 |
| 自己驱动 **`txheader[5:0]` / `txsequence[6:0]`** | **不在我们的端口面上**（核内接） | —— |
| 自己统计 **"坏同步头"当误码量** | **不要用**（P7a 的 `hdre` 判据在真实以太网流量下会立刻爆表，见 `P7B_PHY_IFACE.md` §3.4 末） | 会得到"天天误码"的假告警 |

> ⚠️ **`P7B_PHY_IFACE.md:646` 已于 2026-09-29 被订正过**：原行把"gearbox / 加扰 / 不做编码"三件事捆成一个断言并标"证实"，
> 复核指出**只支持其中两件**。⇒ 引用那份文档时**只引它的 §1/§2.2/§3/§4/§5/§8**，
> `§2.3`/`§10.1` 的"加扰"断言**已作废**（对 P7b 也不构成风险：加扰在官方核内）。

#### ⚠️ 顺带一条**本次新发现**：`rtl/mac_rx_64.v` 的头注释有**两处与 as-built 相反**（照它改会踩坑）

| 行 | 注释写的 | as-built（代码/权威注释） |
|---|---|---|
| `rtl/mac_rx_64.v:4` | "10G 升级时 **PG157 的 AXIS 输出**加一层 shim 对齐到同一约定" | ❌ **PG157 / AXIS 的路线已作废** —— P7b 是官方 **XGMII** 核 + 自写 MAC（本规格书 §1、§4.2.1） |
| `rtl/mac_rx_64.v:7` | "crc 残留 == **`32'hC704DD7B`** 为正确" | ❌ **错的**。同文件 `:94-96` 的正文与代码 `localparam CRC_RESIDUE = 32'hDEBB20E3;` 才是对的；`0xC704DD7B` 是**大端/非反射**实现的魔数（项目 `CLAUDE.md` 的"本工程新增坑"第 2 条点名"勿用"） |

⇒ **新 MAC 的 FCS 判据一律以 `rtl/mac_rx_64.v:96` 的代码 + `rtl/crc32_8b.v:2-4` 的头注释为准**，
**不要读 `mac_rx_64.v` 的头注释第 4/7 行**。这两处**本轮不改**（本规格书只写这一份文件），但**建议后续单独订正**。

---

## 3. 接口冻结（**本章是规格的核心**）

### 3.1 官方核精确端口表（`CORE = Ethernet PCS/PMA 64-bit`）

来源：`_proj_10g/xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/pcs64.veo:58-110`（AMD 明文实例化模板，
**本次逐行读过**）。⚠️ 这是**1 通道**配置下的端口表；改 `CHANNEL_ENABLE` 后**必须以新 `.veo` 为准**（§11 U1）。

| # | 端口 | 方向/位宽 | 时钟域 | 我们的接法（**必须逐条决定，不许默认**） |
|---|---|---|---|---|
| 1 | `gt_rxp_in_0` / `gt_rxn_in_0` | in | — | GT 串行输入 → SFP A（球号由核内 XDC 的 `LOC GTYE4_CHANNEL_X0Y4` 推导） |
| 2 | `gt_txp_out_0` / `gt_txn_out_0` | out | — | GT 串行输出 → SFP A |
| 3 | `gt_refclk_p` / `gt_refclk_n` | in | — | **156.25 MHz 差分**（核内自带 `IBUFDS_GTE4`）；顶层给差分输入；XDC 钉 V7/V6 + `create_clock 6.400` |
| 4 | `gt_refclk_out` | out | — | ⚠️ **不要消费**（与 `rxrecclkout_0` 同理，消费会 route 失败 —— 坑 2） |
| 5 | `dclk` | in | 100 MHz | **用户提供 100 MHz**（DRP/复位域）。⚠️ 与 `FREERUN_FREQUENCY` 强耦合，见 §3.6 |
| 6 | `sys_reset` | in | 异步 | 高有效总复位。**顶层自己产生**（厂商 example 把它当外部输入，`pcs64_exdes.v:75`，**没有片上复位发生器**）——配方 §3.5 |
| 7 | `rx_reset_0` / `tx_reset_0` | **in** | — | ⚠️ **必须被真实驱动，绝不能悬空**（坑 1：悬空 ⇒ `opt_design` 直接失败）。厂商 example 由 `pcs64_pkt_gen_mon` **驱动**（它是 `output wire`，`pcs64_pkt_gen_mon.v:74,100`） |
| 8 | `user_rx_reset_0` / `user_tx_reset_0` | out | 推断=RX/TX 核域 | ⭐ **应当作为我们 MAC 的复位源**（厂商 example 把它接进 monitor 的 `input user_rx_reset`/`user_tx_reset`）。见 §3.5 |
| 9 | `rx_core_clk_0` | **in** | 156.25 MHz | ⭐ **用户必须提供**。厂商 example **自环**：`assign rx_core_clk_0 = rx_clk_out_0;`（`pcs64_exdes.v:98`，上一行是被注释掉的 `= tx_mii_clk_0`） |
| 10 | `rx_clk_out_0` | out | — | 恢复时钟输出（RXOUTCLK）。自环到 #9 |
| 11 | `tx_mii_clk_0` | out | — | **XGMII TX 时钟 156.25 MHz**（TXOUTCLK/PROGDIV 派生） |
| 12 | `tx_mii_d_0[63:0]` | **in** | `tx_mii_clk_0` | XGMII TX 数据（**lane0 = `[7:0]` = 首发字节**，§3.3） |
| 13 | `tx_mii_c_0[7:0]` | **in** | `tx_mii_clk_0` | XGMII TX 控制位（1 = 该 lane 是控制字符） |
| 14 | `rx_mii_d_0[63:0]` | out | `rx_core_clk_0` | XGMII RX 数据（**lane0 = 首发字节**） |
| 15 | `rx_mii_c_0[7:0]` | out | `rx_core_clk_0` | XGMII RX 控制位 |
| 16 | `gtpowergood_out_0` | out | — | GT 电源好；进快照（活体判据） |
| 17 | `rxrecclkout_0` | out | — | ⚠️ **不要消费**（坑 2：route 失败实测） |
| 18 | `gtwiz_reset_tx_datapath_0` / `_rx_datapath_0` | in | — | **恒 `1'b0`**（照厂商 example） |
| 19 | `qpllreset_in_0` | in | — | **恒 `1'b0`**（改它会扰动同 quad 的别的核） |
| 20 | `txoutclksel_in_0[2:0]` / `rxoutclksel_in_0[2:0]` | in | — | **恒 `3'b101`**（厂商原注释："as per gtwizard，不可改"） |
| 21 | `gt_loopback_in_0[2:0]` | in | — | GT 内部环回。**闸 1a 的控制脚**（⚠️ 各模式语义未核实，§11 U6） |
| 22 | `ctl_rx_wdt_disable_0` | in | — | **恒 `1'b0`**（照厂商 example） |
| 23 | `stat_rx_block_lock_0` | out | dclk 域【推定】 | **块锁**。见 §3.2 |
| 24 | `stat_rx_status_0` | out | dclk 域【推定】 | **RX 链路健康**（厂商 example 的用法是 `rx_block_lock_led = block_lock & stat_rx_status`，[转述自] `P7B_XXV_OFFICIAL.md` §4.2；**行号未核**） |
| 25 | `stat_rx_hi_ber_0` | out | dclk 域【推定】 | 高误码率 |
| 26 | `stat_rx_local_fault_0` | out | dclk 域【推定】 | local fault |
| 27 | `stat_rx_framing_err_0` + `stat_rx_framing_err_valid_0` | out | dclk 域【推定】 | 帧定界错 + **有效指示** |
| 28 | `stat_rx_valid_ctrl_code_0` | out | dclk 域【推定】 | 收到合法控制码（**不是错误**，是正证据，见 §3.2） |
| 29 | `stat_rx_bad_code_0` + `_valid_0` | out | dclk 域【推定】 | 坏码 |
| 30 | `stat_rx_error_0[7:0]` + `stat_rx_error_valid_0` | out | dclk 域【推定】 | **逐 lane 错** |
| 31 | `stat_rx_fifo_error_0` | out | dclk 域【推定】 | 弹性 FIFO 错 |
| 32 | `stat_tx_local_fault_0` | out | dclk 域【推定】 | TX local fault |
| 33 | `ctl_rx_test_pattern_0` / `_data_pattern_select_0` / `_test_pattern_enable_0` / `_prbs31_test_pattern_enable_0` | in | — | RX 测试图案（PRBS31 等） |
| 34 | `ctl_tx_test_pattern_0` / `_enable_0` / `_select_0` / `_data_pattern_select_0` / `_prbs31_test_pattern_enable_0` / `_seed_a_0[57:0]` / `_seed_b_0[57:0]` | in | — | TX 测试图案（**58 位种子**） |

**`align_status`（RX 字对齐）**：⚠️ **不是端口**。它在核内存在，被厂商 example 的 XDC 直接引用
（`pcs64_example_top.xdc:132-133`：`get_cells -hier -filter { name =~ */i_RX_WD_ALIGN/align_status_reg[*] }`），
**且已被与进 `stat_rx_status_0`**（【转述自】`P7B_XXV_OFFICIAL.md` §3.1）。
⇒ 要单独看它只能 ILA/`mark_debug`（**可行性未核实**，§11 U2）。

> ⚠️ **不要抄厂商 example 的 XDC**（`pcs64_example_top.xdc`）：它是**别的板子**的
> （`IOSTANDARD LVCMOS18`、`#set_property PACKAGE_PIN AK38 …` 全被注释掉）。引脚一律用本板实测过的版本（§3.7）。

### 3.2 状态输出怎么用（**逐条**：接不接快照 / 当不当判据）

| 状态 | 进快照？ | 当判据？ | 判据形式与注意 |
|---|---|---|---|
| `stat_rx_block_lock_0` | ✅ 1 位 | ✅ | 闸 1/2 期间**必须 = 1**。它是"PCS 层真的在收"的第一判据 |
| `stat_rx_status_0` | ✅ 1 位 | ✅ | **必须 = 1**（它含 alignment + block_lock 等）。厂商 example 拿它点 LED |
| `stat_rx_hi_ber_0` | ✅ 1 位 | ✅（**弱**） | **必须 = 0**；⚠️ **但 `hi_ber=0` 不能当"零误码"证据** —— 它是 802.3 的"高误码"门限指示，不是零错。**零误码只能靠自己的 FCS 错帧/坏块计数**（与 `P7A_SPEC.md` R2 的"漏桶教训"同源） |
| `stat_rx_local_fault_0` | ✅ 1 位 | ✅ | 必须 = 0。非 0 = 对端在发 `/Q/` fault（或我们发的 `/Q/` 被自己收到） |
| `stat_rx_framing_err_0` (+`_valid_0`) | ✅ 计数 | ✅ | `_valid` 限定那拍才计数；**恒 0** |
| `stat_rx_valid_ctrl_code_0` | ✅ 计数（新增） | ✅ ⭐ | **必须非 0 且持续增长** —— 这是"控制块真的在收（`/I/`、`/S/`、`/T/`）"的**正证据**；若它恒 0，说明 RX 侧只见到数据块（或状态线被钉死/悬空），此时其它"恒 0"判据全部失去意义 |
| `stat_rx_bad_code_0` (+`_valid_0`) | ✅ 计数 | ✅ | **恒 0** |
| `stat_rx_error_0[7:0]` (+`_valid_0`) | ✅ 计数 | ✅ | **恒 0**（逐 lane）。⚠️ 位宽是 8 位线上一条、**不是**一个 8 位错误码 |
| `stat_rx_fifo_error_0` | ✅ 计数 | ✅ | **恒 0** |
| `stat_tx_local_fault_0` | ✅ 1 位 | ✅ | 必须 = 0 |
| `gtpowergood_out_0` | ✅ 1 位 | ✅ | 必须 = 1（否则后面都不用看） |
| `ctl_*_test_pattern_*`（TX/RX） | ❌ | ❌（**本轮不用**） | ⚠️ **PCS-only 端口表里没有"图案失配"状态输出**（本次逐行核过 `.veo:58-110` 的 **53** 个端口；对照 MAC+PCS 变体才有 `stat_rx_test_pattern_mismatch`，[转述自] `P7B_XXV_OFFICIAL.md` §3.3）⇒ "用官方 PRBS 自检"**缺判据面**，本轮不做（§11 U5）。XGMII 层的图案自检改由**厂商明文 monitor** 承担（闸 1c） |

**"接进快照"的三条硬规则**（本工程既有教训）：
1. 这些 `stat_*` 的时钟域**未核实**（推断 = `dclk`）⇒ **进快照前必须按域同步**；**多比特计数器不能直接两级同步跨域**（会读成位混值，像"数据面疯了"）。
2. 快照里**只放寄存器输出**（`snap_cdc` 的前提问过：`din_b` 只在 `clk_b` 沿变化）。
3. 判据**不能用"上次读到的值"当期望**（"空读 = 0 不可区分"是本工程老坑）⇒ 每条都要能**独立复算**。

### 3.3 ⚠️⚠️ 字节序高危点（**本规格书要求单独设判据的唯一一处**）

**事实（两侧各自独立、都已核过）：**

| 侧 | 首字节在哪 | 证据 |
|---|---|---|
| **官方 XGMII** | **lane 0 = 帧内第一个字节 ⇒ `tx_mii_d[7:0]` 是首发字节**（LSB-first 排布） | 厂商**明文** monitor：`pcs64_pkt_gen_mon.v:1148` `tx_mii_d <= swapn(tx_datain);` + `:1240` `swapn[i+:8] = d[(63-i)-:8]`（⇒ `tx_mii_d[7:0]` = 内部左对齐字的最高字节 = 帧首字节）；`:1199` `tx_mii_d[full_bits+:8] <= 8'hFD`（terminate 落在"已发字节数"那一 lane） |
| **我们的冻结合同** | **`tdata[63:56]` = 帧首字节**（字内字节从高到低连续） | `P7B_DATAPATH_CONTRACT.md:40-47,63-72`（`rtl/mac_rx_64.v:2-8` 头注释即权威文本） |

⇒ **两边相反**。新 MAC **必须**做一次 **64 位字节翻转**（纯连线，0 逻辑）：

```verilog
// TX: 合同 → XGMII（tdata[63:56]=byte0  ⇒  tx_mii_d[7:0]=byte0）
function [63:0] bswap64; input [63:0] d; integer i;
    begin for (i = 0; i < 8; i = i + 1) bswap64[i*8 +: 8] = d[(7-i)*8 +: 8]; end
endfunction
assign tx_mii_d = bswap64(frame_data);   // RX 侧同一个函数，方向相反
```

**为什么这是"安静失效点"（必须单独设判据）：**

1. 漏翻转 ⇒ **PCS 层完全正常**：块锁能上、`stat_rx_*` 全干净、链路在 NIC 侧也能起；
2. 但**每一帧的字节序全反** ⇒ 对端看到 `dst_mac`/`ethertype` 全错 + **FCS 失配** ⇒ 现象是
   **"链路起来了、一帧都收不到（或全被判 FCS 错）"** —— 这个症状**极像**"物理层不行"，历史上极易被误判。
3. ⚠️⚠️ **自环回对它零判别力**：TX 翻转 + RX 翻转**互相抵消**（厂商 example 的位反转正是这个道理，
   `P7B_PHY_IFACE.md` §2.3 末；P7a 的 `TXGEARBOX_EN` 轮也踩过同型坑）。
   ⇒ **自环回（含 GT 内部环回、J7↔J8 光路）无论跑多久、零错多少帧，都不能证明字节序对。**

**⇒ 本规格书要求的专门判据（三级，缺一不可）：**

| 级 | 在哪 | 判据 | 期望来源（**独立于本设计**） |
|---|---|---|---|
| **(i)** | 闸 3（xsim 单元门） | 给 MAC TX 送一串**逐字节递增**的已知帧字流，断言 `tx_mii_d[7:0] == byte0`、`tx_mii_d[63:56] == byte7`；RX 侧反向断言 | 厂商明文 `pcs64_pkt_gen_mon.v:1148,1199,1240` + 合同条文 ⇒ 期望值**手写死**在 TB 里，**不由 DUT 生成** |
| **(ii)** | 闸 1c（板级，**非对称**） | 与**厂商明文的 `pcs64_pkt_gen_mon`** 对接：我们的 MAC 若把字节放到错的 lane，**它的图案比对必须失败** | 同上（厂商自己的约定当"尺子"） |
| **(iii)** | 闸 2（板级，真网卡） | NIC 侧抓包，帧**逐字节**等于我们意图发的字节序 | 802.3 对端实现（**唯一**的最终裁决者） |

**并配一条变异负对照**：把 `bswap64` 改成直通（或改成"翻两次"）⇒ **(i) 必须 FAIL**（证明判据有牙）。

### 3.4 时钟域方案

| 域 | 来源 | 频率 | 谁在上面 |
|---|---|---|---|
| `dp_clk` | 核心板 **Y1 100 MHz** → MMCM ×1.5625（`clk_gen_p6b`） | **156.25 MHz**（实测 156.2585，`P6B_ACCEPT.md` B2b） | `vlan_strip` 及其后**全部**数据面（**不动**） |
| `tx_mii_clk_0` | 官方核（TXOUTCLK → PROGDIV，QPLL0 ← Y2 156.25 MHz） | 156.25 MHz 标称 | 新 MAC 的 **TX 侧** |
| `rx_core_clk_0` = `rx_clk_out_0` | 官方核（RXOUTCLK，**CDR 恢复**） | 156.25 MHz 标称 | 新 MAC 的 **RX 侧** |
| `dclk` | 用户给 **100 MHz**（Y1） | 100 MHz | 官方核 DRP/复位；`stat_*` 采样【推定】 |
| `pcie_axi_aclk` | XDMA（≈257–259.5 MHz） | — | 快照回程（不动） |

**⚠️ 三个 156.25 MHz 彼此不同源**（Y1-MMCM / QPLL0 / CDR 恢复），有 ppm 偏差。
**10GBASE-R 标准允许每端 ±100 ppm ⇒ 真实对接第三方设备时频差可能到 200 ppm**
（【转述自】`P7B_PHY_IFACE.md` §5.1）。
⇒ **硬规则：TX 域与 RX 域一律按异步处理**；任何"都是 156.25 MHz 所以可以直接连"的假设**不成立**。

**两个跨域点的位置与参数（**必须**重新论证，不许照抄 1G 的数）：**

| 方向 | 位置 | 结构 | 参数（提案，**必须复核**） |
|---|---|---|---|
| **TX** | DP → `tx_mii_clk_0` | `rtl/fifo_async.v`（**复用**，参数化、已板级验证）—— **角色与现役 `u_txcdc` 完全相同**，只把 `rd_clk` 从 `gmii_clk` 换成 `tx_mii_clk_0` | `WIDTH`：73（64+8+1）→ **可能需要 +1**（若新 MAC 需要 `sop`/`terr` 边带，见 §7.3 与 §11 U3）；`DEPTH`：现为 256 = 1.35 帧（下界 = 最大帧 190 字）⇒ **必须重算**（10G 下同样是 190 字，**不变**；但"是否要 2 帧预置"要按新 MAC 的背压行为定） |
| **RX** | `rx_core_clk_0` → DP | 同上，**角色与现役 `u_rxcdc` 相同** | `WIDTH`：现为 **76**（64+8+1+1+1+1）—— ⚠️ `P6B_SPEC` 曾写 77 是**算术错**，as-built 是 76，**接成 77 会静默截掉 `tdata[63]`= 每字首字节**（`P7B_DATAPATH_CONTRACT.md` §B.2）；`DEPTH`：256（下界 = 一个最大帧 190 字） |

**三条必须一起保住的 `fifo_async` 硬契约**（`rtl/fifo_async.v:26-70`，转述自 `P7B_DATAPATH_CONTRACT.md` §D.2）：
① **两侧复位必须同时给**（只复位一侧 = 未定义行为/静默脏数据）；② `full` 是**悲观**的、2 拍同步延迟是契约的一部分
（只在 `full==0` 时置 `wr_en`）；③ `FWFT=1` 会落 **LUTRAM**（`:98-99`）⇒ 深度×宽度直接吃 LUTRAM。
另：`mmcm_locked` **绝不进 FIFO 复位路径**（`wrapper_p4.v:291-293`）。

### 3.5 复位方案

**硬依赖链（取自 IP 内部复位控制器的本地 RTL，**不是猜的**；转述自 `P7B_PHY_IFACE.md` §4.1 —— ⚠️ 那是 **gt_10gbr** 的控制器，
`xxv` 的控制器**在核内**且**同族**，但**未逐行复核**）：**
```
gtpowergood → qpll0lock → userclk_tx_active → txresetdone → reset_tx_done       (RX 侧把 qpll0lock 换成 rxcdrlock)
```

| 项 | 规格 |
|---|---|
| `sys_reset` | 高有效。**顶层产生**（建议：板级 `reset_n` 反相 → 同步到 `dclk` 域 → 展宽若干拍）。⚠️ **具体宽度/时序配方未核实**（§11 U4）—— 厂商 example 把它当外部输入，**没有片上复位发生器**（`pcs64_exdes.v:75`） |
| `rx_reset_0` / `tx_reset_0` | **必须被驱动**（坑 1）。建议：与 `sys_reset` 同源（或按需单独请求）。⚠️ "驱动什么"的语义（= "用户请求复位核的 RX/TX 数据通路"）为【推定】，证据 = 厂商 example 里它们由 monitor 这个**用户侧模块**驱动 |
| `user_rx_reset_0` / `user_tx_reset_0` | ⭐ **用作我们 MAC 的复位源**：RX MAC 用 `user_rx_reset_0`，TX MAC 用 `user_tx_reset_0`。**理由**：核复位后（例如 PLL 失锁/重锁）核内部状态机与我们的 MAC FSM 会失步；用核给的复位源能自动对齐。⚠️ 其时钟域为【推定】（RX→ `rx_core_clk_0`、TX→ `tx_mii_clk_0`），**未核实** |
| 不复用 P7a 的配方 | ⚠️ `_proj_10g/rtl/p7a_top.v:162-163` 的 `gtwiz_userclk_{tx,rx}_reset_int = ~(&*prgdivresetdone & &*pmaresetdone)` 是 **gt_10gbr 的**接法；`xxv` **不暴露** `gtwiz_userclk_*_reset`（复位控制器在核内）⇒ **别照抄** |
| 复位纪律 | 构建期间**不得**从被构建的工程烧位流；每次测量前**必重烧**（本工程铁律） |

### 3.6 必须逐项核对的配置项（**回读比对，不信 `set_property` 的即时回读**）

**8 个顶层参数**（侦察实测回读逐项相符，`S2_POSTGEN_MISMATCH_N = 0`，来源 `P7B_XXV_OFFICIAL.md` §2）：

```
CONFIG.CORE                 = Ethernet PCS/PMA 64-bit     ← 决定一切
CONFIG.LINE_RATE            = 10
CONFIG.CLOCKING             = Asynchronous
CONFIG.BASE_R_KR            = BASE-R
CONFIG.GT_REF_CLK_FREQ      = 156.25
CONFIG.GT_TYPE              = GTY
CONFIG.INCLUDE_SHARED_LOGIC = 1
CONFIG.GT_GROUP_SELECT      = Quad_X0Y1                    ← 这个组名 = 通道 X0Y4（子核回读，不是猜的）
```

**⚠️ 施工坑（实测）**：**设 `CONFIG.CORE` 会把它的依赖参数静默重置**（实测：`LINE_RATE` 被写回 `25`、
`BASE_R_KR` 回到 `BASE-KR`、`GT_REF_CLK_FREQ` 回到 `161.1328125`，而**每条 `set_property` 的即时回读都是对的**）。
⇒ **必须走"不动点迭代"**：每轮设全 8 个 + **全量回读比对**，直到 `MISMATCH_N == 0`（侦察实测第 1 轮收敛）。

**⚠️ P7b 必须新增的一条配置项（本次侦察没做）**：`CONFIG` 里要覆盖到 **2 个通道**
（`CHANNEL_ENABLE` 含 `X0Y4` **与** `X0Y5`）—— 理由见 §5.1 前置。改完**必须**：
  ① 重读 `.veo`，**端口名/位宽/端口数以新表为准**（`_0` 后缀的语义未核实，§11 U1）；
  ② 重跑不动点迭代；
  ③ 重扫 `.xci` 的子核回读。

**子核 GT 回读项（逐项核对，侦察实测值）：**

| 参数 | 侦察值（PCS-only） | `gt_10gbr`（**板级已验收**） | 一致？ | 核对方法 |
|---|---|---|---|---|
| `TX/RX_LINE_RATE` | 10.3125 | 10.3125 | ✅ | 读 `ip_0/<tag>_gt.xci` |
| `TX/RX_INT_DATA_WIDTH` / `TX/RX_USER_DATA_WIDTH` | 64 / 64 | 64 / 64 | ✅ | 同上 |
| `TX/RX_BUFFER_MODE` | 1 | 1 | ✅ | 同上（⚠️ 原语侧 `RXBUF_EN/TXBUF_EN="FALSE"`，是 async gearbox 的正确用法） |
| `TX/RX_PLL_TYPE` | QPLL0 | QPLL0 | ✅ | 同上 |
| `TX/RX_REFCLK_FREQUENCY` | 156.25 | 156.25 | ✅ | 同上 |
| `TXPROGDIV_FREQ_VAL` | 156.25 | 156.25 | ✅ | 同上 |
| **`FREERUN_FREQUENCY`** | **100.00** | **156.25** | ❌ **唯一实质差异** | **见下面的专项** |
| `CHANNEL_ENABLE` | `X0Y4`（1 通道） | `X0Y4 X0Y5`（2 通道） | 差异 | **P7b 必须 = 2 通道**（§5.1） |
| `LOCATE_COMMON`（子核属性） | `EXAMPLE_DESIGN` | `CORE` | 差异 | **字面值语义未核实**（`P7B_XXV_OFFICIAL.md` U3）；实际核内自带 common（综合日志例化了 `*_common_wrapper`） |
| `INS_LOSS_NYQ` / `RX_TERMINATION` | 30 / `PROGRAMMABLE 800` | 未显式设 | 差异 | 若想更贴官方工作点可做 A/B（**未做板级对照**，`P7B_XXV_OFFICIAL.md` U12） |

#### ⭐ `FREERUN_FREQUENCY` 专项（用户点名的高危项）

- **现象**：官方核子核回读 `FREERUN_FREQUENCY = 100.00`（【已实测】），而我们的 `gt_10gbr` 是 **156.25**（因为它把
  `gtwiz_reset_clk_freerun_in` 显式接在 `clk_obs` = 156.25 MHz 上，`_proj_10g/rtl/p7a_top.v:176`）。
- **推断的成因**：`xxv` 的**顶层没有 100 MHz 自由跑时钟端口**，只有 `dclk`；其 OOC XDC 明文写着
  `create_clock -period 10.000 [get_ports dclk]`（`pcs64/synth/pcs64_ooc.xdc`）⇒【**推定**】它从 `dclk` 派生。
  **这是推断不是回读**（GT 内部实现加密）。
- **⇒ 必须核对的不是"数字要不要改成 156.25"，而是"`dclk` 到底喂了什么频率"**：
  | 核对项 | 期望 | 方法 |
  |---|---|---|
  | ① `dclk` 的 OOC 约束周期 | `10.000` ns（= 100 MHz） | 读 `pcs64/synth/pcs64_ooc.xdc`（+ `<tag>.xdc`）原文 |
  | ② 我们送给 `dclk` 的**实际**频率 | **100.000 MHz ±1%** | ⭐ **新增一个 `dclk` 域 32 位自由计数进快照**，按 `Δ/墙钟` 复算（先例：W5/W24 的正证据口径） |
  | ③ 子核回读值 | 与 ②一致 | 读 `ip_0/<tag>_gt.xci` 的 `FREERUN_FREQUENCY` |
- **不这样做的后果**：把 156.25 MHz 送给 `dclk`（顺手图省事）⇒ 复位 FSM 的**所有定时器按 100 MHz 标定、实际按 1.5625× 快**运行 ⇒ 复位等待窗口偏短。
  ⚠️ 具体后果（会不会导致复位失败）**未核实**；但它同时会改变 DRP 时钟 ⇒ **不冒这个险**。
- **负对照**：把 `dclk` 临时换成 156.25 MHz 的变体**不必做**；只需 ② 的实测值与 ① 的约束**对账**（两处独立）。

### 3.7 引脚与约束（**用本板实测过的版本，不要抄任何厂商 XDC**）

```tcl
# ===== GT 参考钟（Y2 已换 156.25 MHz → MGTREFCLK0_225 = ball V7/V6）
set_property PACKAGE_PIN V7 [get_ports gt_refclk_p]
set_property PACKAGE_PIN V6 [get_ports gt_refclk_n]
create_clock -name clk_gt_refclk -period 6.400 [get_ports gt_refclk_p]
# GT 串行脚**不用手写**：核内 XDC 已给 set_property LOC GTYE4_CHANNEL_X0Y4 / X0Y5，
# 串行球号由 channel LOC 推导（依据：iBERT 工程只写 refclk 的 PACKAGE_PIN 就跑通了）

# ===== ⚠️⚠️ SFP 控制脚：厂商两份 XDC 都把每对脚 P/N 对调了（三态实验定案，2026-09-27）
#   v1 只驱动 B11/C9 低 → 4 个 GT 全黑（RX_BER 0.50）；v2 四脚全低 → 链路立起（未接线通道仍 0.49）；
#   v3 只驱动 C11/D9 低 → 链路依然立起  ⇒ TX_DIS 在 C11/D9，RX_LOS 在 B11/C9
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sfp1_tx_dis]   ;# ★ 必须驱动**低**
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports sfp2_tx_dis]   ;# ★ 必须驱动**低**
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp1_rx_los]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp2_rx_los]

# ===== 其它用户时钟
create_clock -name clk_dclk -period 10.000 [get_ports dclk]     ;# ← 与 FREERUN_FREQUENCY 强耦合（§3.6）
# rx_core_clk_0 由 rx_clk_out_0 自环驱动 ⇒ 不需要 create_clock（核内 XDC 已声明它的 OOC 约束）

# ===== debug hub（VIO 若用）
set_property C_CLK_INPUT_FREQ_HZ 156250000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER true      [get_debug_cores dbg_hub]
```

**四条必须记住的**：
1. ⚠️ `SFP1_TX_DIS = C11` / `SFP2_TX_DIS = D9` **必须显式驱动低**；悬空被 10k 上拉拉高 ⇒ **光模块发射永久关断** ⇒
   现象是"两方向全黑"，**极易被误判成"板子做不了 10G"**（本板最难查的一类假故障）。
   闸 1a/1b/2 **都要先读 `sfp{1,2}_rx_los` 确认模块在位**。
2. ⚠️ 命名陷阱：XDC 里的 `Y2` 是 **ball 编号**（SFP A 的 RX+），与**晶振位号 Y2** 不是一回事。
3. ⚠️ quad 225 的 common 是 `GTYE4_COMMON_X0Y1` ⇒ wizard 生成的 refclk 端口名里带 `x0y1`（是 **common 站点号**，
   不是 channel 号）。**别改**。
4. 通道映射：**SFP A = J7 = X0Y4**、**SFP B = J8 = X0Y5**（iBERT 实测 `_ibert/m2_loopback.tcl:133-134`）。
5. ⚠️ 官方核**自己不碰引脚**：它的 `synth/<tag>_board.xdc` **是空的**，`<tag>.xdc` 只 `create_clock` 参考钟端口 +
   CDC waiver，**没有任何 `PACKAGE_PIN`**（`P7B_XXV_OFFICIAL.md` §5.4 坑 3）⇒ **不会和我们的 XDC 冲突**。
   它会报 `[DRC AVAL-326] IBUFDS_GTE4 missing valid LOC`（**Critical Warning，实测不拦位流**）——
   **允许保留但必须记录**；要确定性清除就在 impl-only XDC 里给 `IBUFDS_GTE4` 定 LOC（本次 `get_sites` 返回 0，
   没能自动生成 —— **未核实**）。

---

## 4. 三个工作项

### 4.1 ① 官方 PCS 接入

**交付物**：`rtl/p7b_pcs_wrap.v`（自己的外壳，**不改核内任何生成物**）+ XDC + 构建脚本 + 复位/状态接线。

**必须做的（逐条）**：
1. `create_ip` + **不动点迭代**设全 8 个 `CONFIG.*`（含 **2 通道**）；回读落盘 `.xci`；**在建工程时不得同时跑别的 Vivado**（本工程铁律）。
2. 引脚/时钟按 §3.7；`dclk` 供 **100 MHz** 且按 §3.6 核对。
3. 复位按 §3.5（`sys_reset` + 消费 `rx/tx_reset_0` + 用 `user_*_reset_0` 当 MAC 复位源）。
4. **状态全接出**（§3.2），一个都不许悬空 —— 悬空的状态在读数上与"恒 0"不可区分。
5. 两个 XGMII 时钟（`tx_mii_clk_0` / `rx_clk_out_0`）**各自 BUFG** 后再用；`rx_core_clk_0` 自环（照厂商 example）。
6. ⚠️ **绝不消费** `rxrecclkout_0` / `gt_refclk_out`。
7. ⚠️ 每个新的时钟域都要有一个 **32 位自由计数**（`tx_mii_clk_0` / `rx_core_clk_0` / `dclk`）—— 这是"该域真的在跑"的**唯一正证据**（先例：W5/W24）。

**验收对象**：静态判据 §6.1 的 A 组（构建/回读/时序/DRC/lint）+ 板级读数 §6.1 的 G2/G3。

### 4.2 ② 64 位 XGMII MAC

#### 4.2.1 ⚠️ 为什么**不能**是"把现有 MAC 加宽"

**事实**：`rtl/mac_tx_64.v` 的 TX 状态机是**每拍一字节**的：
`S_PRE`（前导 8 拍，`:143-162`）、`S_DATA`（`:163-193`）、`S_PAD`（最多 ~60 拍，`:194-207`）、
`S_FCS`（**4 拍**，`:208-215`）、`S_IFG`（**12 拍**，`:216-223`）。**这三项开销与帧长无关**（`:58` 的 `MIN_CLEN` / `:217` 的 `ifg_cnt==4'd11`）。
RX 侧的 `rtl/crc32_8b.v` 也是字节串行（`step8` 每字节 8 次移位，`crc32_8b.v:14-32`）。

**算数（本规格书自算，可复算）**：64 位/拍下，最小帧的线侧预算是
`XGMII 前导 8B + 帧 64B + IFG 12B = 84 B = 10.5 拍`。若把现有 FSM 直接搬到 8 字节/拍的通路上：

| 情形 | 每帧拍数 | 吞吐 = 10.5 / 拍数 |
|---|---|---|
| 载荷打满 8 B/拍，但前导/FCS/IFG 保持字节串行（8+4+12 = 24 拍） | 8 + 24 = **32** | **32.8%**（≈1/3） |
| 连载荷也按字节串行走（8+60+4+12 = 84 拍） | **84** | **12.5%**（≈1/8） |

⇒ **最小帧只剩线速的 1/3 ~ 1/8**（用户任务书写"~1/4"，同量级）。**必须是真流水的 64 位 XGMII MAC**：
一拍进出 8 个字节、FCS 用 8 字节并行 CRC 在末字内结清、IFG 按**字节**计但按字推进、前导只出现在帧首那一拍的 lane 里。

#### 4.2.2 哪些既有判据**可逐条照搬**（与位宽无关）

| 项 | 出处 | 照搬要点 |
|---|---|---|
| F4(a) 空间门 | `rtl/mac_rx_64.v:128` `push_ok = !fifo_full_next` | 逻辑等价、与位宽无关。**必须同时把 `full_next` 的组合推导一起搬**（`rtl/fifo_sync.v:53-57`） |
| F4(b) 帧推入门 | `mac_rx_64.v:133` `push_frame_ok = push_ok && !term_pend` | 同上 |
| F4(c) TERM 优先门 | `mac_rx_64.v:135` `term_fire = term_pend && push_ok` | 同上 |
| TERM 字五元组 | `mac_rx_64.v:199-206` `tdata=0, tkeep=8'h00, tlast=1, tuser=0, tcrs=0, terr=1` | **逐位照搬**（0 字节、不污染字节计数、下游按坏帧丢） |
| F-2 的 `S_FLUSH` | `rtl/mac_tx_64.v:232-244` | **判据 = `frd && !fempty && fdout[0]`** —— 依赖"`frd` 是寄存的、`fdout[0]` 是同拍头字"这条 **FWFT 语义**；只要新 MAC 的输入 FIFO 仍是 FWFT，这套判据可逐行照搬 |
| FCS 残差判据（RX） | `mac_rx_64.v:96` `CRC_RESIDUE = 32'hDEBB20E3` | 帧长无关，直接沿用（含"末字未对齐"的处理要重做） |
| `fifo_sync` 接口 | `rtl/fifo_sync.v:20-24`（`W/D/AW` 全参数） | 可直接复用（FWFT + `full_next`/`ovf_pulse` 探针都是通用件） |
| `S_PRE` 的 SFD 判定思路 | `mac_rx_64.v:210-228`（`0xD5 && pre_cnt>=6`） | **思路**可复用；**字节形式必须重写**（10G 的帧首是 `/S/`+`0x55`×6+`0xD5`，见 §4.2.3） |
| IFG 计数思路 | `mac_tx_64.v:216-223` | 思路可复用；**计数口径必须改**（见下） |
| 帧内中止→runt 语义 | `mac_tx_64.v:32` §⑤ + `:188` `stat_abort` | **必须保住** |
| 计数器命名与口径 | `stat_frames/stat_crc_err/stat_drop/stat_bytes/…` | ⭐ **逐字保留**：它们与 W0-W4/W20/W21 的判据和**验收脚本**绑定，改名会让板级脚本**静默读错** |

#### 4.2.3 哪些**必须重写**（逐条）

| 项 | 为什么 | 新要求 |
|---|---|---|
| `ljust64` / `ljust8` 拼字、`wreg/wkeep` 累积 | `mac_rx_64.v:100-102,137-170` 是**逐字节**拼字 | 每个源字进来就是 8 字节有效；`tkeep` 按 SOP/TLAST 与 **FCS 剥离后的有效字节数**重算 |
| `crc32_8b` → **8 字节/拍并行 CRC** | `crc32_8b.v:14-32` 字节串行；全仓**无** `crc32_64`（`P7B_DATAPATH_CONTRACT.md` §C.2 已 grep 确认） | 三条语义**必须逐条保住**：反射多项式 `0xEDB88320`、初值 `0xFFFFFFFF`、**无终值取反**（终值取反只在**写 FCS 字段**时做，`mac_tx_64.v:170`）；`en` 与 `d` **同拍**（`mac_rx_64.v:112-115` 的组合式是正确写法）；残留魔数 **`0xDEBB20E3`**（`mac_rx_64.v:96`）。⚠️ **别照抄 `mac_rx_64.v:7` 的头注释**——那里写的 `0xC704DD7B` 是错的（见 §2.2 末） |
| FCS 的字节落位 | `mac_tx_64.v:170,213`：`fcs_shr <= crc_nxt ^ 0xFFFFFFFF` 后**低字节先出**（LSB-first 上线） | 64 位版的"末 4 字节在字内的落位"必须与 1G 版**逐位一致**（跨版本对拍靠这个） |
| 4 字节前瞻剥 FCS | 1G 版是 32 位移位线（`mac_rx_64.v:103,288,308,313`） | 64 位版 = "末字去掉最后 4 字节"（调 `tkeep`）+ 逐字比较 |
| 孤儿字节计数 `fpushed` | `mac_rx_64.v:237,306` 用 `+= 16'd8` 定值 | 必须改成 **`Σpopc(tkeep)`** |
| **XGMII 成帧层（1G MAC 完全没有）** | 见下 | —— |

**XGMII 成帧层的完整需求（新写，来源 = 802.3 原文，转录见 `P7B_BASER_TABLES.md` §1-§4）：**

| 需求 | 规格 | 期望来源 |
|---|---|---|
| 控制码 | `/I/=0x07`、`/S/=0xFB`（**仅 lane0 合法**）、`/T/=0xFD`、`/E/=0xFE`；`/Q/=0x9C`（本轮可不发，但要能收） | 802.3-2008 **Table 46-3 + Table 49-1**（`P7B_BASER_TABLES.md` §1.1） |
| **帧首那一拍** | **byte0 = `/S/`（TXC=1）、byte1..6 = `0x55`×6、byte7 = `0xD5`（SFD，数据）** | 802.3 46.2.2（`P7B_BASER_TABLES.md` §2.2）。⚠️ **不是** 1G 的 `55×7+D5`（那样会**多一个 0x55、少一个 `/S/`** ⇒ 对端永远见不到块类型 `0x78`，**静默丢帧**） |
| 帧尾 | `/T/` 替换**最后一个有效字节**，位置随帧长落在**任意 lane** ⇒ **帧边界不在整字边界** | 802.3 46.2.1/49.2.4.9 |
| IFG（发） | 帧尾 `/T/` 之后**至少 12 个 `/I/`**（与 MAC 参数一致，保守） | 802.3 Clause 4.4（`interPacketGap = 96 bits = 12 octets`，1G/10G 同值）+ 49.2.4.7（删 `/I/` 必须以 4 个为一组，`/T/` 后 4 个不能删） |
| IFG（收） | ⚠️ **不得假设最小值**：接收 RS 侧 XGMII 最小 IPG = **5 octets**；发送侧可用 DIC 缩短 3 ⇒ 线上最短可能只有 **9** | 802.3 46.2.1（"minimum IPG at the XGMII of the receiving RS is five octets"）+ 46.3.1.4（DIC） |
| 帧长 | 最小 **64 B（含 FCS）**、`maxBasicFrameSize` **1518**、Q-tag **1522**、`maxEnvelope` 2000（不做） | 802.3 Clause 4.4（`P7B_BASER_TABLES.md` §4.1） |
| pad | 内容（DA..FCS）< 60 B 时补 0 到 60 | 802.3 3.2.8；**1G 版的 `MIN_CLEN=60` 踩过坑**（曾用 46 ⇒ `[46,60)` 的帧上线成 runt，`mac_tx_64.v:55-58`） |
| 空闲 | **必须持续发 `/I/`**（一拍都不能停）—— 10GBASE-R 要求连续块流，**停一拍对端就掉块锁** | 802.3 49.2.4.7【推定，但方向确定】 |
| runt/oversize/统计 | 看齐官方 MAC 的 `stat_*` 等价物（`stat_rx_truncated`/`oversize`/`bad_fcs` 这类） | `P7B_XXV_OFFICIAL.md` §3.3 的清单 |

**⚠️ RX 侧必须容忍的两件事（否则接真网卡会挂）**：
1. **IPG 可能只有 5~9 字节**（对端是独立实现，会用 DIC）；
2. **`/T/` 后面紧跟下一帧的 `/S/`**，可能落在同一拍里 —— 帧边界与字边界无关。

### 4.3 ③ `rx_classify` 收发解耦

**问题陈述（来源：`P7B_RXCLASSIFY_AUDIT.md`，本次全文读过；状态 = **未落地**）：**

| 项 | 事实 | 证据 |
|---|---|---|
| as-built | **6 字寄存器 skid + 单 FSM**（`S_FILL/S_DRAIN/S_PASS`），**FILL 与 DRAIN 互斥** ⇒ **FILL 期间不输出任何字** | `rtl/rx_classify.v:52,58,60-65,78-85,102-103`（本次抽查确认） |
| 每帧死拍数 | **3 拍**（非 TCP，w2 定案）/ **6 拍**（TCP，等 w5） | `rx_classify.v:5-11` 注释 |
| 硬吞吐上限 | `N/(N+停顿)`：非 TCP `8/11 = **72.7%**`；**TCP `8/14 = 57.1%`**（最小 64B 帧，剥 FCS 后 60B = 7.5 字 ⇒ N=8） | 审计件 §4.2 的算数（`PORT_NOTES.md:3613` 的 "57%" 与之吻合） |
| 它**不是**"静默丢字"缺陷 | 出口/入口判据是**结构性**的（FSM 状态 + 同拍组合 tready），模块内**无丢字路径**，且背压下的内容保真已被门覆盖（NOSTALL/STALL/HARD 三模式） | 审计件 §3（逐条核过，"不是 F4 形态"） |
| **加深上游 FIFO 修不了** | FILL 期间模块**没有可输出的字**（头字还在灌）⇒ 那 3/6 拍是**整条链的死拍**，与缓冲深度无关；缓冲只能把"丢帧"换成"积压增长"，最终还是丢 | 审计件 §4.2 |
| **10G 下必然触发** | 10G/156.25 MHz = **1 字/拍**，字间隔不再是 1G 的"10 个 dp 拍" ⇒ 每帧净赤字 ≈ **4.5 字（TCP）/ 1.5 字（非 TCP）** ⇒ 无界积压 | 审计件 §4.3（算数） |
| 后果**不是静默** | 进 `mac_rx_64` 的"整帧丢弃"路径 + 计数（`stat_drop_full` → 快照 **W34**） | `mac_rx_64.v:257-263,337-341` / `P6E_OBS.md:80` |
| ⚠️ **门缺口** | 现有 `tb_rx_classify`（125 MHz 固定帧表）只能证**内容保真**，**证不了吞吐**；`tb_udprx_rate.v:13` 自述其线速模型是"**每 8 拍 1 字**"（1G 口径）⇒ **全仓没有一条门在"1 字/拍连续输入"下跑数据面** | 审计件 §5 |

**交付物**：`rtl/rx_classify.v` 的改造（把"等 w5 决策"从**阻塞输出通道**改成**由真 FIFO 解耦**；
深度不是要点 —— **≥ 决策窗 6 字 + 少量抖动**即够，要点是**收字与决策/排空不再互斥**）。

**验收对象（三条，缺一不可）**：
1. ⭐ **新增吞吐门**（闸 3）：`1 字/拍 + 背靠背最小帧`，**TCP 与非 TCP 两条**，判据 = 输出字数/输入字数 = 100%（不是"不丢字"）；
2. **A/B 负对照**：把改造**回退**（或不改造的版本）跑同一条门 ⇒ **必须 FAIL**（证明门有牙）；
3. **不回归**既有三条背压模式门（NOSTALL/STALL/HARD）+ 全链门（闸 3）。

⚠️ **明确写清**：这一项**不**是"修 bug"，是**抬吞吐天花板**；改造**不得**引入丢字/乱序/半帧
（既有门的判据一条都不许放宽）。

---

## 5. 闸序（每闸：判据 / 期望来源 / 失败怎么办）

> **闸序不可跳**。每闸的**失败模式不同**：闸 1 抓"自己不自洽"，闸 1c 抓"对称盲区"，闸 2 抓"不符合 802.3"，
> 闸 3 抓"逻辑 bug"，闸 4 抓"板上才是真的"。

### 5.1 闸 1 —— 最短通路（官方 PCS + 板内自环，**不动线缆**）

#### ⚠️ 前置（**本规格书本次最重要的施工发现**）

**侦察用的配置（`CHANNEL_ENABLE = X0Y4`，1 通道）做不了闸 1。** 理由（自算，可复核）：
J7 = SFP A = **X0Y4**、J8 = SFP B = **X0Y5**（iBERT 实测）。一条 AOC 的两端分别插 J7 与 J8，
于是"J7 的 TX → J8 的 RX"。`X0Y4` 单通道核**只有 SFP A 的 TX/RX** ⇒ 它能发，但**收到的是 J8 发来的东西，
而 J8 没人发** ⇒ **收不到任何东西**。
⇒ **P7b 的核必须至少 2 通道（`X0Y4 X0Y5`）**；改完**必须重读 `.veo`**（端口 `_0` 后缀语义未核实，§11 U1）。
⇒ 至少需要 **1 个我们的 MAC（TX on port0）+ 1 个我们的 MAC（RX on port1）**；推荐做法见下面的 1c。

> 备选（更省，但判别力更弱）：**只用一个端口的 GT 内部环回**（`gt_loopback_in_0`）—— 见闸 1a。
> ⚠️ 但没有"单端口光路环回"这个选项：本板**没有 LC 自环插头**，AOC 的两个端头必须插进两个笼子。

#### 5.1a 闸 1a —— GT 内部环回（最便宜，无光路）

| | |
|---|---|
| 判据 | 令 `gt_loopback_in_0` 进环回模式 ⇒ 自发帧能被自己收回；`stat_rx_block_lock_0=1`、`stat_rx_status_0=1`；帧**逐字节**相等；FCS 残差通过 |
| 期望来源 | 帧内容 = 我们自己造的已知图案（独立复算）；状态位 = §3.2 的语义（官方 `.veo`） |
| 失败怎么办 | 先看 `gtpowergood_out_0` / `stat_rx_*`（若全 0 ⇒ 状态线没接出或核没起）⇒ 再查复位链（§3.5）⇒ 再查 `sys_reset`/`dclk` |
| ⚠️ 判别力声明 | **对称**：对绝对字节序/位序零判别力（见 §3.3）。**只能证"自洽"** |
| 负对照 | 关掉环回 ⇒ **必须 FAIL**（证明判据不是恒真） |
| 代价 | 0 额外硬件；⚠️ 各环回模式的语义（PCS 级 vs PMA 级）**未核实**（§11 U6） |

#### 5.1b 闸 1b —— 板内光路 J7↔J8（需要 2 端口）

| | |
|---|---|
| 前置 | 核为 2 通道；AOC 两端在 J7/J8；`sfp1/2_rx_los` 都读"模块在位" |
| 判据 | 双向（两个方向各建一次通路）跑固定时长，帧数守恒 + **逐字节相等** + FCS 全过 + `stat_rx_framing_err/bad_code/error/fifo_error` 恒 0 + `stat_rx_valid_ctrl_code` **持续增长**（正证据） |
| 期望来源 | 帧内容自算；状态位 = `.veo` 语义；**`valid_ctrl_code` 必须涨** 来自"我们确实在发 `/I/`"这个自证 |
| 失败怎么办 | `block_lock=0` ⇒ 查光路/模块/TX_DIS；`lock=1` 但帧全错 ⇒ 查字节序（§3.3）与 FCS 落位；帧数守恒但内容错 ⇒ 查 XGMII 控制码/lane 落位 |
| ⚠️ 判别力声明 | **仍然对称**（两端都是同一份我们的实现）⇒ **不能**用它裁定字节序 |
| 代价 | 需要 2 端口配置 + 第二个 MAC 实例 |

#### 5.1c 闸 1c —— ⭐ **非对称自检**（与厂商明文的 monitor 对接）【推荐必做】

| | |
|---|---|
| 做法 | 一端 = **我们的 MAC**，另一端 = **厂商明文的 `pcs64_pkt_gen_mon`**（`xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v`，AMD 明文，`gen_clk=tx_mii_clk_0` / `mon_clk=rx_core_clk_0`；它自己驱动 `rx_reset`/`tx_reset`，消费 `user_*_reset`） |
| 判据 | 厂商 monitor 的**图案比对必须通过**；我们的 MAC 若把帧首字节放到错的 lane，**它的比对必须失败** |
| 期望来源 | ⭐ 厂商**自己的**约定（`pcs64_pkt_gen_mon.v:1148,1199,1240` 的 `swapn`）—— **不是我们的实现** ⇒ **这是板级能拿到的最强字节序判据** |
| 失败怎么办 | 若 monitor 比对失败而自环（1a/1b）通过 ⇒ **字节序/lane 落位就是根因**，直接改 §3.3 的翻转 |
| ⚠️ 可行性 | **未核实**：需要先读通 `pcs64_pkt_gen_mon.v` 的图案语义/`PKT_NUM`/`send_continuous_pkts` 与它的 XGMII 接口时序（`restart_tx_rx`/`completion_status`）。**列为闸 1 的可选子项，但优先级高于 1b** |
| 代价 | 一个新 TB 顶层（把 monitor 例化进我们的 wrapper，用 `ifdef`）⚠️ 按工程坑 8：**每个 `ifdef` 配置都必须有自己的真 wrapper 全链门** |

### 5.2 闸 2 —— 接**真网卡**（802.3 对标）⭐ **不可省**

> ⚠️⚠️ **这一步需要用户动手改线缆**：把 AOC 的一端从 **J8** 改插到对端机 `192.168.0.38` 的
> **SFC9120 10G 网卡**口（`enp1s0f0np0` / `enp1s0f1np1`，`01:00.0/.1`，CPU 直连 x16 根端口，实测协商 3.0 x8）。
> ⚠️ **开工前先问清"线两头分别插在哪"**（不能问简称）—— 本工程已记教训（`board-measurement-preconditions`）。
> 现状：P7a 那轮是 J7↔J8；记忆里 NIC 口 1 也插着同型号 AOC（`FCBG110SD1C03`）。
> **若线缆状态与预期不符，闸 1b/1c 也可能需要先动线** —— 所以闸 1 的"不动线缆"要现场确认。

**为什么不可省（判据循环的破除）：**

| 判据 | 自环回能证明吗？ | 为什么 |
|---|---|---|
| 线速率 / 块结构 / 同步头合法性 / 加扰器自同步 / block lock | ✅ 能 | 两端都是官方 PCS，但这些层是**与内容无关**的物理/逻辑层，对称性不掩盖这里的错 |
| **XGMII 的 lane 落位 = 绝对字节序** | ❌ **不能** | 两端是**同一份约定**：TX 放错 lane + RX 读错 lane **互相抵消**（厂商 example 的位反转在自环回里互相抵消就是实证，`P7B_PHY_IFACE.md` §2.3 末） |
| **帧首 `/S/` vs 1G 的 `55×7+D5`** | ❌ 不能（若两端同错） | 同上 |
| **符合 802.3（对端是另一份独立实现）** | ❌ **完全不能** | 自洽 ≠ 对标。本工程历史上多次"自洽但不对标"的安静失效 |

**⇒ 闸 2 的判据（逐条给期望来源）：**

| # | 判据 | 期望来源 | 说明 |
|---|---|---|---|
| E1 | NIC 侧 `Link detected: **yes**` + `Speed: 10000Mb/s` | 802.3 10GBASE-R（NIC 是独立实现） | ⭐ **一条顶四条**：线速率对、64b/66b 块结构对、同步头对、加扰/解扰（自同步）对、block lock 成 —— **任一处错都锁不上** |
| E2 | NIC 侧**硬件** RX 计数增长（`ethtool -S`） | NIC 自己的计数器 | ⚠️ **字段名以现场 `ethtool -S` 输出为准，不许照抄记忆**（不同驱动版本名不同） |
| E3 | 抓包（`tcpdump`）里帧**逐字节**等于我们意图发的字节（dst_mac / ethertype / 载荷 / 长度） | 802.3 对端实现 | ⭐ **这是字节序的唯一裁决**（§3.3 (iii)）。**FCS 由 NIC 硬件校验**：错 FCS 帧根本不会出现在它的接收路径上 |
| E4 | 反向：NIC 发帧（`ping` / 自写 C++ 发包）⇒ FPGA 侧 MAC RX 计数增长、FCS 残差通过、载荷逐字节相等 | 我们的 MAC + 独立复算 | 覆盖 RX 方向 |
| E5 | **负对照**：故意发一个坏 FCS 的帧 ⇒ NIC **必须不呈现**该帧（或计入 FCS 错） | 802.3 3.2.9 | 证明 E3 的"帧出现了"不是真空判据 |
| E6 | **负对照（仿真做，不在板上做）**：去掉 `bswap64` ⇒ (§6.1 (i) 的门) **必须 FAIL** | 厂商明文 RTL | 板上改一次要重建位流，不划算 |
| E7 | `stat_rx_framing_err/bad_code/error` 在整场测试中**恒 0** | `.veo` 语义 | 802.3 对端不会给坏块 |

**失败怎么办（按症状分诊）**：

| 症状 | 最可能的根因 | 先查什么 |
|---|---|---|
| NIC `Link detected: no` | TX_DIS 悬空/被拉高（**全黑**）· SFP 模块/线缆 · 我们没发（TX MAC 没在发 `/I/`） | `sfp{1,2}_rx_los` · `gtpowergood` · TX MII 域自由计数在不在涨 |
| **链路起、零帧被 NIC 收** | ⭐ **字节序/lane 落位反了**（`/S/` 或首字节在错的 lane） | E3 抓包；§3.3 的翻转；闸 1c |
| 链路起、帧到了但**全 FCS 错** | FCS 落位/字节序/`crc` 终值取反写错 | 拿一个已知帧在仿真里对拍 `0xDEBB20E3` |
| 帧到了但**长度/内容少一截** | `/T/` 落位、pad、`tkeep` 重算错 | 对照 `W2`（线上帧长判别器） |
| 我们收不到 NIC 的帧 | 收侧 IPG 假设过严（NIC 用 DIC，IPG 可能只有 5~9 字节）· `/S/` 与上一帧同拍 | §4.2.3 的两条容忍要求 |

**⚠️ 采集纪律**：NIC 侧可能有自发流量（IPv6/LLDP 等）⇒ 判据必须**按流过滤**（按 MAC/ethertype）；
**10G 速率数字只认"板子自报"或"网卡硬件计数"**，**绝不用用户态 socket 收包数**（P6e 实测：~80k pps 必丢）；
**与速度有关的测试一律 C++/内核旁路**（本工程既有纪律）。

### 5.3 闸 3 —— 全链门（xsim）

| # | 判据 | 期望来源 | 失败怎么办 |
|---|---|---|---|
| F1 | **真 wrapper 全链门**（例化真 wrapper，不是子模块 TB）；**每个 `ifdef` 构建配置都要有一份** | 工程坑 8（P5a 血的教训：`ifdef` 分支里的接线错在子模块 TB 里完全隐身） | 门红的**第一件事**：`tasklist \| grep xsim` 排文件锁（坑 7，会假失败） |
| F2 | **逐字读回全部快照字**（含新增的每一个字） | 扩窗七/九处清单；`int_scratch/tb_int_axr36.v` 是模板 | 读回 X / 读到"另一个字的正确值" ⇒ 查拼接项数与 `snap_idx`/`snap_base` 位宽 |
| F3 | ⭐ **新增吞吐门**：`1 字/拍 + 背靠背最小帧`（TCP / 非 TCP 两条） | 802.3 帧长 + `P6B` 数据面 1 字/拍 | 见 §4.3 |
| F4 | **字节序单元门** + 变异负对照 | §3.3 (i)（期望值手写死，不由 DUT 生成） | —— |
| F5 | F4 / F-2 的判据逐条照搬 + 各自的变异负对照 | `mac_rx_64.v:128,133,135,199-206` / `mac_tx_64.v:232-244` | 判据不许放宽 |
| F6 | 隐式网签名命中 **0**（当硬失败：`Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989` (⚠️ 裸 `VRFC 10-3091` 会误伤 `board/util_gmii_to_rgmii.v` 的 14 处良性 unsized 字面量 —— 必须带 `actual bit length 1` 那一段)）· `10-3091` 计数 **0** | 工程坑 24 + 扩窗门 | 隐式 1 位线会静默截断 64 位连接 |
| F7 | 全链守恒律：`W30 == W0 + W32`、`W31 == W1 − 4·W0 + W33`（**按新 MAC 重推**） | `mac_rx_64.v:48-53` 的原始形式 | 新 MAC 的计数器口径若变，守恒律必须重新推导并写进 TB |
| F8 | ⚠️ **force 必须打在"生产者节点"（子模块端口）**，不是 wrapper 线 | P6e 实测：打线版会把"生产者↔线断开"掩盖成 PASS | 见负对照 N4 |

### 5.4 闸 4 —— 板级验收

| # | 判据 | 期望来源 | 失败怎么办 |
|---|---|---|---|
| G1 | 位流 **sha256** + `BUILD_ID` 前置闸（必须是本轮新值，**当前 6 ⇒ 本轮应递增**） | `P6E_OBS.md:29` 的 1..6 定义 + 验收脚本 | ⚠️ **必须同步改验收脚本里"未实现地址"的取值**（当前 `0xB0`），否则"新功能上线"会被报成回归 |
| G2 | **新时钟域的频率正证据**：Δ(自由计数)/Δ(墙钟) = 标称 ±1%（`tx_mii_clk_0` / `rx_core_clk_0` / `dclk`） | 先例 W5 = 125.0061 / W24 = 156.2585 | 计数不涨 ⇒ 该域没起 / 计数被钉死 |
| G3 | **停机态守恒律逐字成立**（§5.3 F7 的式子在板级重跑） | `P6B_ACCEPT.md` E1a/E1b（147==147、21235==21235） | —— |
| G4 | 10G 速率：**板子自报 × 帧长** 与 **网卡硬件计数** 互相对账（偏差 <1%） | P6b 的 956.0 Mbps 口径（99.9%） | 不用用户态 socket |
| G5 | 前置纪律：**构建期间不烧**；每次测量前**重烧**；PCIe 观测 **烧完必重启主机**；判活**看 BAR 不看 `lspci`** | `XCKU5PMini/CLAUDE.md` + `P6E_OBS.md` §6 末 | —— |
| G6 | `rx_classify` 修复的板级判据：最小帧洪泛下 `stat_drop_full` 增量 **恒 0** | 审计件 §4.3 的失效场景 | 若仍丢 ⇒ 回去看吞吐门的结论 vs 板级激励是否一致 |

---

## 6. 判据表

> ⚠️ **本工程的硬规矩：没有"期望来源"栏的判据 = 真空门的温床。** 每一条都必须能**独立复算**。
> 期望来源代号：**【802.3】** = IEEE 802.3-2008（条款号见 `P7B_BASER_TABLES.md`）·
> **【.veo】** = 官方核明文端口表 · **【厂商RTL】** = AMD 明文 example/monitor · **【工具】** = Vivado 回读/报告 ·
> **【合同】** = `P7B_DATAPATH_CONTRACT.md`（已验收的帧流合同）· **【先例】** = 本仓已验收读数 ·
> **【自算】** = 本规格书独立复算（算式写在判据里）· **【审计】** = `P7B_RXCLASSIFY_AUDIT.md`。

### 6.1 正判据（**66 条**：A16 + B11 + C9 + D16 + E5 + F5 + G4）

**A 组 —— 静态（无板）**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| A1 | 8 个 `CONFIG.*` 不动点收敛 | 【工具】+ `P7B_XXV_OFFICIAL.md` §2 | `S2_POSTGEN_MISMATCH_N == 0`（第 N 轮收敛） |
| A2 | `CHANNEL_ENABLE` 含 **X0Y4 与 X0Y5** | 【自算】§5.1 前置（J7↔J8 自环需要两个端口） | 子核 `.xci` 回读 |
| A3 | `.veo` 端口表已按新配置**重读并归档** | 【.veo】 | 端口名/位宽/数量与归档一致 |
| A4 | GT 子核 8 项逐项相符（行速率/内部宽/用户宽/buffer/PLL/refclk/progdiv/channel） | 【工具】+ `gt_10gbr` 板级基准 | 逐项 `=` 表值（§3.6） |
| A5 | `FREERUN_FREQUENCY` 与 `dclk` 实际频率**对账** | 【自算】§3.6 专项（②③ 两处独立） | `\|f(dclk) − 100 MHz\| < 1%` 且回读值 = `100.00` |
| A6 | OOC XDC 三个时钟周期：`rx_core_clk_0` 6.400 / `dclk` 10.000 / `gt_refclk_p` 6.400 | 【工具】`pcs64_ooc.xdc` 原文 | 逐条 `=` |
| A7 | 时序 **0 失败端点**（setup/hold/pulse width） | 【先例】P6a 闸 G / 侦察实测 | 失败端点 = 0 |
| A8 | **hold 余量必须记录数值** | 【先例】P6a `+0.012/+0.013`、PCS-only `+0.019` | 记录（不设下限），并标注薄 |
| A9 | 资源量级：PCS-only ≈ 2.2k LUT / 3.0k FF / **0 BRAM** / **GTY 通道数 = 2** | 【工具】`pcs64_utilization_synth.rpt` | 量级一致（新 MAC 另计） |
| A10 | `AVAL-326`（IBUFDS_GTE4 无 LOC）**允许存在但必须记录**；无其它新增 DRC 错误 | 【工具】+ 坑 3 原文 | 记录 Critical Warning 数 = 2 |
| A11 | `rx_reset_0`/`tx_reset_0`/`user_rx_reset_0`/`user_tx_reset_0` **全被驱动/消费** | 【工具】坑 1 原文（`Opt 31-155`/`31-67`） | 日志**零命中** |
| A12 | `rxrecclkout_0`/`gt_refclk_out` **未被消费** | 【工具】坑 2 原文（`Route 35-54`/`35-7`） | 日志**零命中** |
| A13 | `write_bitstream completed successfully` + `0 Errors`；**`[Vivado 12-1790]` 出现是预期的** | 【工具】§0.1 原文 | 不得把 12-1790 当失败判据；**出现 `[Common 17-69] ... not permitted` 才是失败** |
| A14 | lint：隐式网签名 = 0 (`Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989` (⚠️ 裸 `VRFC 10-3091` 会误伤 `board/util_gmii_to_rgmii.v` 的 14 处良性 unsized 字面量 —— 必须带 `actual bit length 1` 那一段)) · `10-3091` = 0 | 【先例】工程坑 24 | 硬失败门槛 |
| A15 | 无 `NSTD-1`/`UCIO-1`（所有端口有 LOC/IOSTANDARD） | 【工具】坑 4 的教训（`catch {add_files}` 静默失败 ⇒ 零约束设计） | 0 命中；且**必须回读 `get_files` 确认文件真的加进去了** |
| A16 | 位流 sha256 + 大小 + `BUILD_ID` 记录入库 | 【先例】P7a/P6b 的指纹纪律 | 三元组齐全 |

**B 组 —— 快照窗口（扩窗的"同批同改"）**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| B1 | `SNAP_NW`（wrapper localparam）== 两束之和 == `axi_regs.SNAP_NW` == `snap_cdc.NW` 之和 | 【先例】`wrapper_p4.v:2545-2547,2888` / `axi_regs.v:78` | 逐处相等 |
| B2 | `snap_idx` 位宽与 `snap_base` 位宽**同时**加宽 | 【先例】`axi_regs.v:212,222`（**只改一处 ⇒ 未实现地址静默回绕成 W0..W3 = 假 PASS**，本工程踩过） | 字宽 W ⇒ `snap_idx ≥ ceil(log2(W))`、`snap_base ≥ ceil(log2(W*32))` |
| B3 | 逐字读回**每一个**快照字（含最后一个） | 【先例】`P6E_OBS.md` 的 7 处清单 | 全等；**且必须覆盖到末字** |
| B4 | 两束索引表（`rtl/snap_seq.v` 的 `fe_idx_of`/`dp_idx_of`）与拼接项数/顺序**逐项一致** | 【先例】`snap_seq.v:86-121` | 逐项 |
| B5 | 验收脚本里"未实现地址"的取值已随窗口更新 | 【先例】`P6E_OBS.md:105` ⑤（0x18→0x44→0x60→0x84→**0xB0**） | 新值 < 0x100 且 = 末字 + 1 |
| B6 | 快照窗口总字数 **≤ 56 字** | 【自算】`axi_regs.v:173` `ar_word = araddr[7:2]`（6 位）⇒ 地址每 256 B 回绕；快照从 word 8 起 ⇒ 最大 word 63 = **0xFC** = 第 56 字 | 字数 ≤ 56（否则必须动地址译码） |
| B7 | 每个新时钟域都有 **32 位自由计数**且进了快照 | 【先例】W5/W24（"数据面真在跑"的唯一正证据） | 3 个新域各 1 字 |
| B8 | `fe_src`/`dp_src`/新增束的拼接**恰好 NW*32 位** | 【先例】多一项被静默截断（门里 `findstr 10-3091` 当硬失败） | 精确 |
| B9 | 已知缺口 ①：`新 MAC` 的 `stat_flush_words`/`stat_flush_done` **已接进快照** | 【先例】`wrapper_p4.v:2226-2239` **未连接**（`P7B_DATAPATH_CONTRACT.md` E6，本文复核确认） | 两个新字 |
| B10 | 已知缺口 ②：两个 `fifo_async` 的 `ovf_cnt` **已接进快照** | 【先例】`P6E_OBS.md:86-87,232-234`（`ovf_cnt` 悬空，F-1 修复的板级缺口） | 两个新字（TX/RX 各一） |
| B11 | 快照的**束数**与定序已随新域扩展并写明 | 【自算】现役是"两束、FE 先→DP 后"（`snap_seq.v`）；新增 3 个域打破该结构假设 | 束数与**定序方向逐对写明**（有耦合的必须定向） |

**C 组 —— PCS/链路状态（板级）**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| C1 | `gtpowergood_out_0 == 1` | 【.veo】 | = 1 |
| C2 | `stat_rx_block_lock_0 == 1` | 【.veo】 | = 1（闸 1/2 期间） |
| C3 | `stat_rx_status_0 == 1` | 【.veo】+ 厂商 example（`block_lock & status` 点 LED） | = 1 |
| C4 | `stat_rx_hi_ber_0 == 0` | 【.veo】 | = 0。⚠️ **不能当零误码证据** |
| C5 | `stat_rx_local_fault_0 == 0` / `stat_tx_local_fault_0 == 0` | 【.veo】 | = 0 |
| C6 | `stat_rx_framing_err`（`_valid` 限定的那拍）累计 **= 0** | 【.veo】 | = 0 |
| C7 | `stat_rx_bad_code`（`_valid`）累计 = 0；`stat_rx_error[7:0]`（`_valid`）累计 = 0；`stat_rx_fifo_error` 累计 = 0 | 【.veo】 | 全 0 |
| C8 | ⭐ `stat_rx_valid_ctrl_code` **持续增长** | 【自算】我们确实在发 `/I/` `/S/` `/T/` ⇒ 对端（自环/网卡）必然回控制块 | > 0 且随窗口单调增**（正证据：证明这些状态线真的来自核，而不是被钉 0）** |
| C9 | 三个新域的 32 位自由计数在涨，Δ/墙钟 = 标称 ±1% | 【先例】W5/W24 的口径；标称 = 我们给它的时钟频率 | `tx_mii/rx_core ≈ 156.25 MHz`、`dclk ≈ 100 MHz` |

**D 组 —— XGMII MAC（功能）**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| D1 | ⭐ **字节序**：`tx_mii_d[7:0] == 帧首字节`、`tx_mii_d[63:56] == 帧第 8 字节` | 【厂商RTL】`pcs64_pkt_gen_mon.v:1148,1240`（期望值手写死） | 逐字节；**配变异负对照 N2** |
| D2 | ⭐ 帧首那一拍 = `/S/(0xFB, c=1) + 0x55×6 + 0xD5(c=0)`，**共 8 字节** | 【802.3】46.2.2（`P7B_BASER_TABLES.md` §2.2） | 逐字节 + `c[7:0]` 逐位 |
| D3 | 帧尾 `/T/(0xFD, c=1)` 落在**正确 lane**（位置随帧长变化） | 【802.3】46.2.1/49.2.4.9 | 各帧长各测一次（64/65/128/1518） |
| D4 | 帧间至少 **12 个 `/I/(0x07,c=1)`** | 【802.3】Clause 4.4（96 bits = 12 octets） | ≥ 12 |
| D5 | ⚠️ **收侧不假设 IPG 最小值**：对 **5 字节 IPG** 的输入也能正确成帧 | 【802.3】46.2.1（接收 RS 最小 5 octets）+ 46.3.1.4（DIC 短 3） | 5/9/12 三档各测 |
| D6 | 帧长：`<64B` 补 pad 到 60 内容字节；`>1518`（无 tag）/`>1522`（Q-tag）按 oversize 处理 | 【802.3】Clause 4.4 + 3.2.8；1G 版 `MIN_CLEN=60` 的踩坑史（`mac_tx_64.v:55-58`） | 边界点逐个：59/60/61/1517/1518/1519 |
| D7 | FCS：全帧残留 `== 0xDEBB20E3`；FCS = `crc ^ 0xFFFFFFFF` **LSB-first 上线** | 【合同】+ `crc32_8b.v:2-4`（板级实证：ping 5/5、FCS 错帧恒 0） | 残留 = 魔数；**`0xC704DD7B` 严禁混用** |
| D8 | 8 字节并行 CRC 与 `crc32_8b` **跨版本逐位一致** | 【自算】对拍：同一字节流分别过新旧两条通路 | 全等（含各种末字对齐） |
| D9 | 空闲时**持续发 `/I/`**（一个时钟沿都不停） | 【802.3】49.2.4.7【推定】 | 空闲窗口内每拍 c = `8'hFF` 且 d = `8'h07×8` |
| D10 | 帧流合同 9 条逐条成立（FWFT/SOP/TLAST/FCS 剥离/无裸尾/TERM/守恒律） | 【合同】`mac_rx_64.v:2-58` 的原文 | 逐条 |
| D11 | 丢帧补 TERM 五元组：`tdata=0,tkeep=0,tlast=1,tuser=0,tcrs=0,terr=1` | 【合同】`mac_rx_64.v:39-40,199-206` | 逐位 |
| D12 | F-2：帧内中止后**冲刷到本帧 TLAST**，一个字都不发 | 【合同】`mac_tx_64.v:232-244` | 判据 `frd && !fempty && fdout[0]` |
| D13 | `stat_fifo_ovf`（RX 内部 FIFO 拒写）**结构上恒 0** | 【合同】`mac_rx_64.v:83,189-190` | = 0（非 0 = 有字被静默丢） |
| D14 | 守恒律（新 MAC 口径）：`#(TLAST 且 tkeep≠0) == stat_frames`；`Σpopc(tkeep) == stat_bytes − 4·stat_frames + stat_orphan_bytes`；`stat_drop_partial ≤ stat_drop_full ≤ stat_drop` | 【合同】`mac_rx_64.v:48-53` | 逐式 |
| D15 | 计数器**命名**与 1G 版逐字相同 | 【合同】§A.4（改名会让板级验收脚本**静默读错**） | 逐名 |
| D16 | 帧内中止仍留 runt（线上语义不变）+ `stat_abort` 计数 | 【合同】`mac_tx_64.v:32` §⑤ | —— |

**E 组 —— `rx_classify` ③**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| E1 | ⭐ **吞吐门**：`1 字/拍` 连续输入、背靠背最小帧（TCP 与非 TCP 各一条）⇒ 输出字数 == 输入字数 | 【自算】`N/(N+停顿)`：非 TCP `8/11`、TCP `8/14`（审计件 §4.2） | **100%**（不是"不丢字"） |
| E2 | A/B 负对照：未改造版本跑同一条门 ⇒ **FAIL** | 【审计】§4.2 的算数 | 期望 FAIL |
| E3 | 既有背压门（NOSTALL/STALL/HARD）**不回归** | 【先例】`sim/p4sim/run_tb_rxclass.bat` 三模式逐字比对 | PASS |
| E4 | 上板：最小帧洪泛下 `stat_drop_full`（W34）增量 **恒 0** | 【先例】`P6E_OBS.md:80` | ΔW34 = 0 |
| E5 | 不引入丢字/乱序/半帧 | 【合同】§A.1.2 第 5/7 条 | 判据**不许放宽** |

**F 组 —— 网络层（端到端）**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| F1 | 闸 2 的 E1..E7（§5.2 那张表，**逐条都要**） | 802.3 对端 | 见 §5.2 |
| F2 | `ping` 通（10G 口上） | ICMP 往返 | 5/5 且 rtt 合理（对照 1G 的 0.091–0.128 ms 量级） |
| F3 | 图案流逐字节（**用 fast path，不用 app 的 1 字节/拍校验器当速率判据**） | 【先例】P6b 三个独立口径吻合 | 逐字节 |
| F4 | 速率：板子自报 × 帧长 与 网卡硬件计数对账 | 【先例】P6b 口径（956.0 Mbps = 99.9%） | 偏差 < 1% |
| F5 | TCP fast path 在 10G 下不掉链（RTO/重传计数不异常） | 【先例】P6b 基线 | 定性 |

**G 组 —— 观测完整性**

| # | 判据 | 期望来源 | 期望值/形式 |
|---|---|---|---|
| G1 | 快照**每一个字**都有明确的"生产者节点"归档 | 【先例】`P6B_INTEGRATION_REVIEW.md` §1.3 的做法（按 wrapper 拼接逐项读出） | 逐字一行 |
| G2 | 每轮触发**自证**：`SNAP_STATUS.gen` 恰好 +1；36/新字数**无空读** | 【先例】`_proj_pcie/p6b_accept.sh` 的 `round()` 四层守卫 | 任一失败 ⇒ 整轮读数作废 |
| G3 | 频率类判据的窗口 **< 20 s** | 【先例】32 位 @156.25 MHz 每 **27.49 s** 回绕（`P6E_OBS.md:70`） | 窗口 < 20 s |
| G4 | 未实现地址回 `0xffffffff`，**同趟**读一个已实现字作对照 | 【先例】`P6B_ACCEPT.md` A5（0xB0 回 `0xffffffff` / 0x14 回 `0xdeadbeef`） | 两个读数都要有 |

### 6.2 负对照表（**单独列，9 条**）

> ⚠️ 负对照的**唯一目的**是证明判据有牙。**期望 FAIL 而实际 PASS ⇒ 判据是真空的，整轮作废。**

| # | 负对照 | 做法 | 期望 | 证明了什么 |
|---|---|---|---|---|
| N1 | **SFP `TX_DIS` 强拉高** | 把 `sfp1_tx_dis` 临时驱动为 1（或去掉驱动让其被 10k 上拉） | 链路**全黑**（`block_lock=0`、两方向都收不到） | 引脚映射正确 + 我们的 TX_DIS 控制真的在线 |
| N2 | **字节序变异** | `bswap64` 改直通 / 改"翻两次" | 判据 D1 与闸 1c 的比对 **FAIL** | D1 有牙（**这是 §3.3 专门判据的负对照**） |
| N3 | **`snap_idx` / `snap_base` 位宽回退** | 分别改回 5 位 / 10 位 | 逐字读回门 **FAIL**（高地址字读回低地址字） | 扩窗陷阱可被门抓到（本工程实测过：13d=8 字错 / 15b=0x320） |
| N4 | **force 打错节点** | 快照字的 force 打在 wrapper 线上（而非生产者子模块端口） | 把生产者改回悬空时门**仍然 PASS** ⇒ 该门被判为无牙、必须改 | "生产者↔线断开"这类错只能靠打生产者节点抓（P6e 实测） |
| N5 | **环回断开** | 1a：关 GT 环回；1b：拔 AOC | 闸 1 判据 **FAIL** | 闸 1 不是恒真 |
| N6 | **坏 FCS 帧** | 主动发一个 FCS 错的帧 | NIC **不呈现**该帧 / 计入 FCS 错 | E3/E5 的"帧出现了"不是真空 |
| N7 | **不修 `rx_classify`** | 用未改造版本跑吞吐门 | **FAIL**（赤字 > 0） | 吞吐门有牙（E2） |
| N8 | **状态线钉常量** | 把某个 `stat_*` 钉 0（仿真） | 对应的 C 组判据（尤其 C8 `valid_ctrl_code` 增长）**FAIL** | 快照字真的来自核，不是"恒 0 的假干净" |
| N9 | **不发 idle** | 让 TX MAC 空闲时停发（不补 `/I/`） | 对端 `block_lock` 掉 / NIC `Link detected: no` | D9 与 E1 有牙 |

---

## 7. 可观测性

### 7.1 现役窗口与**硬上限**（本次自查确认）

- 现役：**36 字**（W0..W35），地址 `0x20..0xAC`，分**两束**（FE 14 字 = `gmii_clk` / DP 22 字 = `dp_clk`），
  由 `rtl/snap_seq.v` **链式定序（FE 先 → DP 后）**；`SNAP_NW_P6E = 36`（`wrapper_p4.v:2545-2547`）。
- 第一个未实现地址 = **`0xB0`**（`P6E_OBS.md:82`）。
- ⭐ **硬上限（本规格书自查，可复核）**：`_proj_pcie/rtl/axi_regs.v:173` `wire [5:0] ar_word = s_axil_araddr[7:2];`
  ⇒ **地址每 256 字节回绕**；快照从 `word 8` 起（`:117`），最大 `word 63` = `0xFC`
  ⇒ **快照窗口最多 56 字**（`word 8..63`）。现用 36 ⇒ **只剩 20 字（`0xB0..0xFC`）**。
  ⚠️ 超过 56 字就**必须动地址译码**（`ar_word` 位宽/基址偏移），那会破坏"未实现地址 ≠ 实现地址"这条判据形式
  ⇒ **动之前必须先设计新的负对照**。
- ⚠️ `axi_regs.v:74` 的注释"**上限 = 32**"与 `:220-221` 的"10 位是硬上限"**都是过时的**（36 字版已把
  `snap_idx` 加宽到 6 位、`snap_base` 到 11 位，`:212`/`:222`）⇒ **以代码为准**（本规格书已逐行核过）。

### 7.2 ⚠️ 两个**已知缺口必须接出来**（本次已复核确认）

| 缺口 | 现状（逐行可核） | 后果 | P7b 要求 |
|---|---|---|---|
| ① `mac_tx_64` 的 **F-2 观测** | `board/wrapper_p4.v:2226-2239` 只接了 `stat_frames`/`stat_abort`，**`stat_flush_words` / `stat_flush_done` 未连接**；36 字里也没有对应字（**本次 grep + 逐行读确认**） | **F-2 修复的板级证据拿不到**（只能靠仿真门） | 新 MAC 的这两个计数**必须进快照**（新增 2 字） |
| ② `fifo_async` 的 **F-1 观测** | `rtl/fifo_async.v:142-143` 有 `ovf_pulse/ovf_cnt`（`:212` 单驱动累加），但 `wrapper_p4.v:2205-2212` 的两个例化**都没接**（**本次 grep 确认**）；快照无对应字 | **CDC FIFO 自身的丢字无法归因** | ⭐ **P7b 的新跨界 FIFO 必须把 `ovf_cnt` 接进快照**（TX/RX 各 1 字）。⚠️ 它统计的是**所有**被拒的写（含正常运行时的满反压与复位释放窗口）⇒ **正确用法是差分**，不是要求恒 0 |

### 7.3 新增快照字**提案**（共 +18 字 ⇒ 窗宽 54，**距硬上限 56 只剩 2 字**）

| 字 | 内容 | 束（域） | 为什么必须 |
|---|---|---|---|
| W36 | PCS 状态位束 `{gtpowergood, block_lock, rx_status, hi_ber, local_fault, framing_err_valid, bad_code_valid, error_valid, fifo_error, tx_local_fault, sfp1_rx_los, sfp2_rx_los}` | dclk【推定】 | §3.2 的全部状态；**一位都不能悬空** |
| W37 | `stat_rx_valid_ctrl_code` 计数（控块正证据） | dclk | C8 的**正证据**（防"恒 0 假干净"） |
| W38 | `stat_rx_error[7:0]` 累计（逐 lane 错） | dclk | C7 |
| W39 | `stat_rx_framing_err` 累计（`_valid` 限定） | dclk | C6 |
| W40 | `txmii_free`（TX MII 域自由计数） | **TX-MII** | B7/C9（新时钟域的正证据） |
| W41 | `rxcore_free`（RX 恢复域自由计数） | **RX** | B7/C9 |
| W42 | `dclk_free`（dclk 域自由计数） | **dclk** | ⭐ **A5 的唯一实测手段**（证明 `dclk` 真在 100 MHz） |
| W43 | `mac_tx_flush_words`（缺口 ①） | TX-MII | B9 |
| W44 | `mac_tx_flush_done`（缺口 ①） | TX-MII | B9 |
| W45 | `txcdc_ovf_cnt`（缺口 ②，DP→TX-MII 方向） | DP 或 TX-MII（**必须按它自己的写域定**） | B10 |
| W46 | `rxcdc_ovf_cnt`（缺口 ②，RX→DP 方向） | RX 或 DP（同上） | B10 |
| W47 | XGMII TX 侧：发帧数 / 发字节数 | TX-MII | D 组统计 |
| W48 | XGMII RX 侧：收帧数 / 坏 FCS 帧数 | RX | D7/D14（**零误码的唯一判据面**） |
| W49 | XGMII RX 侧：runt / oversize / IPG 违规 / 控制码异常 | RX | D3/D5/D6 |
| W50 | `rx_classify` 改造后的观测（如"决策窗未阻塞的帧数 / 输出停顿拍数"） | DP | ③ 的**正面证据**（不能只靠"没丢帧"反推） |
| W51 | 上游 FIFO 占用峰值（`dbg_occ_w` 类）| DP | ③ 的弹性预算证据 |
| W52 | `sfp{1,2}_rx_los` 的**变化沿计数**（不是电平） | dclk/FE | 光模块在位/掉线的**历史**（电平只给瞬时） |
| W53 | 新增域的"束定序"自证：各束快照的**代际号**（gen）逐束可见 | axi | B11（证明多束定序真的成立，而不是靠单测一次） |

⚠️ **这 18 字是提案，不是定稿** —— 定稿前必须：
① 逐字核对**生产者节点**（G1）；② 算清**总字数 ≤ 56**（B6）；③ 定**每条束的定序方向**（B11）；
④ 把"未实现地址"挪到末字 +1（B5，**新值必须 < 0x100**）。

### 7.4 扩窗陷阱（**逐处同改清单：现役 7 处 ⇒ P7b 9 处**）

| 处 | 位置 | 漏改的症状 |
|---|---|---|
| ① | wrapper 的 `SNAP_NW_P6E`（单一来源） | 全链错位 |
| ② | 每束 `snap_src` → `fe_src`/`dp_src` 的**拼接项数** | 少一项 ⇒ 高位悬空（读回 X）；多一项 ⇒ 被截断 |
| ③ | ⭐ **`axi_regs` 的 `snap_idx` 位宽 + `snap_base` 位宽** | **只改一处 ⇒ 未实现地址静默回绕成 W0..W3 = 假 PASS**（本工程踩过，`P6E_OBS.md:100-104`） |
| ④ | `axi_regs.SNAP_NW` | —— |
| ⑤ | 验收/采样脚本里"未实现地址"的取值 | 会把"新功能上线"判成回归；⚠️ **绝不能挑 ≥0x100**（别名到 MAGIC/已实现字） |
| ⑥ | 三道门自己的参数（`tb_axi_regs` 的 `.SNAP_NW`/`snap_din` 位宽/`w8` 长度、`tb_snap_cdc` 的 `NW`、wrapper 门的 force 清单与 `BUILD_ID` 期望） | 门"看不见"新字（16 字版当年就是这样让 `snap_base` 截断潜伏） |
| ⑦ | `rtl/snap_seq.v` 的 `fe_idx_of`/`dp_idx_of` 索引表 | 读出"另一个字的正确值"，单测一遍看不出来 |
| **⑧（新）** | **束数**（2 → N）与**每束的 `snap_cdc.NW`** | 新域的字进不了快照或串到别的束 |
| **⑨（新）** | **链式定序方向**（`snap_seq` 的 FSM） | 跨域对账判据退化成对称容差 `\|Δ\|≤1`，**失去方向性**（`P6E_OBS.md` §三） |

---

## 8. 未覆盖清单与证据强度标注

### 8.1 未覆盖清单（**本规格书/本轮不闭合的**）

| # | 未覆盖项 | 为什么不覆盖 | 谁来闭合 |
|---|---|---|---|
| X1 | **PCS-only 位流能否在板上跑、有无功能/时间限制** | 位流已生成但**从未上板**（侦察纪律）；`[Vivado 12-1790]` 有"will cease to function after a certain period of time"的**笼统**措辞（**无任何具体期限**，license 是 `permanent`） | **闸 1a 的第一件事**（§5.1a） |
| X2 | **控制块的 `txheader[5:0]` = `6'b000010`** | 该值属 **P7a 路线的接口**；P7b 路线下 `txheader` **不在我们的端口面上**（核内接）⇒ **对本轮不构成风险** | 不需要（路线已改） |
| X3 | **`txdata` 的 64 bit ↔ 线上字节的绝对位序**（P7a 的 U3） | 同上：官方核的 XGMII 面**已经**把这一层封装好了；我们要面对的是 **XGMII 的 lane 语义**（已用厂商明文 RTL 定案，§3.3） | 由闸 1c / 闸 2 覆盖 |
| X4 | **加扰器在哪一层**（P7a 的 U2） | 官方核内部负责（其 PRBS31 种子是 **58 位**，与 `1+x³⁹+x⁵⁸` 同阶 ⇒【推断】加扰在核内 soft logic） | 由闸 2 的 E1（链路锁得上）间接覆盖 |
| X5 | `app_udp_pattern` 的 RX 校验器 1 字节/拍 | N3 明确不做 | 后续轮次 |
| X6 | HLS 慢路径的 10G 化 | N4 明确不做 | 后续轮次 |
| X7 | TCP fast path 在 10G 吞吐下的行为（窗口/RTO 时标） | N5 明确不做 | 后续轮次 |
| X8 | SFP 模块的型号/温度/DOM | 底板未引出 I2C | 物理上不可做 |
| X9 | 手册"12 GHz"边界（Aurora 64b66b）与本设计的关系 | 本轮只到 10.3125 GBd | 不适用 |
| X10 | `INS_LOSS_NYQ=30` / `RX_TERMINATION=PROGRAMMABLE 800` 与 `gt_10gbr` 差异对 BER 的影响 | 只回读到值，未做板级 A/B | 若要贴官方工作点再做 |
| X11 | **长期稳定性（soak）** | 各闸的时长未定到小时级 | 按 `P7A_RESULT.md` §7 的口径登记 |

### 8.2 证据强度标注（本规格书用到的每条关键结论）

| 结论 | 等级 | 依据 |
|---|---|---|
| 本机能出 PCS-only 位流；MAC+PCS 位流被 license 拒 | 【已实测】 | `pcs64/.../impl_1/runme.log:824,826,827`；`macpcs64/.../runme.log` 尾部（两次复现）；§0.1/§0.2 |
| `-1` 上时序收敛（PCS-only `WNS +2.337 / WHS +0.019 / 0 失败端点`） | 【已实测】 | `probe_pcs64_top_timing_summary_routed.rpt`（[转述自] `P7B_XXV_OFFICIAL.md` §5.2） |
| 硬块（scrambler/encoder/decoder/WD_ALIGN/hi_ber）在 fabric 里真实存在 | 【已实测】 | 路由后报告的层次单元名（`i_TX_SCRAMBLER` 等，转述自 §4.6） |
| **官方 XGMII = lane0 首发** | 【明文RTL】 | `pcs64_pkt_gen_mon.v:1148,1169,1199,1240`（**本次未逐行读该文件**；行号与摘录来自 `P7B_XXV_OFFICIAL.md` §3.4 ⇒ 严格说这一条是【转述自…】，列入 §11 U7 待回核） |
| 我们的合同 = `tdata[63:56]` 首发 | 【明文RTL】+【板级实测】 | `rtl/mac_rx_64.v:2-8`；P6b 板级 35/35 验收 |
| `gt_10gbr` 板级 BER `4.997×10⁻¹³` | 【板级实测】 | `P7A_RESULT.md` / `_proj_10g/reports/p7a_bitstream_sha256.txt` |
| 官方核内部 GT 配置与 `gt_10gbr` **逐项相同**（除 `FREERUN_FREQUENCY` / 通道数） | 【已实测】 | 子核 `.xci` 回读（转述自 §4.5 的对账表） |
| `FREERUN_FREQUENCY=100.00` 的来源 = `dclk` | 【推定】 | GT 内部加密；OOC XDC 有 `dclk` 10.000（明文） |
| 端口 `_0` 后缀 = 端口/核索引（2 端口时会有 `_1`） | 【推定】 | `.veo` 里全套端口都带 `_0` 且该配置是 1 通道 ⇒ 见 §11 U1 |
| `rx_classify` 未改造、上限 57.1%、10G 必触发 | 【明文RTL】+【自算】 | 审计件 §1-§5（本次抽查确认 `rx_classify.v:9-11,52,58,60-65,102-103`） |
| `snap_idx`/`snap_base` 现为 6/11 位、窗口硬上限 56 字 | 【已实测】 | `axi_regs.v:173,212,222`（**本次逐行读过**） |
| 两个已知观测缺口（F-2 未接、`ovf_cnt` 悬空） | 【已实测】 | `wrapper_p4.v:2226-2239`（逐行读）/ `:2205-2212`（grep）+ `fifo_async.v:142-143` |
| 对端机 `192.168.0.38` 是 SFC9120 10G 双口、口名 `enp1s0f0np0`/`enp1s0f1np1`、内核 7.0（Onload 装不上、DPDK 可走） | 【转述自】 | 记忆件 `eco-linux-peer-box.md`（2026-09-28 实测）⚠️ **闸 2 开工前必须现场复核**（`lspci`/`ethtool`） |

---

## 9. 风险清单

| # | 风险 | 现象/早期信号 | 缓解 | 验证手段 |
|---|---|---|---|---|
| **R1** | ⚠️ **hold 余量一贯很薄** | 加逻辑后 hold 先出问题；`WHS` 是正数但极小 | 每轮加逻辑后**先看** `*_timing_summary_routed.rpt` 的 WHS 与 hold 失败端点族；必要时 `phys_opt` | 本器件先例：PCS-only `WHS **+0.019**`、MAC+PCS `+0.023`、P6a `+0.012/+0.013` ⇒ **记录数值，不设下限** |
| **R2** | **含 MAC 的官方变体位流被 license 拒**（未来若要官方 MAC 需**高于 `Design_Linking`** 的 `xxv_eth_mac_pcs` license） | `write_bitstream` 报 `[Common 17-69] ... not permitted` / `require licenses greater than a Design Linking license` | **设计不得依赖官方 MAC**；若要换，先拿 license 再谈 | 已两次复现（§0.2）；`Xilinx.lic` 里所有 `INCREMENT` 都是 `License_Type:Design_Linking` ⇒ 换别的特性也绕不过去 |
| **R3** | **官方核 RTL 全加密** | 出问题只能靠外部观测，读不到实现 | ① 把**全部**状态接出来（§3.2）；② 关键行为用**厂商明文 example/monitor** 当参照（闸 1c）；③ 判据全部落在"输入/输出合同"上 | `xxv_ethernet_v5_0_vl_rfs.sv` 除 pragma 头外**全是 base64 密文**（非 base64 行 = 0） |
| **R4** | ⭐⭐ **位流从未上板**（**本规格书最薄的一环**） | 一切静态结论都可能在板上被推翻 | **闸 1a 作为第一件事**，先只验"核能起 + 状态正常 + 环回自洽"，再往上叠 | `p7a` 没有任何上板记录；`[Vivado 12-1790]` 的"will cease to function"措辞**无具体期限** |
| **R5** | **端口表随配置变化**（`_0` 后缀语义未核实） | 例化时端口名/位宽对不上，或**多端口的第二份端口没接** | 改配置后**重读 `.veo` 并归档**；例化前逐条对表 | §11 U1 |
| **R6** | **快照"两束"结构假设被打破** | 新域的字进不去/串到别的束/对账判据失去方向性 | §7.4 的 **9 处同改**；束定序**逐对写明方向** | 逐字读回门 + 束定序负对照（正例 41/41 的模板：`tb_int_snapseq.v`） |
| **R7** | **`rx_classify` 的 57.1% 天花板在 10G 必然触发** | 最小帧洪泛下 `stat_drop_full`（W34）持续增长；TCP 重传、UDP 永久丢 | 工作项 ③（收字与决策解耦）；**加深 FIFO 无效** | 新增吞吐门（`1 字/拍`）+ 板级 D4 |
| **R8** | **app 侧 1 字节/拍被误读成 MAC 缺陷** | 10G 速率判据卡在 ~1.25 Gbps 且 `udp_split` 帧缓冲长期贴满（`stat_drop_ovf`） | **速率判据只用 fast path / 板子自报 / 网卡硬件计数**（N3） | F3/F4；`udp_split.v:464` 的 512 字帧缓冲是既有边界 |
| **R9** | **计数器改名/改口径 ⇒ 验收脚本静默读错** | 板级脚本判"新功能上线"为回归 | 计数器**逐字保留**（D15）；改口径必须**同批改脚本 + 加负对照** | A16/B5 |
| **R10** | **CDC FIFO 的 `full` 悲观语义 + 复位契约被违反** | 丢字但不可观测（`ovf_cnt` 悬空的老坑） | 两侧复位**同时给**；只在 `full==0` 置 `wr_en`；`ovf_cnt` **接进快照**（B10） | N5/N8 + `sim/fifoasync` 的 12 门 + 7 变异 |
| **R11** | **`dclk`/`FREERUN_FREQUENCY` 错配** | 复位 FSM 定时器按错的频率跑（偏 1.5625×） | `dclk` 供 **100 MHz**；实测频率进快照（A5/W42） | §3.6 专项 |
| **R12** | **`err` 类判据"恒 0"是假的**（状态线没接出/被钉死） | 所有 `stat_*` 读 0，看着"完美" | ⭐ **必须有至少一条"非 0 且持续增长"的正证据**：C8（`valid_ctrl_code`）+ C9（三个新域自由计数）+ G2（快照自证） | 这三条同时成立才允许把"恒 0"当结论 |
| **R13** | **构建/测量纪律被破** | 构建期间从被构建的工程烧位流 ⇒ 读数与源码不对应 | 铁律：构建期间**不烧**；每次测量前**重烧**；烧完**重启主机**（PCIe 观测）；判活**看 BAR 不看 `lspci`** | G5 |
| **R14** | **假故障陷阱：SFP `TX_DIS` 悬空** | 两方向全黑，**极易误判成"板子做不了 10G"** | 显式驱动 **C11/D9 低**；每闸先读 `rx_los` | N1 负对照 + §3.7 |
| **R15** | **真空门复发** | 门 PASS 但跑的是另一个 checkout / 门槛没跑 | 门一律走**自定位**入口（`sim/p4gates/run_matrix_p4dfix.bat`）；关键判据**必须带负对照** | 本工程曾有多达 243 个真空门（已修 340 个 + 加守卫） |

---

## 10. 复用清单（别重造）

| 复用件 | 内容 | 注意 |
|---|---|---|
| `rtl/fifo_async.v` | 参数化灰码异步 FIFO（WIDTH/DEPTH/FWFT/AW 全参数），**已板级验证** | 三条硬契约（§3.4）；FWFT=1 ⇒ LUTRAM；**接出 `ovf_cnt`**（缺口 ②） |
| `rtl/fifo_sync.v` | 同步 FWFT FIFO + `full_next`/`ovf_pulse` 探针（F4 的关键件） | `W/D/AW` 全参数，可直接复用 |
| `rtl/crc32_8b.v` 的**语义** | 反射多项式 `0xEDB88320` / 初值 `0xFFFFFFFF` / 无终值取反 / 残留 `0xDEBB20E3` | **实现要换成 8 字节/拍**；语义**逐条保住** |
| `rtl/mac_tx_64.v` 的 `S_FLUSH` **判据** | `frd && !fempty && fdout[0]`（FWFT 依赖） | 判据照搬，实现重做 |
| `rtl/mac_rx_64.v` 的 F4 三门槛 + TERM 五元组 + 守恒律 | `push_ok`/`push_frame_ok`/`term_fire`；`mac_rx_64.v:2-58` 的 9 条合同 | **逐条照搬** |
| `_proj_10g/rtl/gt_10gbr_example_stimulus/checking_64b66b_async.v` | PRBS31 收发 + gearbox 位序反转 + 滑位 hunt | ⚠️ **P7b 路线下这些功能在官方核里** ⇒ 只在**做对照件/单元测试**时当参照，**不进正式数据通路** |
| `xxv_probe/pcs64_ex/.../pcs64_pkt_gen_mon.v` | 厂商明文图案发生器/监视器（XGMII 面） | ⭐ **闸 1c 的对端**（非对称字节序判据） |
| `_proj_10g/tcl/build_p7a.tcl` | 工程创建 + `report_timing_summary` + WNS/WHS 打印骨架；KU5P `create_project -force` 流程 | 直接改 top/源文件表即可 |
| `_proj_10g/board_scratch/probe_p7a_board.tcl` | VIO 读写 + **快照协议** + 负对照 + 窗口测量；含"大数不过 `format`"与"取数前必 snapwait"两条护栏 | ⭐ 板级脚本的模板 |
| `_proj_pcie/p6b_accept.sh` | `rd()`/`rd_new()`/`snap()`/`round()` **四层守卫**（MAGIC 在 + gen 恰好 +1 + 逐字无空读） | ⭐ 闸 4 的验收脚本模板 |
| `sim/p4gates/run_matrix_p4dfix.bat` | 自定位 + 路径守卫 + 修订指纹 + 每门独立工作目录的矩阵入口 | 跑门**一律**用它 |
| `_proj_mdio/probe_phy.tcl` 头注释 | VIO over JTAG 的**五个 API 坑** | 若用 VIO 观测（不用 PCIe 时） |
| `_ibert/constr/ibert_top.xdc` | refclk 引脚/周期 + SFP 四脚（含 PULLUP 与"厂商两份 XDC 都错"的理由） | 直接抄 |
| `_proj_10g/rtl/clk_gen_p6b.v` | Y1 100 MHz → MMCM ×1.5625 = 156.25 MHz（`dp_clk`） | 若还要 100 MHz（`dclk`），需另出一路 |

---

## 11. 未核实清单（**严禁当结论用**）

| # | 未核实项 | 为什么重要 | 怎么核 |
|---|---|---|---|
| **U1** | **端口 `_0` 后缀的语义**（端口/核索引 vs 通道索引）；**2 端口配置下的完整端口表**（是否出现 `_1` 全套、位宽是否变化） | **直接决定例化代码与引脚映射**；闸 1 又必须 2 端口 | 改 `CHANNEL_ENABLE` 后**重读 `.veo`**（明文，几分钟）；把旧/新两版 `.veo` 归档对账 |
| **U2** | `align_status` 能否用 ILA/`mark_debug` 单独观测（加密核内部单元） | 决定"字对齐"这一层有没有独立观测面 | 试 `mark_debug` + 布局；失败则接受"只能看 `stat_rx_status`" |
| **U3** | 新 MAC ↔ `fifo_async` 的**字宽**（73/76 是否仍够；新 MAC 是否要 `sop` 边带） | 接错宽度 ⇒ **静默截断最高位 = 每字首字节**（本工程已有先例） | 逐字对照 `din`/`dout` 拼接与 `WIDTH`（四处同改） |
| **U4** | `sys_reset` 的**配方**（有效电平确认、最小宽度、与 `dclk` 的关系） | 复位不对 ⇒ 核起不来或间歇 | 读厂商 example 的板级顶层（不在本探针）或做一次最小上板实验 |
| **U5** | PCS-only 的 **PRBS 测试图案**能不能当判据（`.veo` 里**没有**图案失配状态输出） | 决定"能不能用它做免 MAC 的自检" | 读 PG 文档 / 或改用 XGMII 层的 `pcs64_pkt_gen_mon`（闸 1c） |
| **U6** | `gt_loopback_in_0[2:0]` 各模式的**语义**（PCS 级？PMA 级？各模式环路在哪一点） | 闸 1a 的**覆盖范围**（决定它证明了哪几层） | 查 UG578（**本地没有**，见 `P7B_PHY_IFACE.md` §8）/ 或做 A/B 实验 |
| **U7** | `pcs64_pkt_gen_mon.v` 的 `swapn` 语义我**没有逐行读原文**（行号与摘录来自 `P7B_XXV_OFFICIAL.md` §3.4） | ⚠️ **§3.3 的字节序结论（整个高危点的方向）建立在这条上** | ⭐ **回原始文件核 `:1148/:1199/:1240`**（5 分钟）；**闸 1c 正是这条的板级闭合** |
| **U8** | 官方核 `stat_*` 输出的**时钟域**（我按 `dclk` 推定） | 决定进快照前怎么同步（**多比特不能直接两级同步**） | 读核内 OOC XDC 的 CDC waiver 列表（明文）；或加 ILA 实测 |
| **U9** | `user_rx_reset_0`/`user_tx_reset_0` 的**时钟域与极性** | 用它当 MAC 复位源的前提 | 同上 |
| **U10** | `rx_reset_0`/`tx_reset_0` 的**确切语义**（"用户请求复位核" vs "核通知用户"） | 决定我们要怎么驱动它 | 读 PG / 看 IP 内部 CDC 单元的方向（`i_*_core_cdc_sync_gt_rx_resetdone_0` 的形态，`P7B_XXV_OFFICIAL.md` §5.4 坑 1 的原文行） |
| **U11** | 2 通道配置能否出位流（探针只验过 1 通道） | **闸 1 的前置** | 建一次 2 通道工程跑到 `write_bitstream`（不需要板子） |
| **U12** | `[DRC AVAL-326]` 会不会在别的场景升级成错误；能否给它定 LOC（本次 `get_sites` 返回 0） | 位流的确定性 | impl-only XDC 里试 `set_property LOC IBUFDS_GTE4_X0Y1` |
| **U13** | `dclk` 的**实际**频率（我们板上的 100 MHz 从哪取、有没有 BUFG 余量） | A5 的实测对象 | 置 W42 的 dclk 自由计数后上板 |
| **U14** | 对端机 SFC9120 的 **10G 口现状**（哪一口、模块在位否、驱动/固件状态、`ethtool -S` 字段名） | 闸 2 的**全部判据**都依赖它 | 闸 2 开工前现场复核（记忆件是 2026-09-28 的快照） |
| **U15** | 线缆**现状**（AOC 的两端现在插在哪） | 闸 1b/闸 2 的前置 | **问装配要问"线两头分别插在哪"**（本工程既有教训） |
| **U16** | 官方核在 **xsim** 里能不能跑（作为参照物） | 若能跑，可以拿 "MAC+PCS 变体"当**金标准**在仿真里对我们的 MAC 做整帧进出比对（`IS_LOCKED=0` + `*_exdes_tb.v` 已生成 ⇒ 应该可以） | 起一次 xsim（`xxv_probe/*_ex/`） |

---

## 12. 证据索引

| 内容 | 位置 |
|---|---|
| PCS-only 能出位流 / MAC+PCS 被 license 拒（原文行） | `_proj_10g/xxv_probe/pcs64/pcs64.runs/impl_1/runme.log:801-807,824,826,827`；`.../macpcs64.runs/impl_1/runme.log` 尾部 |
| 8 个 `CONFIG.*` + 不动点迭代 | `_proj_10g/xxv_probe/tcl/s2_config.tcl`；`logs/s2_config_stdout.txt`（`S2_CONVERGED_AT_ROUND`/`S2_POSTGEN_MISMATCH_N`） |
| `CONFIG.CORE` 静默重置其它参数 | `logs/s1_prepare_stdout.txt`（`CFG_pcs64 CONFIG.LINE_RATE = 25` 等） |
| GT 通道 = `X0Y4` | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/ip_0/pcs64_gt.xci`（`CHANNEL_ENABLE` / `TX_REFCLK_SOURCE`） |
| **PCS-only 完整端口表（53 端口）** | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/pcs64.veo:58-110`（**本次逐行读过**） |
| OOC 三个用户时钟 | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/synth/pcs64_ooc.xdc`（`6.40`/`10.000`/`6.400`） |
| IP 不碰引脚（board.xdc 空 / 无 PACKAGE_PIN） | 同目录 `synth/pcs64_board.xdc`（空）、`synth/pcs64.xdc` |
| `rx_core_clk_0 = rx_clk_out_0` 自环（+ 备选被注释） | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_exdes.v:94-98` |
| 厂商 example 把 `rx_reset`/`tx_reset` 当**输出**驱动、把 `user_*_reset` 当**输入**消费 | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v:74-75,100-101`；实例化 `pcs64_exdes.v:255-311` |
| 厂商 example 的 XDC 是**别的板子**的（IOSTANDARD LVCMOS18 / 引脚被注释） | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_example_top.xdc:69-106` |
| `align_status` 在核内（被 false_path 引用） | 同文件 `:132-133` |
| **XGMII lane0 = 首发字节** | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v:1078,1148,1169,1199,1240`（**行号转述自 `P7B_XXV_OFFICIAL.md` §3.4/§8，见 U7**） |
| 路由后时序（-1） | `xxv_probe/pcs64/pcs64.runs/impl_1/probe_pcs64_top_timing_summary_routed.rpt` |
| 资源（IP 本体） | `xxv_probe/pcs64/pcs64.runs/pcs64_synth_1/pcs64_utilization_synth.rpt` |
| 坑 1/2/3 原文（复位悬空 / `rxrecclkout` / `AVAL-326`） | `xxv_probe/pcs64/pcs64.runs/impl_1/runme.log:247,639,664`；`.../macpcs64.runs/impl_1/runme.log:117,118,183,252,644,669` |
| 冻结合同（9 条 + 端口语义） | `_proj_10g/notes/P7B_DATAPATH_CONTRACT.md` §A.1.1/A.1.2/A.2/A.4/E6 |
| F4 三门槛 / TERM 五元组 / 守恒律 | `rtl/mac_rx_64.v:48-53,83,121-135,189-208,237,248-263,337-341` |
| F-2 `S_FLUSH` 判据 | `rtl/mac_tx_64.v:224-244` |
| CRC 三条语义 + 残留魔数 | `rtl/crc32_8b.v:2-4`；`rtl/mac_rx_64.v:96`；`rtl/mac_tx_64.v:170,213` |
| 1G MAC 的字节串行开销（每拍一字节） | `rtl/mac_tx_64.v:143-223`（S_PRE/S_DATA/S_PAD/S_FCS/S_IFG） |
| `rx_classify` as-built + 上限 + 门缺口 | `rtl/rx_classify.v:5-11,52,58,60-65,78-85,102-103`；`_proj_10g/notes/P7B_RXCLASSIFY_AUDIT.md` §1-§5 |
| 10GBASE-R / XGMII 常量（控制码 / 块类型 / 前导 / IFG / 帧长 / FCS / 加扰） | `_proj_10g/notes/P7B_BASER_TABLES.md` §1-§5（IEEE 802.3-2008 Section 1/4 原文转录） |
| GT fabric 接口冻结（**P7a 路线，已降级为背景**）+ 第 646 行订正 | `_proj_10g/notes/P7B_PHY_IFACE.md` §0-§5/§8/§10.2 |
| 开源库侦察（**路线已作废**，加扰器/块锁/XGMII 分析可作旁证） | `_proj_10g/notes/P7B_LIB_SURVEY.md`（尤其 TL-1..TL-6） |
| 现役 36 字快照窗口 + 扩窗 7 处清单 + 两个已知缺口 | `P6E_OBS.md` §一/§五 |
| `snap_idx`/`snap_base`/`ar_word` 位宽与回绕红线 | `_proj_pcie/rtl/axi_regs.v:43-47,74-78,173,200-222,241-245`（**本次逐行读过**） |
| `snap_seq` 的索引表（单一来源） | `rtl/snap_seq.v:41-51,86-121` |
| P6b 板级基线（频率/守恒律/速率） | `P6B_ACCEPT.md`（B2b/B3/D1-E1b）、`P6B_SUMMARY.md` |
| P7a 板级基线（BER / gearbox 三条腿 / license 负对照） | `P7A_RESULT.md`、`_proj_10g/reports/p7a_*.txt` |
| 本板实测更正（Y2 = 156.25 MHz / SFP 四脚 / 无 UART） | `../XCKU5PMini/CLAUDE.md`「本板实测修正」 |
| 引脚（GT refclk / SFP / 通道映射） | `_ibert/constr/ibert_top.xdc`、`_ibert/m2_loopback.tcl:133-134` |
| 对端机（SFC9120 / 口名 / 内核 / DPDK） | 记忆件 `eco-linux-peer-box.md`（⚠️ 闸 2 前现场复核，见 U14） |

---

## 附：本规格书**自己核过** vs **转述**的边界（诚实声明）

**自己核过（本次用 Read/Grep 逐行读或 grep 确认）**：
`xxv_probe/pcs64/.../pcs64.veo:58-110`（端口表全文）· `pcs64_ooc.xdc` 的三个周期 ·
`pcs64_exdes.v:94-98,255-311`（自环 + monitor 接线）· `pcs64_pkt_gen_mon.v:65-119`（端口方向）·
`pcs64_example_top.xdc` 的非注释行 · `rtl/mac_tx_64.v:1-240`（S_PRE..S_IFG 行号）·
`rtl/mac_rx_64.v:1-140`（头注释 9 条合同 / F4 三门槛 `:128,133,135` / CRC 语义 `:94-96,112-115`）——
⚠️ 该文件 `:140` 之后（字拼装/FIFO/计数器）**未逐行读**，本规格书里那部分的 `mac_rx_64.v:` 行号引自
`P7B_DATAPATH_CONTRACT.md`（**转述**）·
`rtl/rx_classify.v:1-15,50-66,100-106` · `rtl/fifo_async.v` 的 `ovf_pulse/ovf_cnt` 声明与单驱动 ·
`board/wrapper_p4.v:2196-2239,2524-2580,2660-2700` · `_proj_pcie/rtl/axi_regs.v:60-129,171-175,195-246` ·
`rtl/snap_seq.v` 的索引表 · `P6E_OBS.md` 全文 · `P7A_SPEC.md` 全文 · `P7A_RESULT.md` §7-§9 ·
`_proj_10g/notes/` 的四份笔记（`XXV_OFFICIAL`/`DATAPATH_CONTRACT`/`RXCLASSIFY_AUDIT`/`BASER_TABLES` 全文，
`PHY_IFACE` 的关键章节）。
**本规格书自算的结论（写出算式，可独立复核）**：§4.2.1 的 32.8%/12.5% · §5.1 前置的"1 通道做不了 J7↔J8 自环" ·
§7.1 的"56 字硬上限" · §7.3 的"+18 字 ⇒ 窗宽 54" · §6.1 各条的期望值形式。

**转述（未回原始文件）**：`P7B_XXV_OFFICIAL.md` 里引的 license 日志行 / 时序报告数值 / 资源报告数值 /
路由后层次单元名 / `gt_10gbr` 与官方子核的 `.xci` 对账表；`P7A_RESULT.md` 的板级读数；
`P7B_LIB_SURVEY.md` 关于开源库的一切（本次**完全没有**读该库源码）；记忆件里的对端机状态。
⚠️ 其中**唯一影响设计方向的是 U7**（`pcs64_pkt_gen_mon.v` 的 `swapn` 行号与摘录）—— 它已列入未核实清单，
并在**闸 1c / 闸 2** 各有一条板级闭合路径。
