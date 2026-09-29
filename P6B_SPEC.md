# P6B_SPEC — P6b: 数据面 125MHz → 156.25MHz (前端留 125MHz + 异步 FIFO 跨域)

> **施工规格书**。读者 = 施工 agent。所有结论都带 `file:line` 证据；不带证据的判断一律标
> 「**未定**」并进 §B 附录。
>
> 本文件与 `P6E_OBS.md` 同级、互补: P6E_OBS 讲**观测通道怎么用**, 本文讲**这次搬域怎么改**。
>
> 派单书里的四条施工纪律本文全程遵守: ① 空读数 ≠ 真 0; ② lint 看不见的位宽截断;
> ③ `force` 必须打生产者节点; ④ 结论必须能被别人独立复核(给 file:line / 给命令 / 给原始读数)。
>
> ⚠️ **2026-09-29 收尾归档**：P6b 已通过板级正式验收（`P6B_ACCEPT.md`，35 条判据全 PASS）。
> 本文是**施工规格（当时的判断）**，与最终落地实现的**全部不一致处**已集中列在 **§0.4 勘误**
> （含 §7.2 索引表的错误、36 字映射的最终版、`BUILD_ID`/未实现地址/字数的 as-built 偏离）。
> **读本文做任何重实现之前，先读 §0.4。** 总览见 `P6B_SUMMARY.md`。

---

## 0. 一句话结论 + 决策速查

### 0.1 边界裁决 (一句话)

> **边界选 A —— 落在 `mac_rx_64` 的 64 位 AXIS 输出 / `mac_tx_64` 的 64 位 AXIS 输入**
> (即 `mac_rx_64`、`mac_tx_64`、`util_gmii_to_rgmii_us` 跟前端留 125MHz；`vlan_strip`
> 及其后**全部**搬到 156.25MHz)。
> **理由是 方案 B 在数学上不成立**: `mac_tx_64` 的输出速率被硬绑在它的 `clk` 上
> (1 字节/拍, `rtl/mac_tx_64.v:64-77`), 而它**没有任何输出侧停顿口** —— 唯一能停下它的
> 机制是"输入 FIFO 空 ⇒ 帧内中止 (runt)"(`rtl/mac_tx_64.v:148-152`)。把它的 clk 提到
> 156.25MHz 会让它在**线上只有 125 MB/s 的 RGMII 焊死速率**下永远超速 25%，且
> IFG 常数 `ifg_cnt == 4'd11`(`rtl/mac_tx_64.v:180`) 是**拍数**, 在 156.25MHz 下
> 12 拍 = 76.8 ns < 802.3 要求的 96 ns ⇒ **同时违反最小 IFG**。

### 0.2 其余决策速查

| 项 | 决策 | 依据 |
|---|---|---|
| 新时钟源 | 板上 100MHz 差分有源晶振 **Y1 = `SG7050VAN-100.000000M-KEGA3`** → `SYS_CLK_P/N` = **T25/U25** | 原理图实测出图 (见 §8.2) |
| 156.25MHz 生成 | `IBUFDS + MMCME4_BASE`: MULT=**15.625** / DIVCLK=**1** / CLKOUT0_DIVIDE_F=**10.0** ⇒ VCO **1562.5MHz**, 输出 **6.400ns** | §8.3 |
| 时钟域数 | **3 个互异步域**: `gmii_clk`(PHY 回送 125) / `dp_clk`(Y1→MMCM 156.25) / `pcie_axi_aclk`(XDMA≈250) | §1.3 |
| 异步边界 | **2 个** FWFT 双时钟 FIFO: RX 在 `u_mac_rx.m_axis → u_vlan_strip.s_axis`，TX 在 `u_tx_arb.m_axis → u_mac_tx.s_axis` | §2 |
| 快照仪器 | **2 个 `snap_cdc` 实例 + 1 个链式序列器 `snap_seq.v`**；窗口 24 → **32 字** | §7 |
| 新"未实现地址" | **`0xA0`** (word 40) —— 旧的 0x84 作废 | §7.4 |
| `BUILD_ID` | 4 → **5** | §7.5 |
| HLS | **跟数据面一起搬 156.25MHz**；内部时间常数 ×0.8，**只记录不改** | §5.3 |

---

## 0.3 ⚠️ 与**已落地实现**的对齐（施工前必读 —— 本节优先于 §4/§6/§7/§8 的对应细节）

本规格书起草期间，**并行的实现 agent 已经落了 5 个文件**（本仓 `git status` 可见，均未跟踪）:

| 已落地文件 | 它替本文档回答了什么 | 本文档的对应节必须按它读 |
|---|---|---|
| `rtl/clk_gen_p6b.v` | MMCM 时钟发生器 + 复位同步器（**已实现**） | §0.2 / §6.1 / §8.3 |
| `rtl/fifo_async.v` | 异步 FIFO（灰码指针 + 两级同步 + FWFT 选项）（**已实现**） | §3.1 / §4 / §4.4 |
| `tb/tb_fifo_async.v` + `sim/fifoasync/` | FIFO 单元门（7 个 case / 10 条判据，含复位矩阵与结构契约延迟） | §9.2-B |
| `tb/tb_clk_gen_p6b.v` + `sim/clkgen/` | 时钟发生器单元门（含"改错 MULT_F 就真的跑错频率"的负对照） | §9.2-B |
| `board/p6b_verify/` + `run_controls.py` | `check_p6b_timing.py` 的**正/负对照与人工病理样本**（判据②的"入库"要求） | §9.2-A |
| `_proj_pcie/p6b_accept.sh` | P6b 板级验收脚本（9 条判据） | §9.2-C |

**下面 6 处细节以已落地的代码为准**（本文档的旧写法已在对应节改过，这里再集中列一次）：

| # | 项 | 本文档原稿 | **以实现为准** |
|---|---|---|---|
| **A1** | MMCM 配置 | `MULT=15.625 / DIV=1 / CLKOUT0_DIV=10.0`（VCO 1562.5 MHz） | **`CLKFBOUT_MULT_F=12.500 / DIVCLK_DIVIDE=1 / CLKOUT0_DIVIDE_F=8.000`**（VCO **1250 MHz**，输出仍 156.25 MHz）。两者都合法；实现里那份更好（VCO 更居中 + 备用路线 `CLKIN1_PERIOD=8.000/MULT=10.000` 共用同一个 VCO 1250 MHz）。**验收只看 `report_clocks` 里的 6.400ns，不看参数** |
| **A2** | 复位极性 | `dp_rst_n`（低有效，locked 折进"释放"） | `rtl/clk_gen_p6b.v` 给的是 **`rst_dp`（高有效）**，且 `rst_async = (~locked) \| rst_ext` 是**异步置位**、释放同步（4 拍）。§6.2 的四条理由逐条对照仍然成立（它们反对的是"locked 直接当复位**且**释放异步"，实现两条都避开了） |
| **A3** | FIFO 参数名 | `fifo_async #(.W(77), .D(512), .AW(9))` | **`fifo_async #(.WIDTH(77), .DEPTH(256), .FWFT(1), .AW(8))`**（`AW` 必须是 parameter，见 `rtl/fifo_async.v:88-92`） |
| **A4** | FIFO 端口名 | `clk/rst_n/wr,din,full` + `clk/rst_n/rd,dout,empty` | **`wr_clk/wr_rst_n/wr_en/din/full`** + **`rd_clk/rd_rst_n/rd_en/dout/empty`** + `dbg_wbin/dbg_rbin/dbg_wgray/dbg_rgray`（均 `[AW:0]`） |
| **A5** | FIFO 深度 | 512 | **256**（理由见 §4.2/§4.3 的修订：`FWFT=1` 的读口是**组合读 ⇒ 落 LUTRAM**，`rtl/fifo_async.v:82-85` 自己写明"深/宽 FIFO 用 FWFT=0 才推 BRAM"）。256 ≥ TX 的硬约束 190 字，且 LUTRAM 开销减半 |
| **A6** | FIFO 两侧复位源 | "只跟 `reset_n`" | ✅ 与实现的**硬契约 ②** 完全一致（`rtl/fifo_async.v` 头注释："**只复位一侧 ⇒ 指针不一致 = 未定义行为**"）。**两侧都接 `reset_n`**；`clk_gen_p6b.rst_dp`（含 locked）**只喂数据面功能逻辑，绝不喂 FIFO 指针** |

**尚未被实现覆盖、仍需按本文档施工的部分**：
`board/wrapper_p4.v` 的域搬迁与常数替换（§1.3 / §5）、两个 FIFO 的例化与背压接线（§3.1/§3.4）、
`snap_seq.v` + 32 字窗口（§7）、XDC（§8）、以及所有脚本/门的地址与字数更新（§7.4/§7.7）。

---

## 0.4 ⚠️ 勘误（**2026-09-29 收尾归档时补**；**本节优先于正文**）

> 归档时点：P6b **已通过板级正式验收**（`P6B_ACCEPT.md`，35 条判据全 PASS）。
> 本节只记录"**规格书原稿与最终落地实现不一致**"的地方，**正文不改**（保留原稿作为"当时的判断"），
> 只在出错处加指向本节的标注。所有"最终"取值都能追到 `file:line` 或板级读数。

### 0.4.1 §7.2 的两张索引表 `FE_IDX` / `DP_IDX` **与它自己那张 32 行对照表矛盾**（已按对照表纠正）

- **症状**（两个独立来源都指出过）：
  - 对抗审查 `P6B_REVIEW.md` **F5**：「`FE_IDX` 把 `fe[8]/fe[9]` 写在下标 24/25；`DP_IDX` 在
    W26..W31 上整体**错位两个槽**」；
  - 实际实现的代码注释 `rtl/snap_seq.v:49-51` 也留了同一句：**「以对照表为准」**。
- **判据**：以 §7.2 自己那张**逐项对照表**（W ↔ 束 ↔ 槽）为准 —— 它是对的；
  下面两段 `localparam` **例子是错的**（它们是"手抄下标"的产物，正是 §7.2 自己警告的那类错）。
- ⇒ **§7.4 第 ⑦ 处**"必须与 §7.2 的两张表逐项一致"这句话，**要按本节的两张表读**，
  否则"照规格书重实现"会**重新引入静默串位**。

### 0.4.2 **最终采用**的映射（36 字 = FE 14 + DP 22）

**来源**：① 集成 agent 从 `board/wrapper_p4.v` 的两条拼接 `fe_src`/`dp_src`（`:2738-2773`）**逐项读出**的汇报；
② 审查方**独立**复核 —— 自己写 36 行映射表（**不复用** `snap_seq` 的 `fe_idx_of`/`dp_idx_of`，
避免"抄错会跟 DUT 一起错"）+ 41 代快照的**顺序判据与偏斜符号**（`P6B_INTEGRATION_REVIEW.md` §1.3/§1.4）；
③ 落地代码 `rtl/snap_seq.v:83-118`（**单一来源**：`assemble` 与 `ifndef SYNTHESIS` 自检都调它）。

**(a) 36 字归属表**（`W → 束[槽]`；地址见 `P6E_OBS.md` §一）：

| 字 | 归属 | | 字 | 归属 | | 字 | 归属 |
|---|---|---|---|---|---|---|---|
| W0..W5 | FE `fe[0..5]` | | W13 | DP `dp[7]` | | W26 | FE `fe[9]` |
| W6 | DP `dp[0]` | | W14 | DP `dp[8]` | | W27 | FE `fe[8]` |
| W7 | DP `dp[1]` | | W15 | DP `dp[9]` | | W28 | DP `dp[18]` |
| W8 | DP `dp[2]` | | W16 | DP `dp[10]` | | W29 | DP `dp[19]` |
| W9 | DP `dp[3]` | | W17 | DP `dp[11]` | | W30 | DP `dp[20]` |
| W10 | DP `dp[4]` | | W18 | DP `dp[12]` | | W31 | DP `dp[21]` |
| W11 | DP `dp[5]` | | W19 | DP `dp[13]` | | W32..W35 | FE `fe[10..13]` |
| W12 | DP `dp[6]` | | W20 | FE `fe[7]` | | | |
| | | | W21 | FE `fe[6]` | | | |
| | | | W22 | DP `dp[14]` | | | |
| | | | W23 | DP `dp[15]` | | | |
| | | | W24 | DP `dp[16]` | | | |
| | | | W25 | DP `dp[17]` | | | |

⚠️ **两处"槽号是反的"**（拼接字符串从右往左读 ⇒ 先写的落在**束内最低槽**）：
`fe[6]=W21, fe[7]=W20` 与 `fe[8]=W27, fe[9]=W26`。**这是最容易抄错的地方**，
所以全链门必须"**逐字读回**"，单测一遍看不出（错一处只会读出**另一个字的正确值**）。

**(b) `FE_IDX`（W0..W35 → fe 槽；-1 = 不属于 FE 束）**：

```verilog
localparam integer FE_IDX [0:35] = '{  0,  1,  2,  3,  4,  5,           // W0..W5
                                      -1, -1, -1, -1, -1, -1, -1, -1,   // W6..W13
                                      -1, -1, -1, -1, -1, -1,           // W14..W19
                                       7,  6,                           // W20, W21  <-- 反的
                                      -1, -1, -1, -1,                   // W22..W25
                                       9,  8,                           // W26, W27  <-- 反的
                                      -1, -1, -1, -1,                   // W28..W31
                                      10, 11, 12, 13 };                 // W32..W35 (F4)
```

**(c) `DP_IDX`（W0..W35 → dp 槽；-1 = 不属于 DP 束）**：

```verilog
localparam integer DP_IDX [0:35] = '{ -1, -1, -1, -1, -1, -1,           // W0..W5
                                       0,  1,  2,  3,  4,  5,  6,  7,   // W6..W13
                                       8,  9, 10, 11, 12, 13,           // W14..W19
                                      -1, -1,                           // W20, W21
                                      14, 15, 16, 17,                   // W22..W25
                                      -1, -1,                           // W26, W27
                                      18, 19, 20, 21,                   // W28..W31
                                      -1, -1, -1, -1 };                 // W32..W35
```

⚠️ **写成 Verilog 时用 `function`（或由单一 `localparam` 派生）而不是手抄数组** ——
落地版本 `rtl/snap_seq.v` 用的就是两个 `function`（`fe_idx_of`/`dp_idx_of`），
且 `assemble` 与 `ifndef SYNTHESIS` 自检**都调它** ⇒ 抄错下标会**当场 `$finish`**。
上面的字面数组只是为了**便于人读与逐项核对**，**不要**直接抄进代码。

**(d) 与之配套的项数**（同源，必须一起对）：`SNAP_FE_NW = 14` · `SNAP_DP_NW = 22` ·
`SNAP_NW_P6E = 36` · `snap_seq #(.FW(14), .DW(22))` · 两个 `snap_cdc #(.NW(...))` ·
`fe_src`/`dp_src` 各自的拼接项数 · 读侧 `snap_idx`(6 位)/`snap_base`(11 位)。

### 0.4.3 同一批收尾里的其它 **as-built 偏离**（一并记，免得按正文施工撞上）

| 项 | 正文（原稿） | **最终落地** | 证据 |
|---|---|---|---|
| 快照字数 | 32（§7.1/§7.4） | **36**（同批并入 F4 的 W32..W35；**读侧 `snap_idx`/`snap_base` 必须一起加宽**，否则 `0xA0..` 静默回绕成 W0.. = **假 PASS**） | `board/wrapper_p4.v` 的 `SNAP_NW_P6E/SNAP_FE_NW/SNAP_DP_NW`；`P6B_REVIEW.md` 附录 R.5 预先算出了这条硬顶 |
| `BUILD_ID_V` | `32'h00000005`（§7.5） | **`32'h00000006`**（板级实测 A2 = `0x00000006`） | `board/wrapper_p4.v:2883`；`P6B_ACCEPT.md` A2 |
| 未实现地址 | `0xA0`（§7.4 ⑤） | **`0xB0`**（word 44；板级实测 A5 回 `0xffffffff`，同趟读 `0x14` 作负对照） | `P6B_ACCEPT.md` A5；`_proj_pcie/p6b_accept.sh`。⚠️ 正文 §7.4 ⑤ 与 `p6b_accept.sh:76` 曾各写一个值（F9），**以 `0xB0` 为准** |
| FIFO 占用探针 | §7.1 说 W28 用 `dbg_occ_r` | **用 `dbg_occ_w`**（实现是对的：`dbg_occ_r` 属 gmii 域，塞进 DP 束就是多比特 CDC）；**且它是上界**，不是"保守 ≤ 真实占用" | `P6B_REVIEW.md` **F13**；`board/wrapper_p4.v:2152` 附近 |
| `WIDTH` | 77（§0.3-A3/§3.1） | 算术应为 **76**（64+8+1+1+1+1）；已按 77 位端口接 76 位线**落地**，功能良性（补零）但**注释与实际分叉** | `P6B_REVIEW.md` **F6**；`board/wrapper_p4.v:405-412` |
| `÷64 → ÷80` 的逐处清单 | §7.7 列的那些 | **漏了 5 处**，其中 `p6e_snap_check.sh:143` 与 `p6b_accept.sh:278` 是**活算式**（会打印错的复位次数） | `P6B_REVIEW.md` **F7** |
| `W19` 判据 | "恒 0" | **不再恒 0**（F4 修复后与 MAC 丢帧**有向耦合**）；`p6b_accept.sh` 判据 5 已改 | `P6B_REVIEW.md` 附录 R.7 ②(ii)；`P6E_OBS.md` §二·补2 |

> ⚠️ 与本规格书同批的另一个**潜伏设计债**：P6b 的 8 个时间常数被 `ifdef PCIE_OBS` 守卫
> （**一个语义完全无关的宏**）⇒ "要 PCIe 窗口但数据面仍 125MHz"这个组合现在**会拿到 8 个错的时间常数
> 且无告警**。见 `P6B_REVIEW.md` **F1** 与 `P6E_OBS.md` 开头那张表的注。

---

## 1. 当前时钟拓扑 (事实清单)

### 1.1 top / 分支

| 项 | 值 | 证据 |
|---|---|---|
| 构建脚本 | `board/build_p6e_ku5p.tcl` | 存在 |
| top 模块 | **`wrapper_p4`** | `board/build_p6e_ku5p.tcl:19` `set top_module wrapper_p4` |
| 顶层文件 | **`board/wrapper_p4.v`** | `board/build_p6e_ku5p.tcl:57` |
| 器件 | `xcku5p-ffvb676-1-e` | `board/build_p6e_ku5p.tcl:20` |
| 编译宏 | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1` | `board/build_p6e_ku5p.tcl:95` |
| 约束 | `ku5p_p6a_t8p0.xdc` + `ku5p_p6e_pcie.xdc` + `ku5p_p6e_cdc.xdc`(impl-only) | `board/build_p6e_ku5p.tcl:90-97` |

`ifdef` 分支（全部实测核对过）：

| 宏 | 影响的块 | file:line |
|---|---|---|
| `DEV_USP` | 前端选型: 有宏 ⇒ `util_gmii_to_rgmii_us`（零 IDELAY）；无宏 ⇒ `util_gmii_to_rgmii`（K7，IDELAYE2） | `board/wrapper_p4.v:241-245` |
| `DEV_USP`（负向） | `fpga_gclk` 端口 + `MMCME2_BASE` 200MHz IDELAYCTRL 参考钟 | `board/wrapper_p4.v:137-139`, `187-231` |
| `PCIE_OBS` | 端口 `pcie_sys_clk_p/n`、`pcie_txp/n`、`pcie_rxp/n` | `board/wrapper_p4.v:156-168` |
| `PCIE_OBS` | snap_cdc + xdma_0 + axi_regs 整块 | `board/wrapper_p4.v:2305-2561` |
| `APP_MODE` | `app_ctrl` / `app_udp_pattern` / `udp_split` 等 app 通路 | `board/wrapper_p4.v:175-179`, 442-461, 818-887, 1587+, 1841+ |

### 1.2 时钟树 (P6b 之前)

```
  [外部]                                     [FPGA 内]
  ┌──────────────────────────────────────┬─────────────────────────────────────────────┐
  │ 底板 ETH 页 RTL8211E                   │                                             │
  │  25MHz 无源晶体 (PHY 自己的)            │                                             │
  │   └─ PHY 恢复出 RXC 125MHz ──────────────► phy1_rxc (D11, bank86=HDIO, LVCMOS33)
  │                                          │   └─ IBUF(隐式)─► BUFG bufmr_rgmii_rxc
  │                                          │        └─► gmii_clk  ◄── 【本设计唯一数据面时钟】
  │                                          │              ├─ u_mac_rx        (wrapper:312)
  │                                          │              ├─ u_vlan_strip    (wrapper:347)
  │                                          │              ├─ u_classify      (wrapper:370)
  │                                          │              ├─ u_tcp_rx        (wrapper:1151)
  │                                          │              ├─ u_tcp_echo      (wrapper:1251)
  │                                          │              ├─ u_cam/tcb/…     (wrapper:1297/1322)
  │                                          │              ├─ u_slow_cfg      (wrapper:1396)
  │                                          │              ├─ u_udp_split     (wrapper:1620)
  │                                          │              ├─ u_slow_rx       (wrapper:1748)
  │                                          │              ├─ u_hls  (udp_echo, ap_clk) (wrapper:1772)
  │                                          │              ├─ u_slow_tx       (wrapper:1793)
  │                                          │              ├─ u_udp_tx_cfg    (wrapper:1924)
  │                                          │              ├─ u_udp_tx        (wrapper:1969)
  │                                          │              ├─ u_tx_udp_arb    (wrapper:1995)
  │                                          │              ├─ u_tx_arb        (wrapper:2028)
  │                                          │              ├─ u_mac_tx        (wrapper:2048)
  │                                          │              ├─ u_app_status    (wrapper:785)
  │                                          │              ├─ u_dbg_line      (wrapper:2214)
  │                                          │              ├─ trace_mem / rx_trace_mem / blink / latch
  │                                          │              │   (wrapper:997,1047,1067,2091,2122,2151,2206)
  │                                          │              └─ gmii_free/srx_hls_bytes/hr_cnt (wrapper:2418)
  │                                          │                                             │
  │ 金手指 PCIe 100MHz 差分 (AB7/AB6) ────────► pcie_sys_clk_p/n                        │
  │                                          │   └─ IBUFDS_GTE4 u_pcie_refclk (wrapper:2384)
  │                                          │        └─ xdma_0 u_pcie_xdma (wrapper:2472)
  │                                          │             ├─ pcie_axi_aclk ─► u_snap.clk_a (2461)
  │                                          │             │                └─ u_pcie_regs.clk (2540)
  │                                          │             └─ pcie_axi_aresetn
  │                                          │                                             │
  │ 核心板 Y1 100MHz 差分 (T25/U25, bank65) ──► ★ 本设计**完全没用到** (P6a XDC 无此行)   │
  └──────────────────────────────────────┴─────────────────────────────────────────────┘

  已有 BUFG: 只有一个 —— `u_rgmii/bufmr_rgmii_rxc` (board/util_gmii_to_rgmii_us.v:76)
  已有 MMCM: **DEV_USP 分支下没有** —— 唯一的 MMCME2_BASE 在 `ifndef DEV_USP` 内
             (board/wrapper_p4.v:187-231)，P6e 构建 (DEV_USP=1) 下不综合
  已有 BUFIO/BUFR: **没有** (board/util_gmii_to_rgmii_us.v:27-31 记录: HDIO 无 BUFIO/BUFR)
```

### 1.3 `gmii_clk` (即 `i_rxc`) 的**全部**使用者

复跑命令（施工/复核都能用）:

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
grep -n "gmii_clk" board/wrapper_p4.v                                   # 全量
grep -rn "gmii_clk\|i_rxc\|rgmii_rxc\|gmii_rx_clk" rtl/ board/*.v       # 跨模块
```

实测结果（`board/wrapper_p4.v`，行号 = `.clk(gmii_clk)` 或 `@(posedge gmii_clk)` 所在行）:

| 行 | 归属 | P6b 后归属 |
|---|---|---|
| 252 | `u_rgmii.gmii_rx_clk` 输出（源头） | **留 FE** |
| 277, 292 | `wl_cnt`/`wl_last` 线上帧长；RX 再寄存一拍 | **留 FE**（数的是 `e_rxdv` 拍 = 线上字节时间） |
| 312/313 | `u_mac_rx` | **留 FE** |
| 348/349 | `u_vlan_strip` | → **DP** |
| 371/372 | `u_classify` | → **DP** |
| 582/583 | `u_app`（`app_pattern`，例化在 `wrapper:581`） | → **DP** |
| 615/616 | `u_app_pipe`（`axis_pipe W=77`，`wrapper:614`） | → **DP** |
| 626/627 | `u_app_ctrl`（`app_ctrl`，`wrapper:625`） | → **DP** |
| 786/787 | `u_app_status`（UART 状态行，`wrapper:785`） | → **DP**（并改 `BIT_LAST`，见 §5） |
| 997 / 1047 | `trace_mem` / `rx_trace_mem` 64 拍环（**独立 always 块**） | → **DP** |
| 1067 | `wl_last_lat`（WL 异常触发拍锁存，**独立 always 块**） | ⚠️ **留 FE**（见 §3.5 特例 ①） |
| 1156/1157 | `u_tcp_rx`（`wrapper:1151`） | → **DP** |
| 1252/1253 | `u_tcp_echo`（`wrapper:1251`） | → **DP** |
| 1287/1288 | `u_eco_pipe`（`axis_pipe W=77`，`wrapper:1286`） | → **DP** |
| 1298/1299 | `u_cam`（`tcp_cam`，`wrapper:1297`） | → **DP** |
| 1322/1323 | `u_tcb`（`wrapper:1321`） | → **DP** |
| 1397/1398 | `u_slow_cfg`（`wrapper:1396`；`rst_n = reset_n & hls_rst_n`） | → **DP** |
| 1470/1471 | `u_tcp_tx`（`tcp_tx_frame`，`wrapper:1469`） | → **DP** |
| 1621/1622 | `u_udp_split` | → **DP** |
| 1749/1750 | `u_slow_rx` | → **DP** |
| 1772 | `u_hls.ap_clk`（udp_echo） | → **DP** |
| 1794/1795 | `u_slow_tx` | → **DP** |
| 1879/1880 | `u_app_udp`（`app_udp_pattern`，`wrapper:1878`） | → **DP** |
| 1925/1926 | `u_udp_tx_cfg`（`wrapper:1924`） | → **DP** |
| 1970/1971 | `u_udp_tx`（`udp_tx_frame`，`wrapper:1969`） | → **DP** |
| 1996/1997 | `u_tx_udp_arb`（`tx_arb`，`wrapper:1995`） | → **DP** |
| 2029/2030 | `u_tx_arb`（`wrapper:2028`） | → **DP** |
| 2049/2050 | `u_mac_tx`（`mac_tx_64`，`wrapper:2048`） | **留 FE** |
| 2091, 2122, 2151, 2206 | RTO 事件锁存 / `boot_cnt` / `blk_cnt` / `uart_sel` | → **DP** |
| 2215/2216 | `u_dbg_line`（P4 诊断 UART 行） | → **DP**（并改 `BIT_LAST`） |
| 2418 | `gmii_free` + `srx_hls_bytes` + `hr_cnt` **同一个 always 块** | ⚠️ **必须拆两块**：`gmii_free` 留 FE，另两个 → DP（见 §3.5） |
| 2467 | `u_snap.clk_b` | → **拆成两个 snap_cdc，b 分别是 `gmii_clk` / `dp_clk`** |

> ⚠️ **施工铁律**：`u_mac_rx` / `u_mac_tx` / `wl_cnt` / `wl_last` / `wl_last_lat` / RX 再寄存块
> **留 FE**；其余**一律** `gmii_clk` → `dp_clk`。没有第三种情况。

---

## 2. 异步边界位置：**方案 A**（含否决 B 的实证）

### 2.1 方案 B 为什么在结构上不成立（三条硬证据）

**证据 ①  `mac_tx_64` 是"自由跑"的字节泵，速率被它的 clk 焊死**

`rtl/mac_tx_64.v:64-77`：
```verilog
always @* case (state)
    S_PRE:  txd_c = (pre_cnt == 6'd7) ? 8'hD5 : 8'h55;
    S_DATA: txd_c = cw_data[cw_off -: 8];      // ★ 1 字节/拍
    ...
assign gmii_tx_en = (state == S_PRE) || (state == S_DATA) ||
                    (state == S_PAD) || (state == S_FCS);
```
⇒ 每一拍 `S_DATA` 就往 RGMII 送 1 字节。clk 提到 156.25MHz ⇒ **146.5 MB/s 灌向只吃 125 MB/s 的线**。

**证据 ②  `mac_tx_64` 没有输出侧停顿口 —— 唯一的"停"是帧内中止**

端口表 `rtl/mac_tx_64.v:9-22`：只有 `s_axis_tready`（输入侧反压）与 `gmii_txd/tx_en/tx_er`（输出，无 ready）。
`S_DATA` 里唯一能改变流量的分支（`rtl/mac_tx_64.v:141-152`）：
```verilog
end else if (!fempty) begin   // 有字 ⇒ 继续
    ...
end else begin                // 断供: 中止 (runt)
    state <= S_IDLE; cw_v <= 1'b0;
    stat_abort <= stat_abort + 1;
```
⇒ 没有"等下游"这条路径。要在 B 方案下补速率控制，只能**改 `mac_tx_64`**（加 `ce` 或输出 ready）——
那会破坏 P6a 的"前端/默认构建逐位不变"契约，并要求重跑全部 MAC 门。

**证据 ③  即使把 IFG 常数改成 15 拍，速率缺口仍随帧长变化、无法用常数吸收**

- IFG 现状：`rtl/mac_tx_64.v:179-186` `S_IFG: if (ifg_cnt == 4'd11) …` ⇒ **12 拍**。
  @125MHz = 96 ns（= 802.3 的 12 字节时间 ✓）；@156.25MHz = **76.8 ns ✗ 违约**。
- 若改成 15 拍（96 ns）后逐帧的时间账（N = 内容字节，含 14B 以太头）：
  - MAC 侧周期数 = N + 8(前导) + 4(FCS) + 15(IFG) = N+27 拍 ⇒ 时间 **(N+27)×6.4 ns**
  - 线上时间 = N + 8 + 4 + 12 = N+24 字节时间 ⇒ **(N+24)×8 ns**
  - N=64 时 MAC 用 582 ns vs 线上 704 ns（**快 17%**）；N=1518 时 9888 vs 12336 ns（**快 20%**）
  ⇒ 每一帧都超速约 20%，且**超速比例随 N 变化**（0.2N vs 0.2N+2.4）。要有界的 FIFO，就必须
  让 IFG 随帧长变（N=1518 需 ≈398 拍），即需要一个**真正的字节速率节拍器**，而不是常数。

**⇒ 否决 B。** 顺带记一笔：任务书里对 B 的预判（"要求 `mac_tx_64` 有背压口、且 IFG 的插入点/常数要跟着改"）
被实测**证实了两半**（无背压口 ✓、IFG 是拍数常数 ✓），只是"改成 15 拍"这一半不够 —— 还差一个节拍器。

### 2.2 方案 A 的落地形状

```
  FE (gmii_clk 125MHz)                        │  异步边界   │   DP (dp_clk 156.25MHz)
  ────────────────────────────────────────────┼─────────────┼──────────────────────────────
  util_gmii_to_rgmii_us  (IBUF/BUFG/IDDRE1/ODDRE1)
    └─ e_rxd[7:0], e_rxdv, e_rxer
       └─ rx_d1/rx_dv_d1/rx_er_d1 (再寄存一拍, wrapper:290)
          └─ u_mac_rx (mac_rx_64)          ← 留 FE
             └─ wl_cnt/wl_last (wrapper:275) ← 留 FE
             └─ m_axis 64b AXIS ────────────┐
                                            ▼
                             ┌───────────────────────────────┐
                             │  u_rxcdc : fifo_async          │  W=77, DEPTH=256, FWFT=1
                             │  wr=gmii_clk / rd=dp_clk       │
                             └───────────────┬───────────────┘
                                             │  64b AXIS (FWFT)
                                             ▼
                                        u_vlan_strip → u_classify → {fast: u_tcp_rx…}
                                                                  → {slow: u_udp_split → u_slow_rx → u_hls
                                                                                          → u_slow_tx}
                                        … u_udp_tx / u_tx_udp_arb / u_tx_arb
                                             │  m_axis 64b AXIS (73b: data+keep+last)
                             ┌───────────────▼───────────────┐
                             │  u_txcdc : fifo_async          │  W=73, DEPTH=256, FWFT=1
                             │  wr=dp_clk / rd=gmii_clk       │
                             └───────────────┬───────────────┘
                                             ▼
                                        u_mac_tx (mac_tx_64) ← 留 FE
                                             └─ e_txd/e_txen/e_txer → u_rgmii (FE)
```

### 2.3 任务书四问的逐条回答（全部带证据）

#### Q1 `rtl/mac_tx_64.v` 有没有 ready/stall/credit 类的背压输入？IFG 插在哪、常数多少、单位？

| 问 | 答 | 证据 |
|---|---|---|
| 背压输入 | **只有一个**: `output wire s_axis_tready` = `!ffull`（内部 16 深 FIFO 满）。**没有**输出侧 ready/credit。 | `rtl/mac_tx_64.v:17`, `:40` `assign s_axis_tready = !ffull;` |
| IFG 插在哪 | `S_FCS` 最后一个 FCS 字节之后 → `S_IFG`；`stat_frames++` 在 IFG 数满那一拍 | `rtl/mac_tx_64.v:171-186` |
| 常数 | **`ifg_cnt == 4'd11`** ⇒ 12 拍 | `rtl/mac_tx_64.v:180` |
| 单位 | **"clk 拍"**（= 1 字节时间，因为本模块 clk 恒 125MHz、`gmii_tx_en` 有效时 1 字节/拍） | `rtl/mac_tx_64.v:64-77` |
| 内部 FIFO 深度 | `fifo_sync #(.W(73), .D(16), .AW(4))` | `rtl/mac_tx_64.v:41` |
| 最小帧/clamp | `MIN_CLEN = 16'd60`（字节） | `rtl/mac_tx_64.v:29` |

#### Q2 `rtl/mac_rx_64.v` 收帧统计在哪个域？有没有 min-IFG 检查？

- **域**：`stat_frames`/`stat_bytes`/`stat_crc_err`/`stat_drop` 全部由 `always @(posedge clk)` 驱动
  （`rtl/mac_rx_64.v:102`），`clk` 就是 `gmii_clk`（wrapper:313）⇒ **全在 FE 域**。
- **自增条件（P6b 之后必须精确知道，因为它决定了哪些字可以在 DP 域重算）**：
  | 分支 | 位置 | push? | stat_frames++? | 其它 |
  |---|---|---|---|---|
  | 帧尾, 有保持字, FIFO 不满 | `:142-155` | ✓ | ✓ | `crc!=RESIDUE ⇒ stat_crc_err++` |
  | 帧尾, 有保持字, FIFO 满 | `:156-158` | ✗ | ✗ | `stat_drop++` |
  | 帧尾, 无保持字(bcnt==0) | `:159-161` | ✗ | ✗ | `stat_drop++` |
  | 短帧分支 | `:162-173` | ✓ | ✓ | `crc!=RESIDUE ⇒ crc_err++` |
  | `S_FLUSH` 收尾 | `:203-218` | ✓ | ✓ | `crc!=RESIDUE ⇒ crc_err++` |
  | `S_DROP` | `:219-221` | ✗ | ✗ | 只等 `rx_dv` 落 |
  ⇒ **`stat_frames` ≡ 推进输出 FIFO 的帧数**；**`stat_crc_err` ≡ 推走的帧里 `tcrs==0` 的帧数**
  （两条都是"若且唯若"，见 §7.3 的重算论证）。
- **min-IFG 检查**：**没有**。`S_IDLE` 只找 `gmii_rxd == 8'h55`（`:121-125`），`S_PRE` 数前导到 `D5`
  （`:126-138`），对帧间间隔零约束。
  ⇒ **P6b 不影响它**（RX 前端仍是 125MHz、线上仍是 1 字节/拍）。**不需要改。**

#### Q3 `rtl/frame_fifo.v` / `rtl/fifo_sync.v` 接口与深度；RX/TX 路径上现有哪些 FIFO、怎么背压

| 模块 | 接口 | 深度（现有实例） |
|---|---|---|
| `rtl/fifo_sync.v` | `clk, rst_n, wr, din[W-1:0], rd, dout, empty, full` + `dbg_wptr/rptr/full/empty`。**FWFT**：`dout` 与 `!empty` 同拍有效；`full = (wptr[AW-1:0]==rptr[AW-1:0]) && (wptr[AW]!=rptr[AW])`；`empty = (wptr==rptr)`；**有旁路** `bypass = (wr&&!full) && (rptr_n[AW-1:0]==wptr[AW-1:0])` | 单时钟 |
| `rtl/frame_fifo.v` | `clk, rst_n, wr, din[W-1:0], snap, rollback, rd, dout, empty, full` + 诊断。**带"提交/回卷"语义**（帧级：`snap`@tlast 提交，`rollback` 整帧作废） | 单时钟 |

**RX 路径上现有的 FIFO（FE→DP 边界之前 / 之后）**：

| # | 位置 | 模块/深度 | 满/空时上游如何被背压 |
|---|---|---|---|
| 1 | `u_mac_rx` 内部输出字 FIFO | `fifo_sync W=76 D=8 AW=3`（`rtl/mac_rx_64.v:233`） | 满 ⇒ 帧内或帧尾**整帧丢**（`S_DROP`，`stat_drop++` `:156-158,182-184,204-206`） |
| 2 | **★ P6b 新增 `u_rxcdc`** | `fifo_async WIDTH=77 DEPTH=256 FWFT=1 AW=8` | 满 ⇒ `u_mac_rx.m_axis_tready=0` ⇒ 上游退化成 #1 的满 |
| 3 | `u_slow_rx` 输入帧缓冲 | `frame_fifo W=73 D=512 AW=9`（`rtl/slow_rx_adp.v:69`） | 满 ⇒ 吞字并 `abort`（整帧丢，`stat_drop++`） |
| 4 | `u_slow_rx` 输出字节 FIFO | `fifo_sync W=9 D=2048 AW=11`（`rtl/slow_rx_adp.v:83`） | 满 ⇒ 停播（`occ <= 12'd256` 节流 + 看门狗兜底） |
| 5 | `u_slow_cfg` cfg FIFO | `fifo_sync W=32 D=16 AW=4`（`rtl/slow_cfg_adp.v:64`） | 满 ⇒ 丢配置记录 |
| 6 | `u_udp_split` 各级 | `D=32 / PRE_AW=4 / PB_AW=5 / DESC_AW=6 / UDP_AW=9`（`rtl/udp_split.v:98,157-160`） | **`s_axis_tready` 结构性恒 1**（内部丢整帧，绝不回压上游） |
| 7 | `u_tcp_rx` 侧 | 与 N 条连接共享 **64KB frame_fifo**（`rtl/tcp_rx.v:25`） | 满 ⇒ 拒绝（`m_fast_tready=0`） |

**TX 路径上现有的 FIFO**：

| # | 位置 | 模块/深度 | 满/空时怎么表现 |
|---|---|---|---|
| 1 | `u_tx_arb` / `u_tx_udp_arb` | **无 FIFO**，纯组合仲裁 FSM（`rtl/tx_arb.v:5-53`）。`busy` 锁到 TLAST；`m_axis_tvalid = busy && src_valid`；`s_*_tready = busy && sel && m_axis_tready` | 空闲时按请求选择；**保序、严格优先级**（TCP > UDP app > HLS） |
| 2 | **★ P6b 新增 `u_txcdc`** | `fifo_async WIDTH=73 DEPTH=256 FWFT=1 AW=8` | 满 ⇒ `m_tx_tready=0` ⇒ `u_tx_arb` 停 grant ⇒ 源停 |
| 3 | `u_mac_tx` 内部字 FIFO | `fifo_sync W=73 D=16 AW=4`（`rtl/mac_tx_64.v:41`） | **空且帧未发完 ⇒ 帧内中止 (runt)** + `stat_abort++` |
| 4 | `u_slow_tx` 输出帧 FIFO | `frame_fifo W=73 D=512 AW=9`（`rtl/slow_tx_adp.v:68`） | **不再被消费 ⇒ `stat_purge++` 整帧回卷**（W18） |
| 5 | `u_slow_tx` 输入字节 FIFO | `fifo_sync W=9 D=2048 AW=11`（`rtl/slow_tx_adp.v:37`） | HLS 产出的字节堆积 |
| 6 | `tcp_tx_frame` 载荷 FIFO + retx ring | `frame_fifo`/`retx_ram`（`rtl/tcp_tx_frame.v:173,179`；`rtl/tcb.v:140`） | 窗口门控（`RING_CAP=0xBFFE`），满了不发新帧 |

> **"信用机制"在哪**: `tx_arb` **没有信用池**，它是纯 ready/valid 仲裁。真正的信用/窗口在
> `tcp_tx_frame`（`RING_CAP` 门控）与 `app_ctrl`（`WIN_CAP_5 = 16'hBFFE`，`wrapper_p4.v:185`）。
> 施工 agent 不要去找 `tx_arb` 的 credit —— 不存在。

#### Q4 仪器完整性硬约束：W0..W23 的来源在哪个域（逐个列表）

| 字 | 地址 | 来源信号 | 模块 | 现域 | P6b 后 |
|---|---|---|---|---|---|
| W0 | 0x20 | `rx_stat_frames` | `u_mac_rx` (mac_rx_64) | gmii | **FE** |
| W1 | 0x24 | `rx_stat_bytes` | `u_mac_rx` | gmii | **FE** |
| W2 | 0x28 | `{16'd0, wl_last}` | wrapper `wl_cnt` 块 (wrapper:275) | gmii | **FE** |
| W3 | 0x2C | `rx_stat_crc_err` | `u_mac_rx` | gmii | **FE** |
| W4 | 0x30 | `rx_stat_drop` | `u_mac_rx` | gmii | **FE** |
| W5 | 0x34 | `gmii_free` | wrapper (wrapper:2418) | gmii | **FE**（故意的：FE 活性锚点） |
| W6 | 0x38 | `srx_stat_commit` | `u_slow_rx` | gmii | DP |
| W7 | 0x3C | `stx_stat_frames` | `u_slow_tx` | gmii | DP |
| W8 | 0x40 | `udpapp_tx_frames` | `u_app_udp` | gmii | DP |
| W9 | 0x44 | `udpapp_tx_bytes` | `u_app_udp` | gmii | DP |
| W10 | 0x48 | `udpapp_rx_frames` | `u_app_udp` | gmii | DP |
| W11 | 0x4C | `udpapp_rx_bytes` | `u_app_udp` | gmii | DP |
| W12 | 0x50 | `udpapp_rx_null` | `u_app_udp` | gmii | DP |
| W13 | 0x54 | `udpapp_mismatch` | `u_app_udp` | gmii | DP |
| W14 | 0x58 | `tx_stat_frames`(TCP fast) | `u_tcp_tx` (tcp_tx_frame) | gmii | DP |
| W15 | 0x5C | `tx_stat_bytes`(TCP fast) | `u_tcp_tx` | gmii | DP |
| W16 | 0x60 | `srx_hls_bytes` | wrapper (wrapper:2426) | gmii | DP |
| W17 | 0x64 | `hr_cnt` | wrapper (wrapper:2428) | gmii | DP |
| W18 | 0x68 | `stx_stat_purge` | `u_slow_tx` | gmii | DP |
| W19 | 0x6C | `srx_stat_drop` | `u_slow_rx` | gmii | DP |
| W20 | 0x70 | `mac_tx_frames` | `u_mac_tx` (mac_tx_64) | gmii | **FE** |
| W21 | 0x74 | `tx_stat_abort` | `u_mac_tx` | gmii | **FE** |
| W22 | 0x78 | `rx_stat_pass` | `u_tcp_rx` | gmii | DP |
| W23 | 0x7C | `rx_stat_nonmatch` | `u_tcp_rx` | gmii | DP |

⇒ **FE 侧遗留 8 个字**: W0,W1,W2,W3,W4,W5,W20,W21。

### 2.4 为什么不能把它们全搬进 DP 域（否决方案 (i) 的实证）

任务书希望的终局是"**只用一个 `snap_cdc` 实例、所有字严格同代**"。**做不到**，而且原因是可以逐条点名的：

**(a) W4 `rx_stat_drop` 在 DP 域不可复算 —— 它数的是"没留下任何下游痕迹"的事件。**
自增点（`rtl/mac_rx_64.v:158,161,184,206`）全部发生在**没有 push** 的分支上：
- FIFO 满导致的丢帧（`:158`, `:184`, `:206`）—— 帧的字节一个都没进 FIFO；
- 零净荷帧（`:161`, 分支条件 `bcnt == 3'd0` + 无保持字 ⇒ `fbytes <= 4`）—— 同样没有 push。
⇒ DP 侧看不到任何东西。**结构性不可复算。**

**(b) W21 `tx_stat_abort` 同理** —— 它是 `mac_tx_64` 的**内部**"输入 FIFO 空 ⇒ 帧内中止"
（`rtl/mac_tx_64.v:148-152`）。DP 侧能看到"我把字交出去了"，但看不到"MAC 的 16 深 FIFO 在我
两次交付之间跑空了"：16 字 = 128 拍的缓冲能吸收掉 DP 的短停顿而不中止。
⇒ 中止门槛在 DP 侧观测不到。

**(c) W20 `mac_tx_frames`** = W21 的补集（提交的帧 = 发完的帧 + 中止的帧），既然 W21 不可数，W20 也不能从 DP 侧分开。

**(d) W0/W1/W3 虽然可以精确复算（见 §7.3 的证明），但复算它们并不能消灭 FE 束**
—— 只要 W4/W20/W21 还在 FE，就仍然需要第二个 CDC 通道。**所以 (i) 不解决问题，只缩小它**，
代价却是：改 RX FIFO 的读侧数据通路（加 popcount+加法器）、给 FIFO 加 16 位 sideband
（W2）、并且引入"定义漂移"（W1 从 `Σfbytes` 变成 `Σpopc+4·帧`，数值相同但定义不同，
将来任何人改 `mac_rx_64` 的打包都会让两条线分叉）。

**(e) W5 `gmii_free` 是故意留 FE 的** —— 它的语义就是"PHY 回送的时钟还在跑吗"
（`P6E_OBS.md` §一 把它标为"活性锚点"）。搬走它等于毁掉这个判据。

### 2.5 ⇒ 选定的仪器方案: **(ii) + 链式触发**

```
   主机写 0x18=1
        │  (pcie_axi_aclk 域)
        ▼
  ┌──────────────────┐   req_fe(1 拍)   ┌──────────────────────┐   b 域 = gmii_clk 125MHz
  │  snap_seq.v      │ ────────────────►│ snap_cdc #FE  NW=10  │  ← W0..W5,W20,W21,W26,W27
  │  (axi 域序列器)   │ ◄──── valid_fe ──│  (锁存 10 字一束)     │
  │                  │                  └──────────────────────┘
  │  IDLE→FE→DP→IDLE │   req_dp(1 拍)   ┌──────────────────────┐   b 域 = dp_clk 156.25MHz
  │                  │ ────────────────►│ snap_cdc #DP  NW=22  │  ← W6..W19,W22..W25,W28..W31
  │                  │ ◄──── valid_dp ──│  (锁存 22 字一束)     │
  └────────┬─────────┘                  └──────────────────────┘
           │ valid + snap_din[1023:0]   (32 字, 按 §7.2 的表把两束拼成一张连续地图)
           ▼
      axi_regs.snap_*  (接口**一字不改**)
```

**链式触发的顺序 = FE 先、DP 后**。这个顺序不是随意的，它给出一个可判读的因果序：
**FE 计数器采样时刻 ≤ DP 计数器采样时刻**，于是

* `W6(DP) - W0(FE) ∈ {0, 1}`：帧进了 RX FIFO 但还没提交给慢路径的帧数。
* `W30(DP) - W0(FE) ≥ 0`：还滞留在 RX FIFO 里的帧数。
* `W20(FE) ≤ W7(DP)` 一类有向关系同理。

**不改链式会付出什么代价**（任务书点名要答）：两个 `snap_cdc` 各自被同一个 axi 脉冲触发，
FE 锁存与 DP 锁存的**相对次序由两个域的相位随机决定**（异步），偏斜的方向不确定 ⇒
上面那些"非负、≤1"的判据全部退化成 `|Δ| ≤ 1` 的对称容差，跨域对账失去方向性。
量级上相差不大（两者都在 ~40–60 ns 内），但**方向确定**能排除一整类"看起来像计数漂移"的
伪故障，成本只是序列器里多两个状态。⇒ **要链式。**

**偏斜的硬上界（可复算）**：
| 环节 | 最坏拍数 | 时间 |
|---|---|---|
| `req` → FE 锁存 | 3 拍 `gmii_clk` | 24.0 ns |
| FE 返回值 → axi 看到 | 3 拍 `pcie_axi_aclk`(@4ns) | 12.0 ns |
| 序列器 → `req_dp` | 1 拍 axi | 4.0 ns |
| `req_dp` → DP 锁存 | 3 拍 `dp_clk` | 19.2 ns |
| **FE 锁存 → DP 锁存 总计** | | **≤ 59.2 ns** |

**59.2 ns < 96 ns = 1G 背靠背帧的最小 IFG（12 字节时间）** ⇒ **两次锁存之间最多跨过 1 个帧边界**
⇒ 上面那些 `∈{0,1}` 的判据是**结构性成立**的，不是统计性的。

---

## 3. 跨域信号清单（施工图）

### 3.1 数据通路 —— 只有两处（RX / TX），其余全部同域

**RX 异步 FIFO `u_rxcdc`（`rtl/fifo_async.v`, W=77, DEPTH=256, FWFT=1, AW=8）**

| 信号 | 位宽 | 源(域) | 目的(域) | 协议 | CDC 类型 |
|---|---|---|---|---|---|
| `rx_tdata` | 64 | `u_mac_rx.m_axis` (gmii) | `u_vlan_strip.s_axis` (dp) | AXIS 数据 | **异步 FIFO（FWFT）** |
| `rx_tkeep` | 8 | 同上 | 同上 | AXIS 数据 | 同上 |
| `rx_tuser` (SOP) | 1 | 同上 | 同上 | AXIS 边带 | 同上 |
| `rx_tlast` | 1 | 同上 | 同上 | AXIS 帧边界 | 同上 |
| `rx_tcrs` | 1 | 同上 | 同上 | AXIS 边带（FCS 对） | 同上 |
| `rx_terr` | 1 | 同上 | 同上 | AXIS 边带（rx_er） | 同上 |
| `rx_tready`（**背压，FE 方向**） | 1 | FIFO `full`（**FE 本地**） | `u_mac_rx.m_axis_tready` | ready | **不跨域**：`full` 由 FE 本地 `wptr` 与**同步过来的** `rptr` 组合而成 |
| `(内部)` `rptr` | AW+1 | FIFO 读侧 (dp) | FIFO 写侧 (gmii) | 指针 | **格雷码 + 2FF（ASYNC_REG）** |

**TX 异步 FIFO `u_txcdc`（`rtl/fifo_async.v`, W=73, DEPTH=256, FWFT=1, AW=8）**

| 信号 | 位宽 | 源(域) | 目的(域) | 协议 | CDC 类型 |
|---|---|---|---|---|---|
| `m_tx_tdata` | 64 | `u_tx_arb.m_axis` (dp) | `u_mac_tx.s_axis` (gmii) | AXIS 数据 | **异步 FIFO（FWFT）** |
| `m_tx_tkeep` | 8 | 同上 | 同上 | AXIS 数据 | 同上 |
| `m_tx_tlast` | 1 | 同上 | 同上 | AXIS 帧边界 | 同上 |
| `m_tx_tready`（**背压，DP 方向**） | 1 | FIFO `full`（**DP 本地**） | `u_tx_arb.m_axis_tready` | ready | **不跨域** |
| `(内部)` `wptr` | AW+1 | FIFO 写侧 (dp) | FIFO 读侧 (gmii) | 指针 | **格雷码 + 2FF** |

> ⚠️ **TX 只有 3 个字段**：`mac_tx_64` 的输入端口只有 `s_axis_tdata/tkeep/tvalid/tready/tlast`
> （`rtl/mac_tx_64.v:12-16`）。SOP/tcrs/terr 是 **RX 侧**才有的字段。

### 3.2 观测通路（快照）

| 信号 | 位宽 | 源(域) | 目的(域) | 协议 |
|---|---|---|---|---|
| `fe_src` | 320 (10×32) | FE 寄存器束 (gmii) | snap_cdc #FE 的 `din_b` | 相干锁存（toggle 握手） |
| `dp_src` | 704 (22×32) | DP 寄存器束 (dp) | snap_cdc #DP 的 `din_b` | 同上 |
| `req_fe` / `busy_fe` / `valid_fe` / `fe_dout` | 1/1/1/320 | axi ↔ gmii | — | snap_cdc 内部（3 组 ASYNC_REG 同步器 + toggle 握手） |
| `req_dp` / `busy_dp` / `valid_dp` / `dp_dout` | 1/1/1/704 | axi ↔ dp | — | 同上 |
| `snap_din` | 1024 (32×32) | `snap_seq` (axi) | `axi_regs` (axi) | **同域，无 CDC** |

**CDC 硬契约（继承 `rtl/snap_cdc.v` 头注释，施工时不许改）**：
① `req_a` 必须是**恰好 1 拍宽**的脉冲（`:20-26`）⇒ `snap_seq` 的 `req_fe/req_dp` 必须寄存器化成
一拍；
② 必须用 `valid_a` 采样 `dout_a`，**不能**用"busy_a 落下"当完成信号（`:27-31`）；
③ `busy` 期间来的 `req` 被**忽略**（不是排队）⇒ `axi_regs.snap_req` 在序列器忙时到达 = 丢一次请求，
与现状语义一致（现状 `snap_cdc` 也是这么丢的）。

### 3.3 复位与其它

| 信号 | 位宽 | 源(域)→目的(域) | CDC |
|---|---|---|---|
| `reset_n` | 1 | 板 (PERST#, J9) → FE | **异步复位，原样保留**（`negedge reset_n`） |
| `reset_n` | 1 | 板 → DP | **异步置位 + 同步释放桥**（§6.1） |
| `mmcm_locked` | 1 | MMCM (100MHz 参考域) → DP | **2FF 同步（ASYNC_REG）**，参与复位桥 |
| `mmcm_locked` | 1 | → axi（进 SNAP_STATUS[6]） | 2FF 同步 |
| `dp_rst_n` | 1 | DP → FE（**只有 `wl_last_lat` 的触发用**，见 §3.5） | 2FF 同步 |
| `led_d0..3`, `uart_txd` | 4+1 | DP → 引脚 | **不需要 CDC**（纯输出，无时序关系） |

### 3.4 背压路径（单独说清方向）

| 方向 | 谁压谁 | 压不动时丢什么 | 丢在哪 | 对应计数器 |
|---|---|---|---|---|
| **RX**（DP 压 FX） | DP 侧消费者（`tcp_rx` 的 64KB frame_fifo 满）⇒ `u_rxcdc.full` ⇒ `u_mac_rx.m_axis_tready=0` ⇒ `u_mac_rx` 内部 8 深 FIFO 满 ⇒ **整帧丢** | **整帧**（`stat_drop++`） | `rtl/mac_rx_64.v:156-158` / `:182-184` / `:204-206` | **W4**（合计）+ **W26**（新：`u_rxcdc.full` 高电平拍数，专门归因"是不是新 FIFO 造成的"） |
| **TX**（线速压 DP） | RGMII 线 125 MB/s < DP 产能 ⇒ `u_txcdc.full` ⇒ `u_tx_arb.m_axis_tready=0` ⇒ `u_tx_arb` 不 grant ⇒ 源停 | 不丢：TCP 停发（窗口/ring 保住）、UDP app 停发（`utx_busy`）、HLS 的 `frame_fifo` 满后 `stat_purge++` **整帧回卷** | `rtl/slow_tx_adp.v`（purge 路径） | **W18**（purge）+ **W29**（新：DP 被线速压住的拍数） |
| **TX 的帧内断供**（真正的危险） | DP **停顿**（不是线速）⇒ `u_mac_tx` 内部 16 深 FIFO 跑空 ⇒ **帧内中止 (runt)** | 该帧变 runt 上线 | `rtl/mac_tx_64.v:148-152` | **W21**（已有）+ **W28**（新：`u_txcdc.occ_max`） |

> ⚠️ **W21 的语义在 P6b 后变了**（必须写进文档，否则会误判）：
> 现在 DP 可以**领先 MAC 最多 256 字**（≈1.35 个最大帧），所以"DP 停顿"要被吸收掉 256 字才会
> 造成中止 ⇒ **W21 涨 = 一次"持续型"的 DP 断供**（原先 16 字时代的小抖动就会触发）。
> 验收时 W21 = 0 仍是硬判据，但它的**故障含义升级**了。

### 3.5 两个必须单独处理的"同域特例"

**特例 ①  `wl_last_lat`（`board/wrapper_p4.v:1061-1073`）**
现状：在 `gmii_clk` 上锁存 `wl_last`（FE 值），触发源是 `rx_trace_rewind`（**DP 值**）。
`diag18` 的注释明写它当年就是为了"同域直锁、废除 phy1_rxc 2 级同步"才搬过来的。
P6b 之后两者**不同域**了 ⇒ 必须二选一：
- ✅ **采用**：`wl_last_lat` 块**留 gmii_clk**，触发信号换成 `rx_trace_rewind` 的
  **2FF 同步版**（DP → FE，1 位，加 `ASYNC_REG`）。理由：`wl_last` 是"帧间保持"的**值**
  （`board/wrapper_p4.v:276` 注释），偏斜几十 ns 读到的仍是同一帧的长度，语义无损。
  代价：2 个 FF + 1 位 CDC。
- ❌ 否决：搬到 dp_clk。那会让 16 位的 `wl_last` 变成无同步的多比特跨域 ⇒ **位混型假值**
  （正是 `snap_cdc.v` 头注释警告的现象），而且它只在"WL 异常"时才被读，坏读几乎必被误当证据。

**特例 ②  `board/wrapper_p4.v:2418` 的 always 块混了三个计数器**
```verilog
always @(posedge gmii_clk or negedge reset_n) begin          // 行 2418
    gmii_free     <= gmii_free + 32'd1;                      // ← 必须留 FE
    if (hls_rx_tvalid && hls_rx_tready) srx_hls_bytes <= …;  // ← 必须 → DP
    if (!hls_rst_n)                     hr_cnt        <= …;  // ← 必须 → DP
end
```
⇒ **拆成两个 always 块**：`gmii_free` 留 `gmii_clk`；`srx_hls_bytes` / `hr_cnt` 搬到 `dp_clk`
（`hls_rx_tvalid/tready` 来自 DP 域的 `u_slow_rx`，`hls_rst_n` 也由它产生）。

---

## 4. FIFO 深度推导（从协议算，不拍脑袋）

### 4.1 共同项：CDC 同步延迟折算

标准格雷码指针 CDC：`rptr` 用 2–3 拍 `gmii_clk` 同步进 FE（`full` 判定）；`wptr` 用 2–3 拍
`dp_clk` 同步进 DP（`empty` 判定）。两边都是**保守**方向（满判早、空判晚），
**不占用深度预算**，只增加延迟：

| 量 | 值 | 换算成字节 |
|---|---|---|
| FE 侧看到 DP 的 `rptr` 更新 | 2–3 拍 gmii = 16–24 ns | 2–3 字节时间 ⇒ **≤1 个 64 位字** |
| DP 侧看到 FE 的 `wptr` 更新 | 2–3 拍 dp = 12.8–19.2 ns | 在 1G 上 ≈ **≤1 个 64 位字**（字到达间隔 51.2 ns） |
| 链式快照的跨束偏斜 | ≤59.2 ns（§2.5） | 与 FIFO 深度无关 |

⇒ **CDC 延迟对深度的需求 ≤ 2 字。** 深度是被"弹性"决定的，不是被延迟。

### 4.2 RX FIFO `u_rxcdc` 深度

**实际突发**（全部从代码读出）：

| 量 | 值 | 依据 |
|---|---|---|
| 线上最大帧 | 1518 B（+8 前导） | `rtl/mac_tx_64.v:29` `MIN_CLEN=60`；`rtl/tcp_tx_frame.v:179` `PLEN_MAX=1500` |
| `u_mac_rx` 交付给 FIFO 的字数/最大帧 | `ceil((1518-4-8)/8) = ceil(1506/8) = 189` → 取 **190 字** | 帧长减 8 前导减 4 FCS = 内容 1506 B |
| FE 填充率 | **1 字 / 8 拍 gmii = 1 字 / 51.2 ns**（只在有帧时） | `rtl/mac_rx_64.v:233` FIFO 宽 64b，1 字 = 8 字节时间 |
| DP 消耗率 | **≥ 1 字 / 8 拍 dp = 1 字 / 51.2 ns**（名义 1 字/6.4 ns，受上游 ready 限） | `u_vlan_strip` 非 VLAN 帧 1 拍寄存直通（`rtl/vlan_strip.v:32`；VLAN 帧 tag 字处 1 拍输出气泡，`board/wrapper_p4.v:339`） |
| DP 最坏停顿 | **无界**：`u_tcp_rx` 与 N 条连接共享 64KB `frame_fifo`（`rtl/tcp_rx.v:25`），排空时间取决于对端；`u_udp_split` 结构性不反压（`rtl/udp_split.v`） | 见 §3.4 表 |

**结论：RX 侧的"最深停顿"没有有限上界** ⇒ 深度不可能由"保证不丢帧"导出。
这正是**设计合同**（`rtl/mac_rx_64.v:9` 明写"背压: 内部 8 深 FIFO, 满则整帧丢弃"）
已经接受的行为：丢帧是允许的，只要**在帧边界丢 + 可归因**。

⇒ 因此深度按"**可测的弹性目标**"取，并把它写死成判据：

**取值 `DEPTH = 256` 字 (AW=8)，`WIDTH = 77` 位**（64 data + 8 keep + tuser + tlast + tcrs + terr）。

> ⚠️ **修订（对齐已落地的 `rtl/fifo_async.v`，见 §0.3-A5）**：原稿取 512。
> `rtl/fifo_async.v:82-85` 自己写明 **`FWFT=1` 的读口是组合读 ⇒ 综合只落 LUTRAM
> （"双时钟 + 组合读口 = 只能是分布式 RAM"），要推 BRAM 必须 `FWFT=0`**。
> 512 字 × 77 位 = 39,424 个 LUTRAM bit ≈ 616 个 RAM64X1 + 读口 mux 树 ⇒ 在 6.4ns 上是真实风险，
> 而本设计**必须** FWFT（工程坑 4：AXIS = 组合 valid + 组合 rd + FWFT；`board/wrapper_p4.v:340`
> 也依赖这一合同）。⇒ **降到 256**（LUTRAM 减半），硬约束检查见下。
> **升级路径**（若板级证明 256 不够，`W27` 会显形）：换成 `FWFT=0` 的 `DEPTH=512` +
> 读侧自建 1 字输出寄存器/valid 跟踪，即可推 BRAM 而不改语义。**不要**在 FWFT=1 下直接加深度。

**论证算式**：
```
吸收能力        = 256 字 × 8 B/字 = 2048 B
可吸收的反压时长 = 2048 B / 125 MB/s = 16.38 µs
                 = 2048 个 gmii 拍 (256 字 × 8 拍/字)
                 = 1.35 个 1518B 最大帧 (256 / 190 = 1.35)
```
选 256 而不是 128 / 512：
- **256 ≥ 190 字**（一个 1518B 最大帧的字数）—— 这是"整帧进得来"的硬下界（TX 侧同款约束见 §4.3）；
- 128 **不满足**（128 < 190 ⇒ 一个最大帧都装不下 ⇒ DP 每帧都被卡一次）；
- 512 在 `FWFT=1` 下把 LUTRAM 翻倍（见上面的修订），收益只有"多 1.35 帧的弹性"，
  而**弹性没有上界需求**（§4.2 已证最深停顿无界）⇒ 不值。

**资源代价（估算，未经综合验证）**：256×77 = 19,712 bit ⇒ 约 308 个 RAM64X1
（≈ 308–800 LUT，取决于读口 mux 树），相对 P6a 已用的 46,842 LUT
（`p6a_ku5p_verify/p6a_t8p0_utilization_routed.rpt`）可接受。
⚠️ **施工后必须在 `report_utilization` 里确认走的是 LUTRAM（`RAM64X1`/`RAM32X1`），不是 FF 阵列**；
并在 `report_timing` 里看跨这两个 FIFO 的路径（`vlan_strip`/`mac_tx_64` 的输入侧）。

**若深度不够的症状**（日后归因用）：
- `W4`（`rx_stat_drop`）随 `W0` 同步上涨，且 **`W13`（图案失配）= 0、`W3`（FCS 错）= 0**
  ⇒ 不是物理层、不是图案，是"帧在 MAC 边界被丢"；
- `W26`（`u_rxcdc.full` 拍数）**单调上涨** ⇒ 确认是新 FIFO 造成的；
- `W27`（`u_rxcdc.occ_max`）**贴着 256** ⇒ 深度真的不够（把它当"深度探针"用）。

### 4.3 TX FIFO `u_txcdc` 深度

| 量 | 值 | 依据 |
|---|---|---|
| DP 侧最大帧字数 | `ceil(1518/8) = 190 字` | `PLEN_MAX=1500` + 14B 以太头 |
| MAC 消耗率 | 1 字 / 8 拍 gmii（`S_DATA` 8 拍 1 字） | `rtl/mac_tx_64.v:54,129-156` |
| MAC 内部缓冲 | **16 字**（`rtl/mac_tx_64.v:41`）= 128 拍 gmii = 1024 ns | 中止门槛 |
| 上游 `u_tx_arb` 的帧粒度 | **一次只放一帧**（`busy` 锁到 TLAST，`rtl/tx_arb.v:38-52`） | 所以 DP 想预置下一帧，FIFO 必须装得下**整帧** |

**论证算式**：
```
硬约束:  深度 ≥ 1 个最大帧的字数 = 190 字
         (否则 tx_arb 在帧 N 还没发完时无法交付帧 N+1 ⇒ DP 每帧被卡一次)
裕量:    256 / 190 = 1.35 帧
帧内断供容忍: (异步 FIFO 256 + mac_tx 内部 16) 字 = 272 字
              = 272 × 8 拍 gmii = 2176 拍 = 17.4 µs
              其中扣掉一帧自身 (190 字 = 1520 拍 = 12.2 µs) 后的**纯裕量**
              = (272-190) × 8 拍 = 656 拍 = 5.2 µs
```
**取值 `DEPTH = 256` 字 (AW=8)，`WIDTH = 73` 位**（64 data + 8 keep + tlast）。

> ⚠️ **深度不是"越大越好"**：它同时**放宽**了 `W21`（帧内中止）的触发条件，见 §3.4 的警告。
> **修订说明同 §4.2**（512 → 256，理由是 `FWFT=1` 落 LUTRAM）。
> TX 侧比 RX 侧更贴边（1.35 帧 vs 1.35 帧，但 5.2µs 的纯裕量比 RX 的 16.4µs 反压窗口薄），
> 所以 **`W28`（`u_txcdc` 占用峰值）在板级必须读**：贴 256 ⇒ 立刻按 §4.2 的升级路径换 FWFT=0 的 512。

**若深度不够的症状**：
- `W21`（`tx_stat_abort`）在正常流量下**非零** ⇒ MAC 帧内断供 ⇒ 线上出现 **runt** ⇒ 对端抓包
  看到短帧（`W2` 会显形：`wl_last ≈ 66`）；
- `W28`（`u_txcdc.occ_max`）**长时间贴着 256** ⇒ DP 被线速压死，深度不是问题（本来就是线速瓶颈）；
  真正需要加深的信号是 **`W29` 大而 `W18` 不涨**（DP 在等线，而不是在丢弃）。

### 4.4 FIFO 复位的一致性问题（深度之外必须做的设计）

⚠️⚠️ **两个指针必须在**同一代**上复位，否则会静默错位。危险场景：
若 DP 侧指针的复位被 `mmcm_locked` 门控，而 FE 侧不被门控，则一次 `locked` 抖动会让
`rptr` 归零而 `wptr` 保持 ⇒ FE 认为"快满"、DP 从头重读旧数据 ⇒ **数据腐败**（不是丢帧）。

⇒ **硬规则（写进 RTL 头注释与门里）**：
```
两个异步 FIFO 的两侧复位 **只跟板级 reset_n**，各自在本地域做
"异步置位 + 同步释放"（`rtl/fifo_async.v` 内部已经给每域各做了一条 `*_rst_sync`，
所以调用方**直接把同一个 reset_n 接到 wr_rst_n 与 rd_rst_n 即可**）。
**mmcm_locked 绝不进 FIFO 的复位路径。**
数据面"功能性"逻辑的复位用 `clk_gen_p6b.rst_dp`（含 locked），但那不驱动 FIFO 指针。
```
接线（施工照抄）：
```verilog
fifo_async #(.WIDTH(77), .DEPTH(256), .FWFT(1), .AW(8)) u_rxcdc (
    .wr_clk(gmii_clk),  .wr_rst_n(reset_n),  .wr_en(rx_tvalid), .din({rx_tdata,rx_tkeep,rx_tuser,rx_tlast,rx_tcrs,rx_terr}), .full(rx_fifo_full),
    .rd_clk(dp_clk),    .rd_rst_n(reset_n),  .rd_en(vs_tvalid && vs_tready), .dout({vs_tdata_r,vs_tkeep_r,vs_tuser_r,vs_tlast_r,vs_tcrs_r,vs_terr_r}), .empty(rx_fifo_empty),
    .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray()
);
assign rx_tready = ~rx_fifo_full;      // FE 侧反压 (本地组合, 不跨域)
// DP 侧读口 = FWFT: vs_*_r 就是头字; vs_tvalid = ~rx_fifo_empty
```
> ⚠️ `rtl/fifo_async.v` 头注释的**硬契约 ②** 原文：
> "**只复位一侧 ⇒ 指针不一致 = 未定义行为 (静默脏数据)**"，并给出可预测后果
> （只复位读侧 ⇒ 多弹；只复位写侧 ⇒ 多写覆盖未读槽）。这正是本节要防的东西，
> 而且它**与本文档原稿的"两侧都接 reset_n"完全一致** —— 施工时别自作聪明把 `rst_dp` 接到读侧。
理由：`locked` 只回答"新域能不能算数"，不该回答"两个指针是不是同代"。
若 `locked` 抖动（100MHz 参考钟丢失），dp_clk 会停 ⇒ DP 侧不推进 ⇒ FE 侧的 `full` 最终拉高
⇒ `u_mac_rx` 丢帧（**降级但不错**）；时钟恢复后握手自动续上（`rtl/snap_cdc.v:33-47`
记录过同源结论："观测通道只会暂时没更新，不会永久失明"）。

---

## 5. 时钟频率相关常数清单（**逐个 file:line**）

复跑命令：
```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
grep -rn "BIT_LAST\|GAP_TICKS\|GAP_LAST\|WDOG\|RTO_LIM\|FIN_TO_LIM\|FIN_GRACE\|TX_GAP\|act_tmr\|BOOT_HALF\|BLK_HALF\|uart_sel" rtl/ board/ | grep -v "\.log"
```

### 5.1 ★ 必须改（单位是"拍"，且搬进 156.25MHz 域）

| file:line | 信号 | 现常数 | → 新值 | 语义 | 不改的后果 |
|---|---|---|---|---|---|
| `rtl/app_status_uart.v:42` | `BIT_LAST` | `14'd13020` | **`14'd16275`** | UART 每比特拍数−1（9600 baud） | 波特率变 12000，PC 收到全乱码。156250000/9600 = 16276.04 ⇒ 周期 16276 拍（`BIT_LAST=16275`）误差 +0.0003%，优于现状 |
| `rtl/app_status_uart.v:43` | `GAP_TICKS` | `28'd250_000_000` | **需 29 位**: `29'd312_500_000` | 状态行行间 ≈2s | ⚠️ **2²⁸ = 268,435,456 < 312,500,000 ⇒ 现位宽装不下**，必须把参数与 `gap` 寄存器一起加宽到 `[28:0]`。不改 ⇒ 截断成 43,564,544 ⇒ 行间期错乱 |
| `board/uart_dbg.v:139` | `BIT_LAST`（`uart_tx_9600` 默认） | `14'd13020` | **`14'd16275`** | 同上 | 同上 |
| `board/uart_dbg.v:193` | `BIT_LAST`（`dbg_line_tx` 默认） | `14'd13020` | **`14'd16275`** | 同上 | 同上 |
| `board/uart_dbg.v:194` | `GAP_LAST` | `30'd624_999_999` | **`30'd781_249_999`** | 行重复间隔 5s−1 | 30 位够（2³⁰=1.07e9）; 不改 ⇒ 4s |
| `rtl/slow_rx_adp.v:18` | `WDOG` | `22'd2097152` (2²¹) | **`22'd2621440`** | HLS 饥饿看门狗 ≈16.8ms | 变 13.4ms；⚠️ 位宽注释已警告 `[20:0]` 会把 2097152 截成 0。22 位够（<2²²） |
| `rtl/slow_rx_adp.v:119` | `rst_cnt <= 7'd64` | `7'd64` | **`7'd80`** | 看门狗复位脉冲宽度（64 拍=512ns） | 变 410ns；⚠️ **必须与 `wrapper_p4.v:2378` 的 W17 口径 ÷64 同步改 ÷80** |
| `rtl/tcp_tx_frame.v:162` | `RTO_LIM` | `48828` | **`61035`** | RTO = RTO_LIM×16×16 拍 = 100ms | 变 80ms ⇒ 与慢路径 HLS 的 RTO 一起漂（见 §5.3） |
| `rtl/app_ctrl.v:215` | `FIN_TO_LIM` | `18'd195313` | **`18'd244141`** | 关闭超时 400ms（单位=轮×256 拍） | 变 320ms ⇒ **早于 4×RTO 触发 RST ⇒ 把还活着的半关闭连接砍掉**（CLAUDE.md 坑 15 的历史故障）⚠️ 18 位上限 262143，**244141 刚好塞得下，没有余量** |
| `rtl/app_ctrl.v:222` | `FIN_GRACE` | `18'd4` | **`18'd5`** | RST 宽限 4 轮×256 拍=8.2µs | 变 6.6µs；5 轮×256×6.4ns = 8.19µs ✓ |
| `rtl/app_pattern.v:284,536-540` | `act_tmr` | `20'd200_000` | **`20'd250_000`** | LED 活动保持 1.6ms | 纯观感；20 位够 |
| `board/wrapper_p4.v:2117` | `BOOT_HALF` | `25'd25_000_000` | **`25'd31_250_000`** | 上电 LED 自检半周期 0.2s | 变 0.16s；25 位够（<2²⁵=33.5M） |
| `board/wrapper_p4.v:2146` | `BLK_HALF` | `25'd31_250_000` | **`25'd39_062_500`** | blink 编码器半周期 0.25s | ⚠️ **39,062,500 > 2²⁵ (33,554,432) ⇒ 25 位装不下，必须加宽到 `[25:0]`** |
| `board/wrapper_p4.v:2205,2208` | `uart_sel[29]` 切换点 | 判据 `!uart_sel[29]` ⇒ 在 2²⁹ = 536,870,912 拍停下（4.295s） | **`30'd671_088_640` 拍**；⚠️ 671,088,640 = 2²⁹ + 2²⁷ **不是 2 的幂** ⇒ 判据必须从"单个位测试"改成**幅值比较**（`uart_sel < 30'd671_088_640`）。`reg [29:0]` 的位宽**够**（2³⁰=1.07e9 > 6.71e8），**不需要加宽** | APP_MODE 切到 app 状态行的时刻 4.295s | 不改 ⇒ 切换点提前到 3.44s（PC 侧能容错，但口径变） |
| `rtl/app_udp_pattern.v:86` | `TX_GAP` | `16'd0`（**当前不生效**） | 若重新启用需 ×1.25 | 帧间限速拍数（历史值 58000≈24.7Mbps） | 当前 `TX_GAP=0`（`board/wrapper_p4.v:1878` 例化处覆盖为 0）⇒ **本次不改**；但注释里要写清"历史值 58000 在 156.25MHz 下应取 72500，而 16 位装不下 ⇒ 要加宽到 17 位" |
| `rtl/app_ctrl.v:306`（注释） | `stat_fc_wait_max > 16384 拍` | 16384 | 20480 | 哨兵阈值（仅文档/观测） | 不改 ⇒ 文档与实际不符 |

### 5.2 ✗ **绝不能改**（单位是字节/帧/条目/协议常量）

| file:line | 常数 | 为什么不能改 |
|---|---|---|
| `rtl/mac_tx_64.v:180` | `ifg_cnt == 4'd11`（12 拍） | **它是"字节时间"**：本模块 clk 恒 125MHz 且 1 字节/拍 ⇒ 12 拍 = 12 字节 = 802.3 最小 IFG。**P6b 保持 MAC 在 125MHz ⇒ 该常数继续正确**（这正是选方案 A 的好处） |
| `rtl/mac_tx_64.v:29` | `MIN_CLEN = 16'd60` | 字节 |
| `rtl/mac_tx_64.v:41` | `fifo_sync .D(16)` | 条目 |
| `rtl/mac_rx_64.v:40` | `CRC_RESIDUE = 32'hDEBB20E3` | 魔数 |
| `rtl/mac_rx_64.v:233` | `fifo_sync .D(8)` | 条目 |
| `rtl/slow_rx_adp.v:69,83` | `frame_fifo D=512` / `fifo_sync D=2048` | 条目 |
| `rtl/slow_rx_adp.v:147` | `occ <= 12'd256` | 字节（节流门限）。⚠️ **副作用随频率变**：HLS 读速 ×1.25 ⇒ 节流效果变弱 25%（无功能危害） |
| `rtl/slow_tx_adp.v:46,102-104` | `skip_cnt` 15 / 4 | 前导字节数 |
| `rtl/slow_cfg_adp.v:64` | `fifo_sync D=16` | 条目 |
| `rtl/tcp_tx_frame.v:173,179,190-191,201-202` | `RING_CAP=0xBFFE` / `PLEN_MAX=1500` / `ACKQ_D=32` / `wait_cnt,hcnt` | 字节 / 条目 / **流水级数**（流水级不是时间） |
| `rtl/udp_tx_frame.v:65,81-82` | `PLEN_MAX` / 流水级 | 同上 |
| `rtl/tcb.v:140-141`、`rtl/retx_ram.v:6,119-120` | `65536`/`0xBFFE`/`4095`/`53244` | 字节/ring 容量 |
| `rtl/frame_fifo.v:54-56` | `W=73 D=2048 AW=11` | 条目 |
| `rtl/udp_split.v:97-160` | `D=32/PRE_AW=4/PB_AW=5/DESC_AW=6/UDP_AW=9` | 条目 |
| `rtl/app_pattern.v:27-29` | `TX_BYTES=1048576` / `TX_SEGSZ=1460` / `BAD_LEN=2000` | 字节 |
| `rtl/app_udp_pattern.v:79,93` | `TX_BYTES` / `PLEN_MAX=1500` | 字节 |
| 无时间常数的文件 | `rtl/udp_tx_cfg.v` / `tcp_cam.v` / `tcp_synp.v` / `rx_classify.v` / `vlan_strip.v` / `snap_cdc.v` / `tx_arb.v` / `checksum16.v` / `crc32_8b.v` / `udp_echo.v` / `tcp_echo.v` / `axis_pipe.v` / `fifo_sync.v` | 逐个 grep 过，只有状态机编码 / FIFO 深度 / 帧数 |

> ⚠️ **`board/wrapper_p4.v:48` 的注释**（"9600-8N1, gmii_clk 125MHz 域, 13021 拍/位"）与
> `board/wrapper_p4.v:2378` 的注释（"64 拍 = 512ns"、"÷64"）**必须同步改**，否则文档与 RTL 分叉
> （本工程把"文档与 RTL 分叉"当硬失败看）。

### 5.3 HLS（`udp_echo`，`hls/slowstack_prj/solution1/syn/verilog/`）—— **改不了，只能记录**

**它现在跑在 `gmii_clk` 上**：`board/wrapper_p4.v:1772` `.ap_clk (gmii_clk)`。
**P6b 之后它跑在 `dp_clk` (156.25MHz)**（⇒ 所有内部 `pass` 计数折算的墙钟时间 **×0.8**）。

| HLS 源码 | 常数 | @125MHz | @156.25MHz | 影响面 |
|---|---|---|---|---|
| `hls/src/eth_types.h:77` | `DHCP_TIMEOUT = 0x1000000` | ~130 ms | **~104 ms** | DHCP 重试节奏 |
| `hls/src/eth_types.h:176` | `TX_PACING_COUNT = 625000000` | ~5 s | **~4 s** | 周期 HELLO 帧 |
| `hls/src/layer_tcp.cpp:40` | `TCP_RTO_MIN = 10000000` | ~80 ms | **~64 ms** | 慢路径 TCP 最小 RTO |
| `hls/src/layer_tcp.cpp:77` | `ACTIVE_DELAY = 250000000` | ~2 s | **~1.6 s** | 主动建连等待 |
| `hls/src/layer_tcp.cpp:80` | `ACTIVE_ARP_INTERVAL = 5000000` | ~40 ms | **~32 ms** | ARP who-has 重发 |
| `hls/src/layer_stats.cpp:27` | `timer < 100000000` | ~0.8 s | **~0.64 s** | 状态上报节流 |
| `hls/src/udp_echo.cpp:128` | `dhcp_delay > 100000000` | ~1 s | **~0.8 s** | 上电到启动 DHCP |
| 与频率无关 | `TCP_MAX_RETRY=3` / `ACTIVE_ARP_RETRY=3` / `L1_AGE_BITS=3`(LRU 档位) / `DHCP_MSG_SIZE` / 缓冲区偏移 / 端口号 | — | 不变 | — |

**"外部拍数补偿"怎么做（这是任务书问的那一问）**：

1. **能补的只有"RTL 侧对 HLS 施加的时间窗"** —— 那就是
   `rtl/slow_rx_adp.v:18` 的 `WDOG`（饥饿看门狗）：它决定"**给 HLS 多少墙钟宽限才踢它复位**"。
   按 §5.1 改到 `22'd2621440` ⇒ HLS 拿到**同样的 16.8 ms**，即使它的内部常数已经漂了。
   `board/wrapper_p4.v:2378` 的 W17 口径随之从 ÷64 改 ÷80。
2. **不能补的是 HLS 内部的时间语义**（RTO / DHCP 超时 / HELLO 周期）—— 除非
   ⓐ **重跑 HLS**：`hls/run_hls_active_board.bat:11` 的 `--freqhz 125000000` 与
   `hls/run_hls_active_board.tcl:25` 的 `create_clock -period 8` 一并改成 `156250000` / `6.4`
   ⇒ **换掉整份生成 RTL**（`hls/slowstack_prj/solution1/syn/verilog/` 173 个 `.v`），
   这是 P6b **范围之外**的变更，需要重跑全部 HLS 相关门；或
   ⓑ 给 HLS 单独一个 **125MHz 的 MMCM 输出**（第二个 dp 域 + 4 条新跨域：
   `rx_stream`(16b) / `tx_stream`(16b) / `cfg_stream`(32b) / `msg_stream`(16b, 其 TREADY 恒 1)）
   —— 那是**回退方案**，不是基线。
3. **P6b 的决策：不重跑 HLS，接受 ×0.8 漂移，并在文档里点名。**
   理由（可复核）：P6b 的两条板级验收都不碰 HLS 的墙钟——
   - **ping**（`_proj_pcie/p6e_pingtest.sh`）= ICMP echo，慢路径**无任何计时器参与**；
   - **图案/吞吐**（`p6e_rate.sh` + `tools/cpp_peer`）= UDP 8081，走 app 通路**不进 HLS**。
   ⇒ 漂移对验收不可见。**但必须在 P6B_SPEC → P6E_OBS 的寄存器表里注明"HLS 内部计时已 ×0.8"**，
   否则将来有人拿 100ms/5s 去对账会误判。

⚠️ **一条时序上的连带证据（重要，能省一轮猜）**：
`hls/slowstack_prj/solution1/solution1.log:517` 有唯一一条
`WARNING: [HLS 200-871] Estimated clock period (6.373 ns) exceeds the target (… effective delay budget: 5.840 ns)`
（模块 `tcp_parse_opts`）。**这条在 P6b 下不需要重新裁决**：
闸 G 的 t6p4 档把**整设计（含 HLS）**按 6.400 ns 约束综合+实现，读数是
**WNS +0.426 / 0 setup 失败端点 / 0 hold 失败端点**
（`p6a_ku5p_verify/p6a_t6p4_failing_endpoints.txt` 只有表头、无数据行；
`p6a_ku5p_verify/p6a_t6p4_clocks.rpt` 显示 `phy1_rxc`/`gmii_clk` 都是 6.400 ns）
⇒ **HLS 在 6.4 ns 下已实测收口**，HLS 的 6.373 ns 估计是布局前悲观值。

---

## 6. 复位方案

### 6.1 DP 域复位（新域）—— **已由 `rtl/clk_gen_p6b.v` 实现**（对齐见 §0.3-A2）

**不要再手写**：例化 `clk_gen_p6b` 就有了。它的接口是
```verilog
clk_gen_p6b #(
    .SIM_BYPASS       (0),          // TB 用 1 (行为级时钟模型, 不等 MMCM 锁定)
    .CLKIN1_PERIOD_NS (10.000),     // Y1 = 100MHz
    .CLKFBOUT_MULT_F  (12.500), .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(8.000)
) u_clkgen (
    .clk_p(sys_clk_p), .clk_n(sys_clk_n),
    .rst_ext(~reset_n),             // ★ 高有效异步置位 (板级 PERST#)
    .clk_dp(dp_clk), .clk_in_100(), .locked(mmcm_locked), .rst_dp(rst_dp)
);
// 数据面功能逻辑统一用 rst_dp (高有效):
always @(posedge dp_clk or posedge rst_dp) if (rst_dp) … else …
```
它内部的复位结构（`rtl/clk_gen_p6b.v` 的 "locked 的语义" 一节 + 末尾的 `rel_sr` 块）：
```verilog
wire rst_async = (~locked_raw) | rst_ext;      // 置位: 异步, 立即可靠
(* ASYNC_REG *) reg [3:0] rel_sr;              // 释放: 连续 4 个 clk_dp 沿看到 0 才放行
always @(posedge clk_dp or posedge rst_async)
    if (rst_async) rel_sr <= 4'h0; else rel_sr <= {rel_sr[2:0], 1'b1};
assign rst_dp = ~rel_sr[3];
```
⇒ **等价于本文原稿的三段式**（`reset_n` 异步置位 + `locked` 参与释放 + 多拍同步释放），
只是把置位源写成了 `rst_ext(高有效) | ~locked`、极性改成高有效。
**两条避坑要点它都满足**：置位是异步的（`locked` 掉了立刻停摆），**释放是同步的**（下游无
recovery/removal 风险）。

### 6.2 **为什么不能把 `locked` 直接当复位**（任务书要求说清理由）

| # | 理由 |
|---|---|
| ① | `locked` 的跳变**与 `dp_clk` 沿完全无关**（它来自 MMCM 内部 100MHz 参考域的逻辑）⇒ 直接当异步复位会让**每一个**它驱动的 FF 都跑 recovery/removal 检查，必然出 CDC-13/14 类违例；工具会报、且真板上有**亚稳态 startup 态**（不同 FF 在不同拍脱离复位） |
| ② | `locked` **低 ≠ 时钟停**，`locked` **高 ≠ 时钟已经稳定足够久**。直接用它会得到一个"释放时刻与时钟相位无关"的复位 ⇒ 复位后的**第 1 拍落在哪不确定**（对握手类逻辑就是随机丢 1 个事件） |
| ③ | `locked` **不覆盖 `reset_n`**。板级 PERST# 拉低时 `locked` 可能仍是高的（参考钟还在）⇒ 复位失效 |
| ④ | 它是一个**大扇出的电平**，当异步复位用等于造了一根"伪时钟网"，工具报高 skew 且布局受限 |

⇒ **替代做法就是 6.1 的三条**：`reset_n` 做异步置位（物理上与板级复位同源），
`locked` 经 2FF 同步后**参与"释放"的条件**（不是参与"置位"）。

⚠️ **与已落地实现逐条对照**（`rtl/clk_gen_p6b.v`，见 §0.3-A2）：
它的 `rst_async = (~locked) | rst_ext` 把 `locked` 用在了**异步置位**侧 —— 这**不违反**上面四条，
因为四条反对的核心是"**释放也异步**"：
| 理由 | 实现的处理 | 成立? |
|---|---|---|
| ① recovery/removal | 释放走 `rel_sr` 的 **4 拍同步**（`posedge clk_dp`）⇒ 释放沿与时钟对齐 | ✅ 规避 |
| ② "释放时刻不确定" | 同上；且 4 拍释放窗口 ≫ 时钟稳定时间 | ✅ 规避 |
| ③ `locked` 不覆盖 `reset_n` | `rst_ext`（= `~reset_n`）是**第二个独立置位源** | ✅ 规避 |
| ④ 大扇出伪时钟网 | `rst_dp` 本来就要驱动整个 DP 域 ⇒ 扇出无增量 | ⚠️ 可接受（非缺陷） |
⇒ **结论：实现的写法是对的，本文档原稿与它等价，不要再改。**

### 6.3 FE 域复位

**原样保留**：`always @(posedge gmii_clk or negedge reset_n)`，`reset_n` 直接当异步复位
（`board/wrapper_p4.v` 全篇现状）。**改动只有一处**：`u_slow_cfg` 的
`.rst_n (reset_n & hls_rst_n)`（`board/wrapper_p4.v:1398`）—— `hls_rst_n` 现在由 DP 域的
`u_slow_rx` 产生，而 `u_slow_cfg` 也搬到 DP 域 ⇒ **同域，无 CDC**，保持原式即可。

### 6.4 `snap_cdc` 的 b 域时钟

| 实例 | `clk_a` | `clk_b` | `rst_n` | 备注 |
|---|---|---|---|---|
| `u_snap_fe` | `pcie_axi_aclk` | **`gmii_clk`** | `pcie_axi_aresetn` | 内部有 `rstb_sync`（`rtl/snap_cdc.v:67-72`）自同步到 b 域 |
| `u_snap_dp` | `pcie_axi_aclk` | **`dp_clk`**（**新**） | `pcie_axi_aresetn` | 同上 |

⚠️ **`clk_b` 换成 `dp_clk` 的直接后果（必须写进文档）**：
若 MMCM 未锁定 / `sys_clk_p` 未接 ⇒ `dp_clk` 不跑 ⇒ `busy_a` **恒高**、`valid_a` 永不出现
⇒ 主机看到 `SNAP_STATUS.busy = 1` 永久。**这正是既有的诊断语义**
（`P6E_OBS.md` §一："busy 一直不落 = gmii 时钟没在跑"），现在它同时对两个域成立。
⇒ **为把这句诊断变成可自动判定的**：把 `mmcm_locked` 的 axi 域同步版接到
`SNAP_STATUS[6]`，主机就能分开"没锁定" vs "没触发"（见 §7.2）。

⚠️ **`snap_seq` 的复位**：`pcie_axi_aresetn`（同 axi 域）。若序列器卡在 `WAIT_FE`/`WAIT_DP`
（对应域的时钟停了），`busy` 恒高 ⇒ 主机看到 `SNAP_CTRL` 写了但 `done` 永不置。
语义与现状一致（"没时钟"），并可用 `SNAP_STATUS[5:3]` 分辨卡在哪个域。

---

## 7. 快照窗口计划（施工级）

### 7.1 新增字（≥1 条"可独立复算"的正证据）

| 字 | 地址 | 内容 | 域 | 为什么必须有 |
|---|---|---|---|---|
| **W24** | `0x80` | `dp_free` —— **DP 域 32 位自由计数器** | DP | ⭐ **"数据面真在 156.25MHz 跑"的唯一正证据**。主机两次触发、按墙钟间隔反解频率（见 §7.6）。32 位 @156.25MHz **每 27.49 s 绕一圈** ⇒ 判据必须用 **< 20 s** 的间隔 |
| **W25** | `0x84` | `{31'd0, mmcm_locked_sync_dp}` | DP | ⭐ 任务书要求的 MMCM locked 位。⚠️ 同时**镜像**到 `SNAP_STATUS[6]`（axi 域，见 §6.4），因为 DP 束在时钟停摆时读不到 —— 两个位置都要有 |
| W26 | `0x88` | `rxcdc_full_cycles` —— `u_rxcdc.full` 高电平**拍数** | FE | RX 方向"DP 跟不上"的直接量（§4.2 的症状判据）。**零新增硬件**（`full` 本来就在 FE 域） |
| W27 | `0x8C` | `{16'd0, rxcdc_occ_max}` —— `u_rxcdc` 历史最大占用（字） | FE | 深度探针：贴 256 ⇒ 深度真的不够。⚠️ **需要给 `fifo_async` 加一个 `dbg_occ_w` 输出**，见下 |
| W28 | `0x90` | `{16'd0, txcdc_occ_max}` —— `u_txcdc` 历史最大占用（字） | DP | 同上的 TX 版，需要 `dbg_occ_r` |
| W29 | `0x94` | `txwire_stall_cycles` —— DP 侧 `m_tx_tready==0 && m_tx_tvalid==1` 的拍数 | DP | 区分"DP 在等线"与"DP 在丢帧"（§4.3） |
| W30 | `0x98` | `rxcdc_out_frames` —— RX FIFO **读侧** TLAST 数 | DP | ⭐ **跨域完整性锚点**：与 W0 对账（§7.3） |
| W31 | `0x9C` | `rxcdc_out_bytes` —— RX FIFO 读侧 `Σpopc(tkeep) + 4×帧数` | DP | ⭐ 与 W1 对账（**理论上逐位相等**，见 §7.3）。**这一条就是"可独立复算"的正证据** |

### 7.2 窗口布局与两束归属

| 束 | 字数 | 成员（按向量 LSB→MSB 顺序 = 拼接右→左） |
|---|---|---|
| **FE** (`u_snap_fe`, NW=10) | 10 | `{rxcdc_full_cycles(W26), {16'd0,rxcdc_occ_max}(W27), mac_tx_frames(W20), tx_stat_abort(W21), gmii_free(W5), rx_stat_drop(W4), rx_stat_crc_err(W3), {16'd0,wl_last}(W2), rx_stat_bytes(W1), rx_stat_frames(W0)}` |
| **DP** (`u_snap_dp`, NW=22) | 22 | `{rxcdc_out_bytes(W31), rxcdc_out_frames(W30), txwire_stall_cycles(W29), {16'd0,txcdc_occ_max}(W28), {31'd0,mmcm_locked_sync_dp}(W25), dp_free(W24), rx_stat_nonmatch(W23), rx_stat_pass(W22), srx_stat_drop(W19), stx_stat_purge(W18), hr_cnt(W17), srx_hls_bytes(W16), tx_stat_bytes(W15), tx_stat_frames(W14), udpapp_mismatch(W13), udpapp_rx_null(W12), udpapp_rx_bytes(W11), udpapp_rx_frames(W10), udpapp_tx_bytes(W9), udpapp_tx_frames(W8), stx_stat_frames(W7), srx_stat_commit(W6)}` |

> ⚠️ **每一项都必须恰好 32 位**：`W27/W28`（占用数最多 256 ⇒ 9 位）与 `W25`（1 位）
> 必须显式零扩展 `{16'd0,…}` / `{31'd0,…}`。**少写零扩展 = 位宽截断**，而
> `xvlog` 对"赋值右端比左端**窄**"只在**部分场景**报 —— 端口的宽窄不匹配它完全不看
> （铁律 ②，本工程 `P6E_OBS.md` 的"扩窗 ⑥"就是这么踩的）。门的 `findstr 10-3091`
> 只能当补充，真判据是逐字读回。

**⚠️ W27/W28 需要给 `rtl/fifo_async.v` 加两个探针输出**（当前只有 `dbg_wbin/dbg_rbin/
dbg_wgray/dbg_rgray`，而 `dbg_rgray` 在写域里是**未同步**的原始灰码总线，
直接组合使用等于多比特 CDC）：
```verilog
// 在 rtl/fifo_async.v 内 (两个值都由**已同步**的指针算出, 天然保守 ≤ 真实占用):
function [AW:0] gray2bin; input [AW:0] g; integer i;
    begin gray2bin[AW] = g[AW];
        for (i = AW-1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
    end
endfunction
assign dbg_occ_w = wbin_r - gray2bin(rgray_s2_w);   // 写域可见占用 (写侧用)
assign dbg_occ_r = gray2bin(wgray_s2_r) - rbin_r;   // 读域可见占用 (读侧用)
```
（两个都是纯组合 assign，与逻辑零耦合 —— 与模块既有探针风格一致。**必须顺手把这两根线
接进 `tb/tb_fifo_async.v` 的判据**：金标准对拍时同步核对 `dbg_occ_w == 队列长度`，
否则探针自己错了没人管。若不想动已落地的模块，退路是**只保留 W26 + W29**
（`full`/`tready` 拍数），放弃 W27/W28 —— 但那会丢掉"深度够不够"的直接读数，
板级就只能靠"W4 涨不涨"间接推。**推荐加探针。**）

**`snap_seq.v` 在 axi 域把两束拼成连续地图**（唯一允许出现索引算术的地方，必须单点化）：
```verilog
// 逻辑上等价的映射表 (施工时用 generate/for 由 localparam 表驱动, **不要手抄 32 个下标**)
// W[i] = (FE_IDX[i] >= 0) ? fe_dout[FE_IDX[i]*32 +: 32] : dp_dout[DP_IDX[i]*32 +: 32]
//        (下标 = **快照字编号** W0..W31; 值 = 该束向量里的字槽, -1 = 不属于本束)
//
// ⚠️⚠️ 【2026-09-29 收尾归档标注】下面这两张数组**是错的**（FE_IDX 把 fe[8]/fe[9] 写在下标 24/25；
//        DP_IDX 在 W26..W31 上整体错位两个槽）—— 它们与**紧接着的那张 32 行对照表**矛盾。
//        **以对照表为准**；最终落地版见 **§0.4 勘误**（那里有 36 字版的完整两张表）。
//        实际实现 `rtl/snap_seq.v:83-118` 用的不是数组而是两个 function，且自检会当场 $finish。
localparam integer FE_IDX [0:31] = '{  0,  1,  2,  3,  4,  5, -1, -1,
                                      -1, -1, -1, -1, -1, -1, -1, -1,
                                      -1, -1, -1, -1,  7,  6, -1, -1,
                                       8,  9, -1, -1, -1, -1, -1, -1 };
localparam integer DP_IDX [0:31] = '{ -1, -1, -1, -1, -1, -1,  0,  1,
                                       2,  3,  4,  5,  6,  7,  8,  9,
                                      10, 11, 12, 13, -1, -1, 14, 15,
                                      16, 17, 18, 19, 20, 21, -1, -1 };
```
**逐项对照（施工时必须拿这张表核对上面两个 `{...}` 的 LSB→MSB 顺序 —— 这是新的第 7 处扩窗风险点）**：

| W | 束 | 槽 | | W | 束 | 槽 | | W | 束 | 槽 |
|---|---|---|---|---|---|---|---|---|---|---|
| W0 | FE | fe[0] | | W11 | DP | dp[5] | | W22 | DP | dp[14] |
| W1 | FE | fe[1] | | W12 | DP | dp[6] | | W23 | DP | dp[15] |
| W2 | FE | fe[2] | | W13 | DP | dp[7] | | W24 | DP | **dp[16]** |
| W3 | FE | fe[3] | | W14 | DP | dp[8] | | W25 | DP | **dp[17]** |
| W4 | FE | fe[4] | | W15 | DP | dp[9] | | W26 | FE | **fe[9]** |
| W5 | FE | fe[5] | | W16 | DP | dp[10] | | W27 | FE | **fe[8]** |
| W6 | DP | dp[0] | | W17 | DP | dp[11] | | W28 | DP | **dp[18]** |
| W7 | DP | dp[1] | | W18 | DP | dp[12] | | W29 | DP | **dp[19]** |
| W8 | DP | dp[2] | | W19 | DP | dp[13] | | W30 | DP | **dp[20]** |
| W9 | DP | dp[3] | | W20 | FE | **fe[7]** | | W31 | DP | **dp[21]** |
| W10 | DP | dp[4] | | W21 | FE | **fe[6]** | | | | |

> ⚠️ **注意 W20/W21 与 W26/W27 的槽号是"反的"**（拼接的 MSB 端先出现）：
> FE 束 `{W26, W27, W20, W21, W5, W4, W3, W2, W1, W0}` 从右往左读 ⇒ `fe[6]=W21, fe[7]=W20,
> fe[8]=W27, fe[9]=W26`。**这正是"手抄下标"最容易错的地方**，也正是全链门必须逐字读回
> 32 个字的原因（错一处只会读出"另一个字的正确值"，单测一遍看不出来）。
⚠️ **`FE_IDX`/`DP_IDX` 是新的"第 7 处"扩窗风险点**（旧文档只列到第 ⑥ 处）。
施工铁律：**这两张表 + 两束的拼接项数 + `SNAP_NW_P6E` 四处，必须由同一个 `localparam` 派生**；
门必须"逐字读回 32 个字 + 每个字单独 force 成不同常数"（照抄 `sim/p6e_pcie/tb_p6e_pcie_wrapper.v:137-163`
的模式，扩到 32 路 + 两个束），否则索引表错了 lint 完全看不见。

### 7.3 W30/W31 为什么是"可独立复算的正证据"（含判据的**正确**表述）

**证明（W1 与 W31 的关系）**：
- `rtl/mac_rx_64.v:177` `fbytes <= fbytes + 1`（每个 `S_DATA` 拍 = 内容+FCS 的字节）
  ⇒ **`stat_bytes` = Σ(内容 + 4)**（`:152,172,216` 三处都累加 `fbytes`）。
- 打包逻辑（`:180-199`）：每 8 个内容字节组成 1 个满字（`wkeep <= {wkeep[6:0],1'b1}`），
  最后一个不满字在 `:165-166`/`:209-210` 用 `ljust64/ljust8(wreg,wkeep,bcnt)` 交付
  ⇒ **一帧的 `Σpopc(tkeep) = 内容字节数`**。
- 因此 `Σpopc + 4×帧数 = Σ(内容+4) = stat_bytes`。**逐位相等。**

**但"读到的两个值相等"只在一种条件下成立**：两次采样时 **RX FIFO 是空的**。
因为 W0/W1 在**写侧**（FE）、W30/W31 在**读侧**（DP），两者天然差一个"在飞量"。

⇒ **判据必须写成两句，不许写成"W1 == W31"**：

| 判据 | 形式 | 用途 |
|---|---|---|
| **C1（板级，最干净）** | **停流量 → 等 ≥1 个最大帧时间（≥ 13 µs）→ 触发快照 ⇒ 必须有 `W0 == W30` 且 `W1 == W31`（逐位）** | 停机态下 FIFO 必空 ⇒ 这是**精确等式**，任何 CDC 丢/重/位错都当场现形 |
| **C2（在跑流量时）** | `(W0 - W30)` 与 `(W1 - W31)` **在每个采样间隔里必须"有界且不漂移"**, 上界 = 256 字 × 8 B = 2048 B（+ 一帧） | 长跑回归用；单调漂移 = CDC 完整性故障 |

⚠️ **`W0 - W30` 是有向的**（链式触发保证了 W30 的采样时刻不早于 W0）⇒ **`W0 - W30 ≥ -1`**
（允许 -1 是因为 DP 侧可能在两次锁存之间多读走一帧）。写判据时用 `-1 ≤ W0-W30 ≤ 界`，
**不要**用 `|W0-W30| ≤ 界`（那会掩盖方向性错误，比如两个束的先后被写反）。

### 7.4 扩窗"**逐处**同改"清单（旧的"五处"已扩到**七处**）

| # | 处 | 文件:行 | 现在 | → 新值 |
|---|---|---|---|---|
| ① | 字数单一来源 | `board/wrapper_p4.v:2339` | `localparam SNAP_NW_P6E = 24;` | `= 32;` + 新增 `SNAP_FE_NW=10`/`SNAP_DP_NW=22` |
| ② | 拼接项数 | `board/wrapper_p4.v:2432-2455` (`snap_src`) | 24 项 | 拆成 `fe_src`(10) + `dp_src`(22)，两处项数各自精确 |
| ③ | `snap_base` 位宽 | `_proj_pcie/rtl/axi_regs.v:197` | `wire [9:0] snap_base = {snap_idx, 5'b0};` | **无需改**（NW=32 时最大 `{31,5'b0}`=992 < 1024 ✓）。**但要在注释里写死："这是 NW=32 的上限，再扩就装不下"** |
| ④ | `axi_regs.SNAP_NW` | `board/wrapper_p4.v:2538` | `.SNAP_NW (SNAP_NW_P6E)` | 不变（自动跟随） |
| ⑤ | **验收/采样脚本的"未实现地址"** | `_proj_pcie/p6e_snap_check.sh:161`(注释) / `_proj_pcie/p6e_boot_timeline.sh:23`(注释) / `_proj_pcie/p6e_watch.sh:15`(注释) / `_proj_pcie/tb/tb_axi_regs.v:181,183,187,207,269`(实判据) | `0x84` | **`0xA0`** ⚠️ 新判据地址既是 word 40，且 `0xA0 < 0x100` 不触发 256B 回绕红线。⚠️ **2026-09-29 标注**：最终 36 字版取 **`0xB0`**（word 44）⇒ **见 §0.4.3** |
| ⑥ | 三个门自己的参数 | `_proj_pcie/tb/tb_axi_regs.v:51,55,70,144,149,151,251,261,263`; `tb/tb_snap_cdc.v:31`; `sim/p6e_pcie/tb_p6e_pcie_wrapper.v:114,137-163`; `sim/p6e_pcie/tb_p6e_pcie_counters.v:156` | `SNAP_NW(24)` / `snap_din[767:0]` / `w8[0:23]` / `NW=24` / force 23 路 / `BUILD_ID=4` | 32 / `[1023:0]` / `w8[0:31]` / `NW=32` / force 32 路(+2 束) / `BUILD_ID=5` |
| ⑦ | ⭐ **新**: 两束索引表 | `_proj_pcie/rtl/snap_seq.v` 的 `FE_IDX`/`DP_IDX` | — | 必须与 §7.2 的两张表逐项一致，且由单一 `localparam` 派生。⚠️ **2026-09-29 标注**：本行原写的"§7.2 的两张表"指的是 §7.2 的**逐项对照表**，**不是**那段 `localparam` 例子（例子本身是错的）⇒ **请按 §0.4 勘误的两张表**（36 字版）。落地实现落在 `rtl/snap_seq.v`（不是 `_proj_pcie/rtl/`）|

### 7.5 `BUILD_ID` 与 `SNAP_STATUS`

| 项 | 位置 | 现在 | → 新值 |
|---|---|---|---|
| `BUILD_ID_V` | `board/wrapper_p4.v:2535` | `32'h00000004` | **`32'h00000005`**（P6b 双时钟域 32 字）。⚠️ **2026-09-29 标注**：最终落地是 **`32'h00000006`**（36 字 + F-1/F-2 修复），板级实测 A2 = `0x00000006` ⇒ **见 §0.4.3** |
| 期望值 | `_proj_pcie/p6e_snap_check.sh:20` | `EXPECT_BID=0x00000004` | **`0x00000005`** |
| 期望值 | `sim/p6e_pcie/tb_p6e_pcie_wrapper.v:114` | `32'h00000004` | `32'h00000005` |
| 期望值 | `sim/p6e_pcie/tb_p6e_pcie_counters.v:156` | `32'h00000004` | `32'h00000005` |
| `SNAP_STATUS` 位域 | `_proj_pcie/rtl/axi_regs.v:198` | `{snap_gen_r, 13'd0, seen, done, busy}` | **新增 3 位**: `[5]=fe_busy, [4]=fe_seen, [3]=fe_done`；`[6]=mmcm_locked_sync_axi`；`[15:7]` 保持 0 |

⚠️ **`SNAP_STATUS` 加了位但不改已有的位**（`[2:0]` 与 `[31:16]` 语义逐位不变）⇒ 所有按
`(s >> 16) & 0xffff` 取 `gen`、按 `s & 0x7` 取 busy/done/seen 的脚本**不用改**。
这一点必须写进文档，否则会有人去改脚本。

### 7.6 W24 频率判据（可独立复算）

```
① 快照 A → 读 W24 = a, 记主机墙钟 t_a (v4l 用 `date +%s.%N`)
② 等 Δ = 10 s (取 < 20 s: 32 位 @156.25MHz 每 27.49 s 绕一圈)
③ 快照 B → 读 W24 = b, 记 t_b
④ f = ((b - a) mod 2^32) / (t_b - t_a)
   判据: 155.0 MHz ≤ f ≤ 157.8 MHz   (±1%)
   参考: 一次成功量测应给出 156.2499…MHz ± MMC 晶振容差(±50ppm) ± 主机时钟误差
```
⚠️ **前置条件（否则判据假 FAIL）**：`W25.bit0 (mmcm_locked) == 1` **且** `SNAP_STATUS[6]==1`；
否则时钟本身不在跑而在"归零"（`dp_rst_n` 会清 `dp_free`）⇒ 先修时钟再看频率。

### 7.7 验收/采样脚本：**哪些要改、哪些明确不用改**

| 脚本 | 要不要改 | 逐行 |
|---|---|---|
| `_proj_pcie/p6e_slowpath_probe.sh` | **要改 2 处** | `:45` 与 `:50` 的 `for a in 20 24 … 7c` 列表要补 `80 84 88 8c 90 94 98 9c`；`:70` 的说明文案（W16 累计口径）不变。**W0/W6/W7/W16/W17/W18/W19/W20 的 W 号语义不变 ⇒ 其余不用改** |
| `_proj_pcie/p6e_boot_timeline.sh` | **要改 1 处** | `:23` 的注释 `0x84` → `0xA0`；读的 W0/W5/W6/W7/W13 语义不变 ⇒ 其余不用改 |
| `_proj_pcie/p6e_watch.sh` | **要改 2 处** | `:15` 注释 `0x84`→`0xA0`；`:37` 的 `for a in …` 补 8 个地址 |
| `_proj_pcie/p6e_capture.sh` | **要改 2 处** | `:11` 注释、`:30` 的 `for a in …` |
| `_proj_pcie/p6e_snap_check.sh` | **要改 4 处** | `:20` `EXPECT_BID`→`0x00000005`；`:43,45` 的列表与"24 字"文案；`:161` 注释的未实现地址；`:123,126-149` 的 W 号**语义不变**（W0..W23 逐位不动） |
| `_proj_pcie/p6e_pingtest.sh` | **不用改** | `:23` 只读 W0..W7（`0x20..0x3c`），这些字语义完全没动 |
| `_proj_pcie/p6e_precheck.sh` | **要改 1 处** | `:20` 的注释 `BUILD_ID=4` → `5` |

---

## 8. XDC 计划

### 8.1 文件划分（沿用 P6e 的"不复制、不分叉"纪律）

| 文件 | 作用 | 状态 |
|---|---|---|
| `board/ku5p_p6a_t8p0.xdc` | **前端 125MHz**：`create_clock -period 8.000 -name phy1_rxc` + `create_generated_clock … gmii_clk` + RGMII/reset/LED/uart 引脚 | **原样复用，一字不改** |
| `board/ku5p_p6e_pcie.xdc` | PCIe 参考钟 + GT 引脚 | **原样复用** |
| **`board/ku5p_p6b_sysclk.xdc`（新）** | Y1 100MHz 差分输入 + `create_clock` | 新增 |
| **`board/ku5p_p6b_cdc.xdc`（新）** | 三组 `set_clock_groups -asynchronous` | 新增，**必须 `used_in_synthesis false`** |

### 8.2 Y1 频率核实（任务书要求，不许假定）

**已用原理图 PDF 出图核实**（命令可复跑）：
```bash
C:/Users/zhxue/anaconda3/python.exe -c "
import pymupdf
doc = pymupdf.open(r'D:\repo\XCKU5PMini\图纸\核心板\XCKU5PMini.pdf')
p = doc[5]; p.set_rotation(0)
for w in p.get_text('words'):
    x0,y0,x1,y1,t = w[0],w[1],w[2],w[3],w[4]
    if 480 < x0 < 900 and 620 < y0 < 760: print(f'{x0:7.1f} {y0:7.1f}  {t}')
"
```
**原始读数**（页 6，0-based `doc[5]`）：
```
  560.5   647.3  Y1
  542.5   697.6  SG7050VAN-100.000000M-KEGA3      ← 位号 Y1 的完整型号
  711.4   690.4  SYS_CLK_P
  711.4   661.7  SYS_CLK_N
```
⇒ **Y1 = `SG7050VAN-100.000000M-KEGA3` = 100.000000 MHz 差分有源晶振**,
输出网络 `SYS_CLK_P` / `SYS_CLK_N`。**不是 "100MHz 左右"，是 100.000000MHz 的定频晶振**。
（`-KEGA3` 后缀 = 3.3V 供电、LVDS 输出、±50ppm。）

**引脚可布性核实**（Vivado 只读器件模型查询，**不建工程**）：
```bash
cd board/ku5p_probe/clkgen_p6b
"C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat" -mode batch -source pin_probe.tcl \
    -log pin_probe.log -nojournal
```
**原始读数**（`pin_probe.log`）：
```
PACKAGE PIN T25:  PIN_FUNC = IO_L14P_T2L_N2_GC_A04_D20_65   BANK = 65
                  IS_GLOBAL_CLK = 1   IS_DIFFERENTIAL = 1   DIFF_PAIR_PIN = U25
site of T25 = IOB_X0Y80   SITE_TYPE = HPIOB_M   IS_GLOBAL_CLOCK_PAD = 1
MMCM sites: MMCM_X0Y0/X0Y1/X0Y2/X0Y3   (T25 所在 CLOCK_REGION = X0Y1)
BUFGCTRL sites: 32
```
⇒ T25/U25 = **bank 65 (HP) 的 GC（全局时钟）差分对**，其时钟区 X0Y1 **有 MMCM**（`MMCM_X0Y1`）
⇒ **可以直接驱动 MMCM**。✅

**IOSTANDARD**：厂商 `Demo/XCKU5P_PCIe_DDR4_ETH_aurora_12g/src/PCIe.xdc:43-44` 写的是
`DIFF_POD12_DCI`（bank 65 是 DDR4 bank，VCCO=1.2V）。**沿用厂商值**（该 XDC 是这块板上
已经跑通过的约束）。⚠️ 见 §9 风险 R6：若 DRC 拒绝，退路写在那里。

### 8.3 三个时钟的约束写法

```tcl
# ---------------- board/ku5p_p6b_sysclk.xdc (新) ----------------
# Y1 = SG7050VAN-100.000000M-KEGA3 (原理图实测出图, 见 P6B_SPEC §8.2)
create_clock -period 10.000 -name sys_clk_100 [get_ports sys_clk_p]
set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {sys_clk_p sys_clk_n}]
# ⚠️ 不在本文件写 gmii_clk / GMII 相关约束 —— 那是 ku5p_p6a_t8p0.xdc 的事 (基线不许分叉)
```

```tcl
# ---------------- board/wrapper_p4.v (DEV_USP 分支新增) ----------------
# ⚠️ 不要手写 IBUFDS/MMCME4_BASE 原语 —— 例化已落地的 rtl/clk_gen_p6b.v (见 §0.3-A1/A2):
clk_gen_p6b #(
    .SIM_BYPASS       (0),          // TB: 1 (行为级时钟模型, 不等 MMCM 锁定)
    .CLKIN1_PERIOD_NS (10.000),     // ★ 必须与 create_clock 同值 (Y1 = 100MHz)
    .CLKFBOUT_MULT_F  (12.500),     // VCO = 100/1 * 12.500 = 1250.0 MHz
    .DIVCLK_DIVIDE    (1),
    .CLKOUT0_DIVIDE_F (8.000),      // 1250/8 = 156.25 MHz → 6.400 ns
    .REF_JITTER1      (0.010)
) u_clkgen (
    .clk_p(sys_clk_p), .clk_n(sys_clk_n), .rst_ext(~reset_n),
    .clk_dp(dp_clk), .clk_in_100(), .locked(mmcm_locked), .rst_dp(rst_dp)
);
# 内部已含 IBUFDS(DIFF_POD12_DCI, DIFF_TERM=FALSE) + BUFG + MMCME4_BASE + BUFG + 复位同步器
# 只接 CLKOUT0, 其余 CLKOUT 不接负载 ⇒ 不会多产生 5.0–9.0ns 带内的时钟 (见下)。
```
> ⚠️ 本文档原稿的 MMCM 参数是 `MULT=15.625 / CLKOUT0_DIV=10.0`（VCO 1562.5MHz），
> 与实现的 `12.500 / 8.000`（VCO 1250MHz）**都产生 6.400ns**。**以实现的为准**（§0.3-A1）。
> 实现里还额外留了一条**备用路线**（输入 125MHz：`CLKIN1_PERIOD=8.000 / MULT=10.000`，
> **同一个 VCO 1250MHz**），并写明它的代价：`i_rxc` 消失时 MMCM 失锁 ⇒ `rst_dp` 断言 ⇒
> **数据面会跟 PHY 耦合**。⇒ **本设计选 T25/U25 自由运行路线，不走备用路线。**

**`create_generated_clock` 要不要写？**
> **不要手写。** MMCME4_BASE 的输出时钟由 Vivado **自动推导**（依据 `CLKIN1_PERIOD` /
> `CLKFBOUT_MULT_F` / `DIVCLK_DIVIDE` / `CLKOUT0_DIVIDE_F`），推导结果**恰为 6.400 ns**，
> 并会在 `report_clocks` 的 Clock Summary 里出现一行 `Period(ns)=6.400`
> —— 而 `board/check_p6b_timing.py` 判据 2 **正是按周期值自动发现时钟名**（`:19` "网名会变,
> 绝不硬编码"），所以自动推导的时钟名随便叫什么都行。
> ⚠️ **手写 `create_generated_clock` 反而有害**：它会与自动推导的时钟冲突（`CRITICAL WARNING`
> 或生成两个同周期的时钟）。**只在一种情况下才写**：确证自动推导没发生
> （`report_clocks` 里看不到 6.400），此时用
> `create_generated_clock -name dp_clk -source [get_pins u_mmcm_dp/CLKIN1] \
>  -divide_by 10 -multiply_by 125 [get_pins u_mmcm_dp/CLKOUT0]`（等价于 100→156.25）。
> 施工时必须**先跑 `report_clocks` 看那一行在不在**，再决定。

**⚠️ 不许产生 5.0–9.0 ns 带内的第三个时钟**（重要，但**说清它到底会不会判 FAIL**）：
`check_p6b_timing.py:55-59` 定义了 `TOL=3% / FAMILY_LO=5.0 / FAMILY_HI=9.0`。
读代码可知（`:194-227`）：
- `dual` 分支（`:211-219`）与 `auto` 分支（`:221-222`）都**只要求 `have_fe && have_dp`**；
- 只有当这两个不同时成立时，才走到 `:227` 的
  `"该带内有 %d 个周期但既不齐 {~8.000, ~6.400}"` FAIL。

⇒ **一个多余的 5.0–9.0ns 时钟并不会让判据 2 判 FAIL**，但：
1. 它会被打印在"该带内全部周期"那一行（`:204`）⇒ 报告的**自述与预期不符**，属于要被点名的不一致；
2. 一个 200MHz（**恰好 5.000 ns，落在带的下边界 `5.0 <= 5.0`**）会混进 `fam` 集合，
   增加"两个目标周期之外还有东西"的解释成本；
3. 多余时钟自己还要收敛时序（白担风险）。

⇒ **施工纪律：MMCM 只接 CLKOUT0，其余输出不接任何负载。**
（本板 RGMII 在 HDIO、零 IDELAY ⇒ **不需要 IDELAYCTRL ⇒ 不需要 200MHz**，
见 `board/util_gmii_to_rgmii_us.v:27-31`。所以这条纪律零成本。）

### 8.4 `set_clock_groups -asynchronous`

```tcl
# ---------------- board/ku5p_p6b_cdc.xdc (新) ----------------
# ⚠️ 本文件必须 `set_property used_in_synthesis false` (在 build tcl 里设)
#    理由见 ku5p_p6e_cdc.xdc 头注释: XDC 在**综合前**解析, 那时 create_clock 还没生效、
#    XDMA/MMCM 还是黑盒 ⇒ get_clocks 拿到空对象 ⇒ Vivado 报
#    `CRITICAL WARNING [Vivado 12-4739] set_clock_groups: No valid object(s) found`
#    并**静默丢弃**该约束。本工程已实测踩过 (P6e BUILD_ID=2 那版)。
#
# 三个域的物理源互不相同 ⇒ 两两异步:
#   gmii_clk       ← 底板 PHY 的 25MHz 无源晶体恢复出的 RXC
#   dp_clk         ← 核心板 Y1 的 100MHz 有源晶振 (经 MMCM)
#   pcie_axi_aclk  ← 金手指的 100MHz PCIe 参考钟 (XDMA 内部生成)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks phy1_rxc] \
    -group [get_clocks -include_generated_clocks sys_clk_100] \
    -group [get_clocks -include_generated_clocks pcie_axi_aclk]
```
**若某个 `get_clocks` 拿到空对象**（症状：构建日志出现 `Vivado 12-4739` CRITICAL WARNING），
退路是改成按**引脚**取：
```tcl
    -group [get_clocks -of_objects [get_pins u_mmcm_dp/CLKOUT0]] \
```
⇒ **施工时必须在 impl 日志里 grep `12-4739`；命中 = 约束没生效, 必须修**。
（这是本工程已经踩过一次的坑，`board/ku5p_p6e_cdc.xdc:11-15` 有留档。）

### 8.5 必须放在 impl-only XDC 的约束

只有一处：**`set_clock_groups`**（上面整段）。原因是它引用时钟对象，而综合前那些对象不存在。
其余的（引脚 / `create_clock` / `create_generated_clock`）都可以在综合阶段解析 ——
`create_generated_clock` 引用 `u_rgmii/bufmr_rgmii_rxc/O`（RTL 例化点，综合时存在 ✓）。

### 8.6 **预判（可检验的判据）**

| 判据 | 期望 | 若不成立怎么立刻归因 |
|---|---|---|
| setup 失败端点 | **0** | 看 `report_timing` 的域：若失败端点**全在 dp_clk** ⇒ 156.25 域太长；若在 `gmii_clk` ⇒ 前端被动过（不该发生） |
| hold 失败端点 | **0** | P6a 基线的 hold 只有 +0.012/+0.013（`p6a_ku5p_verify/p6a_t6p4_hold_400.rpt`）⇒ 改数据通路就会先在这里塌。查 `report_timing -delay_type min -max_paths 400` 三族 |
| **`IDDRE1/C\|CB` Min-Period 违例数** | **0（闸 G 那 16 条必须消失）** | 若不为 0 ⇒ 前端**没有**被 8.000ns 约束（`create_clock -period 8.000` 丢了 / `phy1_rxc` 名字变了）。闸 G 的 16 条全部是 `required=8.000ns` 的 HDIO 器件上限（`p6a_ku5p_verify/p6a_t6p4_*.rpt`），P6b 前端留 125MHz ⇒ 该检查自然满足 |
| Clock Summary 带内周期 | **恰好 {8.000, 6.400}** | 多出第三个 ⇒ 见 §8.3 的 200MHz 警告 |
| 报告自述 | `All user specified timing constraints are met.` | — |
| **一条命令验证全部** | `python board/check_p6b_timing.py <rpt> --expect dual` 退出码 **0** | 判据 2 会自动发现两个域并按周期打印；判据 3 会点名 `IDDRE1/C\|CB` 的条数 |

---

## 9. 风险表与验收判据

### 9.1 风险表

| # | 风险 | 现象 | 早期信号 | 缓解 | 归属验证手段 |
|---|---|---|---|---|---|
| **R1** | 156.25MHz 数据面时序不收敛 | 位流有 setup/hold 违例 ⇒ 静默读错 | `check_p6b_timing.py` 判据 1 | 闸 G 已实测 "+0.426/0 失败" ⇒ 高置信 | **时序报告** |
| **R2** | 新异步 FIFO 的 FWFT 读侧丢/重/错位（工程坑 4 的形态） | 每一帧的第 N 个字重复或跳过 ⇒ 图案失配 **W13 涨**；ping 偶发失败 | `W13` 非 0 而 `W3`(FCS 错)=0 | 单元门必须含"**空↔非空边界连读**"与"**写空槽同拍读**"两个用例 | **单元门 + 全链门** |
| **R3** | 两个束的索引表 (`FE_IDX`/`DP_IDX`) 抄错 | 某些字读回**别人**的值（静默、lint 看不见） | 全链门逐字读回 32 路必然抓到 | 索引表由单一 `localparam` 派生 + 门逐字验 | **全链门** |
| **R4** | `snap_base` 类"窄左端静默截断"再现 | 高地址字回绕读低地址字 | 门逐字读回（判据 15b 同款） | NW=32 时 10 位恰好够；注释写死上限 | **单元门 + 全链门** |
| **R5** | HLS 内部时间常数 ×0.8 未被记录 | 将来有人拿 100ms/5s 对账 ⇒ 误判为缺陷 | 无（是文档缺口） | §5.3 全表入档 + P6E_OBS 寄存器表加一行 | **文档复核** |
| **R6** | `DIFF_POD12_DCI` 能不能驱动 MMCM 输入未实测 | DRC / 综合报错，或时钟质量差 | 构建日志的 DRC | 沿用厂商已验证值；退路：改用 `LVDS` + 检查 bank65 VCCO，或改走 `IBUFDS_GTE4`+`BUFG_GT`（Y2 的 156.25MHz 参考钟经 HROW） | **构建 DRC** |
| **R7** | MMCM 在 xsim 里锁定慢 ⇒ 全链门超时 | 门假 TIMEOUT | 门日志里 `locked` 一直 0 | 门里显式等 `u_dut.mmcm_locked`（并加超时上限）；必要时加 `ifdef P6B_SIM_CLKGEN` 旁路（**端口表不许变**） | **全链门** |
| **R8** | 复位不同代 ⇒ FIFO 指针静默错位（§4.4） | 数据腐败（不是丢帧）：图案**整段偏移** | `W13` 涨 + `W0/W30` 差**持续漂移** | FIFO 复位只跟 `reset_n`（§4.4 硬规则）+ 单元门加"单侧复位"负对照 | **单元门** |
| **R9** | `req_fe/req_dp` 宽过 1 拍 ⇒ 反复受理（`snap_cdc.v:20-26` 硬契约①） | 快照连发，`gen` 一次跳多；`busy` 抖动 | `gen` 增量 ≠ 1（既有判据已在查，`p6e_slowpath_probe.sh:38-46`） | 序列器把 req 寄存器化成一拍 | **单元门 + 板级** |
| **R10** | W21 语义变化被误读 | 旧文档说"MAC 帧内中止"变成"持续断供" | 无 | §3.4 的警告 + P6E_OBS 注明 | **文档复核** |
| **R11** | 观测通道在 DP 时钟停摆时整窗失明 | 主机读到 `busy=1` 永久 | `SNAP_STATUS[6]`(locked)=0 | 每块板级脚本前置判 `SNAP_STATUS[6]==1` | **板级** |
| **R12** | 改动漫过 P6a 基线（前端被动） | 闸 G 的读数不可比 | `check_p6b_timing.py` 判据 2/3 | `ku5p_p6a_t8p0.xdc` 一字不改 + `u_mac_rx/u_mac_tx` 端口表一字不改 | **diff + 时序报告** |

### 9.2 P6b 验收判据清单

**A. 时序门（唯一的"能不能上板"闸）**
1. `python board/check_p6b_timing.py board/p6b_ku5p_timing.rpt --expect dual` **退出码 0**。
2. 该报告里：setup 失败端点 **0** / hold 失败端点 **0** / `IDDRE1/C|CB` Min-Period 违例 **0**（§8.6）。
3. 构建日志里 **无** `Vivado 12-4739`（`set_clock_groups` 真生效）。
4. 构建日志里 **无** `implicit` 隐式网、`10-3091` 位宽不符（照抄既有门的硬失败规则）。

**B. 单元门（每个新模块至少一门 + 负对照）**

| 门 | 内容 | 必须包含的负对照 |
|---|---|---|
| **`tb_fifo_async`（✅ 已落地，`tb/` + `sim/fifoasync/`）** | 7 个 case（BAL/WRFAST/RDFAST/BOUND/RESET/CLKSTOP/LAT）+ 10 条判据（金标准队列对拍 / 无丢无重无重排 / 100:1 极端时钟比 / 随机使能 / 满空捶打 / **灰码单调性监视** / **复位矩阵** / **时钟停摆** / **二级同步的结构契约延迟 dt>3T** / 4 个参数化实例） | 见 `tb/tb_fifo_async.v` 头注释（`mut_full_off` / `mut_empty1` 已点名）|
| `tb_clk_gen_p6b`（✅ 已落地，`tb/` + `sim/clkgen/`） | 时钟/复位发生器；`SIM_BYPASS=1` 走行为级模型（不等 MMCM 锁定），频率由参数算出 ⇒ **改错 `MULT_F` 就真的跑错频率** | 见 `tb/tb_clk_gen_p6b.v` |
| **`snap_seq` 单元门（新，待建）** | 链式顺序（FE 先 DP 后）+ req 一拍宽 + busy 期间 req 被忽略 + 两束拼接索引逐位（§7.2 的 32 行对照表） | 把 FE/DP 顺序对调 ⇒ 有向判据 `W6-W0 ∈{0,1}` 必须 FAIL |
| `tb_snap_cdc`（已有，`sim/snapcdc/`） | `NW=24 → 32` 一行改（`tb/tb_snap_cdc.v:31`）；跑两遍（24 与 32）以证明它不依赖具体字数 | 已有的撕裂负对照保留 |
| `tb_axi_regs`（已有，`_proj_pcie/`） | `SNAP_NW=32` + `snap_din[1023:0]` + `w8[0:31]` + 未实现地址 `0xA0` | 把 `snap_base` 改回 `[8:0]` ⇒ 必须 FAIL（既有变异体手法） |
| **全链门 `tb_p6e_pcie_wrapper`（已有，扩到 32 路 + 两束）** | 逐字读回 32 个字（每路 force 成互不相同的常数）+ `BUILD_ID=5` + 触发/done/冻结 | ⭐ **force 必须打生产者节点**（`sim/p6e_pcie/tb_p6e_pcie_wrapper.v:17-30` 的 F1 纪律）。把某一束的拼接项去掉一项（悬空）⇒ 该字必须读回 0/z 而**不是**别人的值 ⇒ 门 FAIL |
| `tb_p6e_pcie_counters`（已有） | W16/W17 的**增量**条件（200 拍 ⇒ +200 等） | 保留既有负向 |
| **`board/p6b_verify/` + `run_controls.py`（✅ 已落地）** | `check_p6b_timing.py` 自身的**正/负对照 + 人工病理样本**：`pos_*`（P6e 8ns 单域、合成双域）、`neg_p6a_t6p4.{auto,dual}`（真负对照 = 闸 G 那 16 条 Min-Period）、`neg_path_*`（setup/hold 假 FAIL、总判句缺失、5ns 病理时钟）、`extra_*`（闸 G 的额外带内周期） | 这是判据②"闸要有区分能力"的落地：**负对照必须判 FAIL，正对照必须判 PASS** |

**C. 板级门**

⭐ **入口已经写好：`_proj_pcie/p6b_accept.sh`（✅ 已落地，含 9 条判据 + 上板手册 + 前置闸纪律）。
下面的表是"它覆盖了什么 + 本文档额外要求什么"，两边一起看。**

| # | 判据 | `p6b_accept.sh` 里对应哪条 | 容差要求 |
|---|---|---|---|
| C0 | 前置闸：`MAGIC = 0x50360001` 且 **`BUILD_ID = 0x00000005`**；不通过**拒绝继续** | 判据 1 | 精确 |
| C0b | 活性：`FREECNT(0x0C)` 两次读数必须变化；`MARKER(0x14)=0xDEADBEEF`。**判活只看 BAR 读得动，不用 `lspci`/config 空间** | 判据 2 | 精确 |
| C1 | **MMCM locked 位 = 1** —— 否则后面全部无意义（读 `W25.bit0` 与 `SNAP_STATUS[6]` 两处，必须一致） | 判据 7 | 精确 |
| C2 | ⭐ **数据面域自由计数器实测 156.25MHz ±1%**：`W24` 两次触发 + 墙钟（**10–20 s** 间隔；32 位 @156.25MHz 每 27.49 s 绕一圈） | 判据 6 | ±1%（实际预期 ±50ppm） |
| C3 | **ping 复现**：`ping -c 5` 5/5，再 `ping -c 20 -i 0.05` 复测 | 判据 3 | 与 P6a 基线同量级（rtt avg ≈ 0.13ms） |
| C4 | **图案仍 931 Mbps 且逐字节**：板子自报 `W9` 反解速率 (≥900 Mbps) + 网卡硬件计数 + 对端 memcmp + `W13 = 0` + `W3 = 0` | 判据 4 | ≥ 900 Mbps；逐字节 0 失配 |
| C5 | **观测通道对账**：`W20` vs `W7`、`ΔW0 ≥ ΔW7`、`W13/W18/W19` 恒 0、`W17 = 0` | 判据 5 | ⚠️ **脚本现在是 `W20 == W7`；本文档要求改成 `0 ≤ W20 - W7 ≤ 1`**（§9.3 的跨束偏斜）—— 施工时必须同步改脚本，否则正常偏斜 1 帧会被报成 FAIL |
| C6 | 前端健康：`W3` = 0；`W4` 涨速与 `W0` 脱钩；**`W26` 不单调涨；`W27 < 256`** | ⚠️ **`p6b_accept.sh` 目前没有** | 需补（否则 R 的"深度不够"只能靠 W4 间接推） |
| C7 | TX 健康：`W21` = 0；**`W28 < 256`**；`W20` 与 `W7`/`W8` 对账 | ⚠️ 同上，需补 | 需补 |
| C8 | 慢路径回归：`W6` 涨而 `W16` 跟着涨（HLS 真在读）；`W17` 不涨（看门狗没在踢，且 ÷80 口径）| 可用 `_proj_pcie/p6e_slowpath_probe.sh`（**要按 §7.7 补 8 个地址 + 改 ÷80 文案**） | — |
| **C10** | ⭐ **新（本文档独有，最有判别力）**：**停流量 → 等 ≥13 µs → 触发快照 ⇒ 必须有 `W0 == W30` 且 `W1 == W31`（逐位精确）** | ⚠️ 无（胶水判据） | 精确等式，见 §7.3-C1 |
| **C11** | ⭐ **新**：在跑流量时 `-1 ≤ W0-W30 ≤ 256×8/64+1`（有向！）且 `(W1-W31)` 有界不漂移 | ⚠️ 无 | 见 §7.3-C2 |

> ⚠️ **`p6b_accept.sh` 的判据 5 与本文档冲突**：它以 `W20 == W7` 为判据。
> 在 P6b 的**双束链式快照**下这两者天然可差 1（§9.3），**必须改成区间判据**，
> 否则第一次正常上板就会被报 FAIL。这是施工时必须先改的一处。
> 同理它若写了"W17 ÷ 64"也要一并改 ÷80。

### 9.3 ⚠️ **哪些旧判据会因这次改动而失效 / 需要调容差**

| 旧判据 | 出处 | 为什么失效 | 新形式 |
|---|---|---|---|
| **`W20 ≡ W7`**（"只有 HLS 是唯一 TX 源时两者才相等"） | `P6E_OBS.md` §二·补 | W20 在 FE、W7 在 DP ⇒ 跨束偏斜 ≤59.2 ns ⇒ 可能差 1 帧 | **`0 ≤ W20 - W7 ≤ 1`**（链式顺序给出方向） |
| **`W6 = W0`**（"每一帧都进了慢路径"） | `P6E_OBS.md` §六 板级首测 | 同上（W0 在 FE、W6 在 DP） | **`0 ≤ W6 - W0 ≤ 1`** |
| **`W16 ÷ 64 ≈ 看门狗复位次数`** | `P6E_OBS.md` §二·补、`wrapper_p4.v:2378` | `rst_cnt` 由 64 拍改 80 拍（§5.1） | **`W16 ÷ 80`** |
| **"W17 ÷64"** | `_proj_pcie/p6e_slowpath_probe.sh:70,111` | 同上 | 脚本文案与算式都要改 ÷80 |
| **`W5` 反解频率 = 125MHz** | `P6E_OBS.md` §八（"627,020,671 / 5s = 125.4 MHz"） | W5 仍是 FE 的 `gmii_free` ⇒ **本条不变** ✓ | 不变；**新增** W24 反解 156.25MHz |
| **`W21` 的语义** | `P6E_OBS.md` §一（"MAC 帧内中止 = 源流断供的 runt"） | DP 可领先 256 字 ⇒ 中止门槛变高 | 判据仍是 `W21=0`，但**故障含义升级为"持续型断供"**（§3.4） |
| **"未实现地址 = 0x84"** | `p6e_snap_check.sh:161` 等 4 处 | 扩窗到 32 字 | **`0xA0`** |
| **"24 字窗口 / BUILD_ID=4"** | 全仓多处 | 扩窗 + 双域 | **32 字 / BUILD_ID=5** |
| **`W14/W15` 不是 MAC 计数**（而是 TCP fast path） | `P6E_OBS.md` §八 | 语义不变 ✓ | 不变 |
| **`hr_cnt`/`W16` 的"消费侧"论证** | `wrapper_p4.v:2367-2376` | 论证仍然成立，只是域从 gmii 变 dp | 不变（但要改注释里的"gmii 域"） |

---

## 附录 A：改动文件清单（施工顺序建议）

**新增文件**
| 文件 | 内容 |
|---|---|
| `rtl/fifo_async.v` | FWFT 双时钟异步 FIFO（格雷码指针 + ASYNC_REG 2FF + 预读式 FWFT 输出级）。参数 `W/D/AW`；端口 `wclk,wrst_n,wr,din,full / rclk,rrst_n,rd,dout,empty` + `dbg_occ/dbg_occ_max` |
| `_proj_pcie/rtl/snap_seq.v` | 链式快照序列器（axi 域），见 §2.5/§7.2 |
| `board/ku5p_p6b_sysclk.xdc` | §8.3 |
| `board/ku5p_p6b_cdc.xdc` | §8.4（**必须 impl-only**） |
| `board/build_p6b_ku5p.tcl` | 复制 `build_p6e_ku5p.tcl`：+`rtl/fifo_async.v` +`snap_seq.v` + 两个新 XDC + `set_property used_in_synthesis false [get_files …p6b_cdc.xdc]`；`set project_name p6b_ku5p_prj`；宏不变 |
| `board/run_build_p6b_ku5p.bat` | 复制 + 改日志名；成功判据仍是"位流文件存在" |
| `board/p6b_verify/`（目录） | 时序报告 + `check_p6b_timing.py --expect dual` 的原始输出（判据 ② 的"入库"要求） |
| 门：`sim/p6b_fifo_async/`、`sim/p6b_snap_seq/` | 见 §9.2-B |

**修改文件（按依赖顺序）**
| # | 文件 | 改什么 |
|---|---|---|
| 1 | `board/wrapper_p4.v` | 新端口 `sys_clk_p/n`（`ifdef DEV_USP` 或无条件？**建议无条件**：K7 板没有 Y1，但默认构建不引用它 —— 需与 K7 构建核对，见 §B）；`IBUFDS+MMCME4_BASE+BUFG`；`dp_clk/dp_rst_n`；**全局 `gmii_clk`→`dp_clk` 替换（§1.3 的"留 FE"清单除外）**；两个 `fifo_async`；拆 2418 的 always 块；`wl_last_lat` 触发改 2FF；`SNAP_NW_P6E=32` + `fe_src`/`dp_src` + `snap_seq` 例化；`BUILD_ID_V=5`；§5.1 的全部常数；文档注释同步 |
| 2 | `rtl/slow_rx_adp.v` | `WDOG`、`rst_cnt`（§5.1） |
| 3 | `rtl/tcp_tx_frame.v` | `RTO_LIM` |
| 4 | `rtl/app_ctrl.v` | `FIN_TO_LIM`、`FIN_GRACE`、注释 |
| 5 | `rtl/app_status_uart.v` | `BIT_LAST`、`GAP_TICKS`（**含加宽**） |
| 6 | `board/uart_dbg.v` | 两个 `BIT_LAST`（`:139`, `:193`）、`GAP_LAST`（`:194`） |
| 7 | `rtl/app_pattern.v` | `act_tmr` |
| 8 | `_proj_pcie/rtl/axi_regs.v` | `SNAP_STATUS` 加 4 位（`[6]` locked、`[5:3]` fe_*）；注释写死 `snap_base` 的 NW≤32 上限 |
| 9 | `_proj_pcie/tb/tb_axi_regs.v`、`tb/tb_snap_cdc.v`、`sim/p6e_pcie/tb_p6e_pcie_wrapper.v`、`sim/p6e_pcie/tb_p6e_pcie_counters.v` | §7.4 的 ⑥ |
| 10 | `_proj_pcie/p6e_*.sh`（6 个） | §7.7 |
| 11 | `P6E_OBS.md` | 寄存器表 32 字 + W24..W31 + `BUILD_ID=5` + 未实现地址 `0xA0` + HLS ×0.8 与 W21 语义变化的注记；`P6B_SPEC.md` 自身 |

**明确不许动的**
- `board/ku5p_p6a_t8p0.xdc`、`board/ku5p_p6e_pcie.xdc`（基线）
- `rtl/mac_rx_64.v` / `rtl/mac_tx_64.v` / `rtl/vlan_strip.v` / `rtl/rx_classify.v` / `rtl/tx_arb.v` / `rtl/fifo_sync.v` / `rtl/frame_fifo.v` / `rtl/snap_cdc.v`
- `hls/`（含 `hls/slowstack_prj/` 生成产物）

---

## 附录 B：**我没能确定的事项**（诚实清单）

| # | 未定事项 | 影响 | 我做了什么 / 建议怎么定 |
|---|---|---|---|
| **B1** | **bank 65 的 VCCO 与 `DIFF_POD12_DCI` 能否驱动 MMCM 输入** —— 只核到引脚是 GC/HP、时钟区有 MMCM；**没有**核到 VCCO 网络与 IBUFDS+MMCM 的实际可布性 | R6。若不行，整个 156.25MHz 方案要换源 | 我做了 `pin_probe.tcl` 的只读器件查询（结果见 §8.2）。**建议**：施工 agent 第一次综合后立刻看 DRC/`report_clock_networks`；退路写在 R6 |
| **B2** | **`sys_clk_p/n` 端口要不要包在 `ifdef` 里** —— K7 板（`DEV_USP` 未定义）没有 Y1。P6a 的"默认构建逐位不变"契约要求新增端口在默认路径上必须是常量或是 `ifdef` 内的 | 可能破坏 K7 各档的可比性 | 我**没有**去核 K7 板是否有 100MHz 差分可用。**建议**：把新端口放进 `ifdef DEV_USP`（与 `fpga_gclk` 的 `ifndef DEV_USP` 对称），并逐档核对 K7 构建的端口表 |
| **B3** | **`u_rxcdc` 深度 256 是否够用** —— §4.2 已证明"最深停顿无上界" ⇒ 深度只能按弹性目标取 | 不够时表现是 W4/W26/W27 上涨（可归因，可事后加深） | 我给了完整的症状判据。**建议**：第一次板级测试就把 W27（occ_max）读出来当数据，再决定要不要加深 |
| **B4** | **闸 G 的 t6p4 档里 HLS 的实测 WNS 是多少** —— 我只核到"整设计 0 失败端点"，**没有**下钻到 `u_hls` 层次的 WNS | 若 HLS 层次恰好是 +0.001，P6b 没有额外负担；若本来是 +0.4，还有余量 | 可复跑：`open_run impl_1; report_timing -from [get_cells u_hls*]`。**建议**：施工 agent 在 P6b 的 impl 后跑一次 `report_timing_summary -hier` 看 HLS 层次 |
| **B5** | **`u_eco_pipe`/`u_slow_tx`/`u_app_udp` 之外，是否还有我没扫到的 `gmii_clk` 语义依赖** —— 我是按"`gmii_clk` 字面出现的行"枚举的，**没有**逐模块读全部 34 个 `rtl/*.v` 的时钟语义 | 漏一个 = 某模块在错误的域里 | 我用 `grep -n "gmii_clk"` 枚举了 wrapper 的全部出现（§1.3）；rtl/ 下的模块**不含**时钟选择（都是 `input clk`），所以域由 wrapper 决定。**建议**：施工 agent 用 `grep -rn "clk" rtl/*.v | grep -v "input .*clk"` 复核一遍 |
| **B6** | **`board/wrapper_1g.v` / `wrapper_echo.v` / `wrapper_tcp.v` 的 `rx_act_cnt` 等** | 我只改了 P6e/P6b 路径上的文件；这三个 wrapper 不在 P6b 构建里 | 已标注"不在本次范围"。**建议**：不碰（它们不在 `build_p6b_ku5p.tcl` 的文件清单里） |
| **B7** | **`GAP_TICKS` 与 `BLK_HALF` 加宽会不会撞上别处的位宽假设** —— 我核到"2²⁸ < 312.5M"与"2²⁵ < 39.06M"，但**没有**核到消费这两个寄存器的比较表达式是否也吃旧位宽 | 若比较处写了字面量位宽，加宽会被静默截断（铁律 ②） | **建议**：加宽后跑 `xvlog` 的 `10-3091` 检查（既有门已把它当硬失败），并在门里对这两个计数器做一次"计到 2 倍原值"的用例 |
| **B8** | **链式触发的 59.2 ns 偏斜上界**是基于"每级 3 拍"的最坏估计（`snap_cdc` 的两级同步器各 2 拍 + 1 拍逻辑），**没有**实测 | `∈{0,1}` 判据的成立性 | 可实测：`sim/snapcdc/` 的既有门能测往返延迟。**建议**：在 `tb_snap_cdc` 里加一条"往返拍数 ≤ 3+3"的断言 |
| **B9** | **`SNAP_STATUS[3:5]` 新位会不会被既有脚本误读** | 我核了 `p6e_*.sh` 的取位方式（都是 `s&0x7` 与 `(s>>16)&0xffff`）⇒ 不受影响 | 若还有别的消费者（我没全仓扫），需要复核。**建议**：`grep -rn "0x1c\|SNAP_STATUS" _proj_pcie/ tools/` 复核 |

---

*本文档由 P6b 调查/规格 agent 产出（2026-09-29）。所有 file:line 与原始读数均按"可独立复核"要求给出；
标「未定」的 9 条在附录 B 内逐条列出，不做推测性结论。*
