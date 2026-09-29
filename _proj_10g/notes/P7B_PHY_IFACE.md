# P7b PHY 侧接口冻结文档（`gt_10gbr` fabric 接口）

- 日期：2026-09-29
- 性质：**只读侦察**产物。未烧板、未碰硬件、未跑 Vivado 综合、未做任何 git 写操作、未修改本文件以外的任何文件。
- 侦察对象：`_proj_10g/` 下的 P7a 工程（`gtwizard_ultrascale:1.7`，模块名 `gt_10gbr`）。
- 姊妹文档：`_proj_10g/notes/P7B_DATAPATH_CONTRACT.md`（讲**下游 MAC/数据面**合同）。
  **本文只讲 PHY 侧**：GT 的 fabric 接口、64b/66b 成帧边界、时钟/复位、以及"官方怎么做成帧"的检索结果。
- 与 `P7A_SPEC.md` §9「我没确证的」的关系：本文**逐条更新**了那份清单里的第 2、4、6、12 项（见 §10.0）。

## 证据强度标记（全文使用）

| 标记 | 含义 |
|---|---|
| 【RTL】 | 读本机**生成的 RTL / 属性文件 / 报告**，给出 `文件:行号`，可逐行复核 |
| 【板级】 | P7a 上板读数的**原始文本**（`board_scratch/logs/`） |
| 【工具】 | Vivado 工具自己的输出（`.xci` 参数、综合/实现回读报告） |
| 【网文】 | WebSearch/WebFetch 摘要。⚠️ **`docs.amd.com` 被本机网络策略直接拒绝**（WebFetch 报 "Unable to verify if domain … is safe to fetch"），**UG578 原文未核**；这些条目一律标【网文·未核原文】 |
| 【推断】 | 逻辑推理，无直接证据 |
| 【未核实】 | 就是不知道 |

---

## 0. 一页结论（先读这个）

| 问题 | 结论 | 证据 |
|---|---|---|
| GT 的 fabric 接口是什么形态？ | **每通道 `64 bit 数据 + 2 bit 有效同步头`，一拍一个 64b/66b 块**；不是字节+控制位 | §1、§2 |
| GT 自己做 64b/66b 编码吗？ | **只做"加/剥 2 bit 同步头 + 64↔66 速率适配（gearbox）"**。**块类型（XGMII 控制字符那一层）在 64 位数据里，由 fabric 自己编** | §2.2（**决定性证据**：官方 PCS-only 核的 GT 配置与本设计逐字相同，而它的 fabric 面是 XGMII） |
| 6 位 header 怎么用？ | 本配置（8 字节接口 / 64B66B_ASYNC / 非 CAUI）**只用 `txheader[1:0]`；数据块 = `6'b000001`，高 4 位必须是 0** | §2.3 |
| `txsequence` 呢？ | **本配置下全 0**。P7a 板级 6 Tbit 零错就是在 `txsequence=7'd0` 下跑出来的 | §2.4 |
| `rxdatavalid[1:0]` 是什么？ | 2 bit/通道；本配置下**锁住后恒为 `2'b11`**（板级实测） | §1、§3.4 |
| 何时能往 TX 推数据？ | `gtwiz_userclk_tx_active_out=1` 之后即可安全推；`gtwiz_reset_tx_done_out=1` 是"链路已就绪"的语义 | §4 |
| TX/RX 时钟同源吗？ | **不一定**。两个独立 BUFG_GT 网络（TXOUTCLK / RXOUTCLK），Vivado 未声明关系；P7a 自环回实测有 **≈5 ppm** 偏差（机理未查） | §5 |
| PRBS 现在什么状态？ | **GT 内部 PRBS 关闭**（`TXPRBSSEL=RXPRBSSEL=4'b0000`），PRBS 在 **fabric 侧**（XAPP884 `prbs_any`）。换成真实以太网**不需要改 GT** | §6 |
| 有官方成帧参考实现可读吗？ | **`xxv_ethernet` 的 `_vl_rfs.sv` 是加密的（`pragma protect`），零明文 RTL**。但它**明文的分支**（`.veo` 端口表 + 子核 `.xci` + channel wrapper）已经把答案给全了 | §7 |
| UG578 本地有吗？ | **本地没有**（全盘 `find` 无果）。替代证据见 §8 | §8 |

---

## 1. 接口表

范围 = 本设计顶层 `p7a_top.v` 里 **GT IP `gt_10gbr` 的实例 `u_gt`** 的端口（`p7a_top.v:165-206`）。
位宽一律按"**总位宽 = 每通道位宽 × 通道数(2)**"给出。

### 1.1 TX 侧（fabric → GT）

| 信号 | 位宽 | 方向 | 时钟域 | 语义 | 证据 |
|---|---|---|---|---|---|
| `gtwiz_userdata_tx_in` | 128（=2ch×**64**；`[63:0]`=ch0、`[127:64]`=ch1） | in | **TXUSRCLK2**（`gtwiz_userclk_tx_usrclk2_out`，156.25 MHz） | 每通道每拍 **1 个 64b/66b 块的 64 位净荷**。无握手、无 valid、无 ready：**推一拍 = 出一个块**（永不停顿） | `gt_10gbr_stub.v:32,52`【RTL】；分片见 `p7a_top.v:211-212`【RTL】 |
| `txheader_in` | 12（=2ch×**6**） | in | TXUSRCLK2 | 每通道每拍 6 位的**块头字段**。本配置**只用 `[1:0]`**（= 该块的 2 bit 64b/66b 同步头），其余位必须为 0 | §2.3；`gt_10gbr_stub.v:32,60`【RTL】；`gt_10gbr_gtwizard_gtye4.v:1885`（**逐位直通，无任何重排**）【RTL】 |
| `txsequence_in` | 14（=2ch×**7**） | in | TXUSRCLK2 | 同步 gearbox 的序列计数器。**异步 gearbox 不用**，example 恒 0，P7a 板级有效 | §2.4；`gt_10gbr_stub.v:32,61`；`gt_10gbr_example_stimulus_64b66b_async.v:111-112`【RTL】 |
| `gtwiz_userclk_tx_reset_in` | 1 | in | 异步 | 复位 TX 用户时钟环（BUFG_GT）。p7a 的置位条件 = `~(&txprgdivresetdone & &txpmaresetdone)` | `p7a_top.v:162`【RTL】 |
| `gtwiz_userclk_tx_usrclk2_out` | 1 | out | — | **TX payload 时钟 156.25 MHz** | `p7a_top.v:169,234`；`C_TX_USRCLK2_FREQUENCY=156.2500000`【工具】 |
| `gtwiz_userclk_tx_srcclk_out` | 1 | out | — | BUFG_GT 的**输入**源时钟（= `TXOUTCLK`），未过 BUFG | 时钟报告 `:83,66`【工具】 |
| `gtwiz_userclk_tx_active_out` | 1 | out | TXUSRCLK2 | BUFG_GT 已锁定且复位已释放 ⇒ **fabric 侧可以开始推数据** | §4 |

### 1.2 RX 侧（GT → fabric）

| 信号 | 位宽 | 方向 | 时钟域 | 语义 | 证据 |
|---|---|---|---|---|---|
| `gtwiz_userdata_rx_out` | 128（=2ch×**64**；`[63:0]`=ch0、`[127:64]`=ch1） | out | **RXUSRCLK2** | 每通道每拍 1 个 64b/66b 块的 64 位净荷。**同步头已被剥掉** | `gt_10gbr_stub.v:32,53`；分片 `p7a_top.v:213-214`；helper 映射**低半字直通、不反转**：`gtwizard_ultrascale_v1_7_gtwiz_userdata_rx.v:81-83`【RTL】 |
| `rxheader_out` | 12（=2ch×**6**） | out | RXUSRCLK2 | 每通道 6 位块头。本配置 `[1:0]` = 收到的 2 bit 同步头；`rxheader[5:2]` 在本配置下**未定义/应为 0**【推断，见 §10】 | `gt_10gbr_stub.v:32,66`；`p7a_top.v:219-220`【RTL】 |
| `rxheadervalid_out` | 4（=2ch×**2**） | out | RXUSRCLK2 | `[0]` = 当前 `rxheader[2:0]` 有效（普通模式）；`[1]` = 第二组头（16 字节接口 / CAUI datastream B） | 【网文·未核原文】UG578 Table 4-47（异步 gearbox）；`gt_10gbr_stub.v:32,67` |
| `rxdatavalid_out` | 4（=2ch×**2**） | out | RXUSRCLK2 | `[0]` = **普通模式 / 8 字节接口**下 `rxdata` 有效；`[1]` = 16 字节接口的 `rxdata[127:64]` | 【网文·未核原文】UG578 Table 4-44/4-47；`gt_10gbr_stub.v:32,65` |
| `rxgearboxslip_in` | 2（=2ch×1） | in | **RXUSRCLK2** | 每通道 1 根：**脉冲一下 = 把 RX gearbox 滑到下一个可能的块对齐** | §3.2；`gt_10gbr_stub.v:32,59` |
| `rxstartofseq_out` | 4（=2ch×**2**） | out | RXUSRCLK2 | gearbox 内部序列计数器 = 0 的指示（"当前 RXDATA 是序列起点"）。**本设计未使用**（P7a 顶层把这 4 根线接了但没连任何逻辑） | 原语端口 `GTYE4_CHANNEL.v:601`【RTL】；wrapper `:373`；`gt_10gbr_stub.v:32,70`【RTL】 |
| `gtwiz_userclk_rx_reset_in` | 1 | in | 异步 | 同上，RX 侧。p7a 条件 = `~(&rxprgdivresetdone & &rxpmaresetdone)` | `p7a_top.v:163` |
| `gtwiz_userclk_rx_usrclk2_out` | 1 | out | — | **RX payload 时钟 156.25 MHz**（标称；见 §5） | `p7a_top.v:174,235` |
| `gtwiz_userclk_rx_active_out` | 1 | out | RXUSRCLK2 | RX 用户时钟可用 | §4 |

### 1.3 复位 / 状态 / 时钟

| 信号 | 位宽 | 方向 | 语义 | 证据 |
|---|---|---|---|---|
| `gtwiz_reset_clk_freerun_in` | 1 | in | 复位状态机的自由振荡参考钟。**p7a 用 `clk_obs` = 156.25 MHz** | `p7a_top.v:176`；`C_FREERUN_FREQUENCY=156.25`【工具】 |
| `gtwiz_reset_all_in` | 1 | in | 全复位请求（IP 内部同步）。**IP 的复位控制器在自己肚子里**（`LOCATE_RESET_CONTROLLER=CORE`），上电后自动跑一遍 | `p7a_top.v:177,307`；`p7a_ip_config.txt:20`【工具】 |
| `gtwiz_reset_tx_pll_and_datapath_in` / `_tx_datapath_in` / `_rx_pll_and_datapath_in` / `_rx_datapath_in` | 各 1 | in | 分项复位；**p7a 全接 0，不用** | `p7a_top.v:178-181` |
| `gtwiz_reset_tx_done_out` / `gtwiz_reset_rx_done_out` | 各 1 | out | TX/RX 复位序列完成。**PLL 失锁会让 `tx_done` 自动掉回去** | §4；`gtwiz_reset.v:411-425`【RTL】 |
| `gtwiz_reset_rx_cdr_stable_out` | 1 | out | = `rxcdrlock` 同步后的版本（RX CDR 已锁） | `gtwiz_reset.v:754`【RTL】 |
| `gtpowergood_out` | 2（=2ch×1） | out | 该通道上电良好 | `gt_10gbr_stub.v:32,62` |
| `txpmaresetdone_out` / `rxpmaresetdone_out` / `txprgdivresetdone_out` / `rxprgdivresetdone_out` | 各 2 | out | PMA / PROGDIV 复位完成。p7a 用它们生成用户时钟复位条件 | `p7a_top.v:162-163` |
| `gtrefclk00_in` | 1 | in | quad 225 参考钟（Y2 156.25 MHz 经 `IBUFDS_GTE4`） | `p7a_top.v:100-112,187` |
| `qpll0outclk_out` / `qpll0outrefclk_out` | 各 1 | out | QPLL0 输出；**p7a 悬空**（用户时钟走 PROGDIV，见 §5） | `p7a_top.v:188-189` |
| `gtyrxn_in`/`gtyrxp_in`/`gtytxn_out`/`gtytxp_out` | 各 2 | — | 串行侧 | `p7a_top.v:151-158` |

### 1.4 **本配置里不存在**的经典 PCS 信号（重要，别去找）

| 想找的信号 | 状态 | 证据 |
|---|---|---|
| `rxnotintable` / `rxdisperr` | **IP 端口列表里没有**（8b10b 时代的；本配置 `rx8b10ben_in=0`） | `gt_10gbr_stub.v:19-31` 全端口清单【RTL】；`gt_10gbr.v:467` |
| `rxprbserr` / `rxprbslocked` | **原语有、但被留空**：`gt_10gbr.v:740-741` 是 `.rxprbserr_out(), .rxprbslocked_out()` | `gt_10gbr.v:740-741`【RTL】 |
| `rxbyteisaligned` / `rxchanisaligned` / `rxphaligndone` | `INTERNAL_PORT_ENABLED_*_OUT = 0` ⇒ 本配置未生成 | `gt_10gbr.xci:655-661,691-692`【工具】 |
| `gtwiz_buffbypass_tx/rx_*` | `C_TX/RX_BUFFBYPASS_MODE=0` 且 stub 无此端口 ⇒ **不存在**（所以 `example_init` 里说的"与 buffbypass_done 相与"在本设计不适用） | `gt_10gbr_stub.v:19-31`；`gt_10gbr.xci:753,802`；`gt_10gbr_example_init.v:96-99` 注释【RTL】 |
| GT 内部 PRBS 的 SEL/ERR 端口 | `INTERNAL_PORT_ENABLED_{TX,RX}PRBSSEL_IN=0`、`RXPRBSERR/LOCKED_OUT=0` ⇒ 未生成 | `gt_10gbr.xci:526-527,603-604,694-695`【工具】 |

---

## 2. ⭐【最重要】fabric 接口 ↔ XGMII 的关系（含对上级假说的核实结论）

### 2.1 结论一句话

**GT 给我们的不是 XGMII**。XGMII 是"8 个字节 + 8 个控制位"；`gt_10gbr` 给的是
**"8 个净荷字节（64 bit）+ 2 bit 同步头"**，而**同步头就是 XGMII 那 8 个控制位压缩后的结果**：
`c[7:0]==0` ⇒ 数据块（头 = `01`）；`c[7:0]!=0` ⇒ 控制块（头 = `10`），
**控制块的"哪几个字节是控制、分别是什么控制码"必须由 fabric 自己编码进那 64 位数据里**。

⇒ **P7b 要自己写的是"XGMII（或等价语义）↔ 64b/66b 块"这一层，即 802.3 Cl.49 的 PCS 编码/解码**，
不是"往 GT 里灌字节"。

### 2.2 决定性证据：官方 PCS-only 核的 GT 配置与本设计**逐字相同**

`_proj_10g/lic_deny_ctrl_prj/` 里那个被 license 锁住的 `xxv_ethernet` PCS-only 变体 **`w2_pcs64_baser`**
（10GBASE-R PCS/PMA，见 `P7A_SPEC.md` §1.2），内部**嵌了一个 gtwizard 子核**：
`.../w2_pcs64_baser/ip_0/w2_pcs64_baser_gt.xci`。

**它的 GT 配置与我们的 `gt_10gbr` 逐项相同**（【工具】两侧 `.xci` 对照）：

| 配置项 | 我们的 `gt_10gbr` | 官方 `w2_pcs64_baser_gt` |
|---|---|---|
| `TX_DATA_ENCODING` / `RX_DATA_DECODING` | `64B66B_ASYNC` | `64B66B_ASYNC` |
| `TX/RX_INT_DATA_WIDTH` / `TX/RX_USER_DATA_WIDTH` | `64` / `64` | `64` / `64` |
| `TX/RX_LINE_RATE` | `10.3125` | `10.3125` |
| `TX/RX_REFCLK_FREQUENCY` | `156.25` | `156.25` |
| `TX/RX_PLL_TYPE` | `QPLL0` | `QPLL0` |
| `TX/RX_BUFFER_MODE` | `1` | `1` |
| `LOCATE_RESET_CONTROLLER` | `CORE` | `CORE` |
| `RX_OUTCLK_SOURCE` / `TX_OUTCLK_SOURCE` | `RXPROGDIVCLK` / `TXPROGDIVCLK` | 同 |
| **布局后原语属性** `GEARBOX_MODE` | `5'b10001` | `5'b10001` |
| `TX/RXGEARBOX_EN` | `TRUE`/`TRUE` | `TRUE`/`TRUE` |
| `RXBUF_EN` / `TXBUF_EN` | `"FALSE"` / `"FALSE"` | `"FALSE"` / `"FALSE"` |
| `RX_XCLK_SEL` | `"RXDES"` | `"RXDES"` |
| `RXOUTCLKSEL_VAL` / `TXOUTCLKSEL_VAL` | `3'b101` / `3'b101` | `3'b101` / `3'b101` |
| `RX/TX_DATA_WIDTH` | `64` / `64` | `64` / `64` |

证据行：本设计 `gt_10gbr.xci:35,45,37,47,36,46`、`p7a_readback.txt:5-20`、`gt_10gbr_gtye4_channel_wrapper.v:567,680,904,948,1033,1080,1109,1160,1184,1279`；
官方 `w2_pcs64_baser_gt.xci:32-53`、`w2_pcs64_baser_gt_gtye4_channel_wrapper.v:567,680,904,948,1033,1080,1109,1160,1184,1279`。

**而这个官方核的 fabric 接口是 XGMII**（明文端口表 `w2_pcs64_baser.veo`）：

```
  .tx_mii_d_0(tx_mii_d_0),   // input  wire [63 : 0] tx_mii_d_0     <-- veo:98
  .tx_mii_c_0(tx_mii_c_0),   // input  wire [ 7 : 0] tx_mii_c_0     <-- veo:99
  .rx_mii_d_0(rx_mii_d_0),   // output wire [63 : 0] rx_mii_d_0     <-- veo:78
  .rx_mii_c_0(rx_mii_c_0),   // output wire [ 7 : 0] rx_mii_c_0     <-- veo:79
  .stat_rx_block_lock_0(stat_rx_block_lock_0),   // veo:87
  .stat_rx_framing_err_0(...), .stat_rx_hi_ber_0(...), ...       // veo:84,90
```

**推理链（这一步是本次侦察最硬的结论）**：
同一个 GT 配置（`64B66B_ASYNC` + async gearbox + 64/64）在官方核里接的是 **XGMII（字节+控制位）**，
而这个 GT 配置**没有**任何"XGMII 解析"端口可用 ⇒ 那份 XGMII↔64b/66b 的翻译**必然发生在 GT 之外的逻辑里**
（就是那个加密的 `xxv_ethernet_v5_0_vl_rfs.sv`）。
⇒ **我们手里的 GT 只提供"64 bit 净荷 + 2 bit 头"，块类型编码必须自己写。**

补充证据（同一份 `.veo`）：官方核另有一整套**块级状态**要由 soft logic 产生/消费 ——
`stat_rx_block_lock_0`（块锁定）、`stat_rx_framing_err_0`(+`_valid`)、`stat_rx_valid_ctrl_code_0`、
`stat_rx_hi_ber_0`、`stat_rx_bad_code_0`(+`_valid`)、`stat_rx_error_0[7:0]`(+`_valid`)、
`stat_rx_local_fault_0`、`stat_rx_status_0`、`stat_rx_fifo_error_0`、`stat_tx_local_fault_0`（`veo:80-97,100-104`）。
**这些在 `gt_10gbr` 上全都没有** ⇒ P7b 若需要它们（尤其 `block_lock` / `hi_ber` / `local_fault`），
**要自己在 fabric 里做**。这是 P7b 工作量里最容易漏掉的一块。

另外，官方核的 GT 子核里 **`rxgearboxslip_in` 的 `INTERNAL_PORT_ENABLED = 1`**（`w2_pcs64_baser_gt.xci:491`），
而 `txheader_in` / `txsequence_in` / `rxheader_out` / `rxheadervalid_out` / `rxdatavalid_out` 也**全部 = 1**（`:570,613,675,678,679`）
⇒ 官方 soft PCS **自己驱动 txheader/txsequence、自己读 rxheader/rxheadervalid/rxdatavalid**，
与我们 `gt_10gbr` 暴露的端口集完全一致。**P7b 要做的事，就是补上那个被加密的 soft PCS。**

### 2.3 6 位 header 到底怎么映射（对上级假说的核实）

**核实结果：上级假说成立 —— `txheader[5:0]` 在本配置下只有低 2 位有意义，高 4 位必须为 0。**

| 项 | 结论 | 证据 |
|---|---|---|
| 语义 | `[1:0]` = 该块的 **2 bit 64b/66b 同步头**；`[4:3]` 留给 16 字节接口的第二块 / CAUI datastream B；`[5]` 在 CAUI+64B66B 必须为 0；**未用位必须接 0** | 【网文·未核原文】UG578 TX gearbox 章 / TXHEADER 端口表；【网文·未核原文】UG576 摘录 "H1 corresponds to TxB&lt;0&gt;, H0 to TxB&lt;1&gt;" |
| 本设计实测取值 | example 恒 `6'b000001`，注释原文 "tie txheader to the **'data'** type" | `gt_10gbr_example_stimulus_64b66b_async.v:105-106`【RTL】 |
| 板级回路验证 | 自环回收到 `rxheader = 0x01`（= `6'b000001`）**逐位不变**、60 万次采样零偏离 | `p7a_board_stdout.txt:343-347`【板级】；`P7A_RESULT.md:228` |
| 与外部独立实现一致 ⭐ | 开源 `verilog-ethernet` 的 `eth_phy_10g` 也用 **2 位** `serdes_tx_hdr`（`HDR_WIDTH` 硬校验 == 2，`rtl/eth_phy_10g.v:38`）；它内部 `SYNC_DATA=2'b10` 经 **`BIT_REVERSE(1)`** 反转后送到 GTY 的正是 **`2'b01`** —— 与本 example 的 `6'b000001` **逐位相同** | 【同级侦察转述】`_proj_10g/notes/P7B_LIB_SURVEY.md:22-28,265-266,300-310`；**本文未独立复核该库源码** |
| 高 4 位怎么办 | 该库的 `txheader` 端口**只有 2 位**（`[HDR_WIDTH-1:0]`），上 4 位**根本没有驱动** ⇒ 综合成常数 0 —— 与"高 4 位必须为 0"的要求天然吻合 | 同上（`P7B_LIB_SURVEY.md:265`） |
| ⭐ **位序（U3 的最强线索）** | `BIT_REVERSE` **同时**作用于 **64 位 data 与 2 位 hdr**（整字逐位镜像）。该库的板级 wrapper（VCU108 / **KU5P**）都写死 `BIT_REVERSE(1)`，注释说"**Xilinx GTY 的 header/data 位序是反的**" ⇒ **GTY 的 fabric 字是 MSb-first（`txdata[63]` 先出线）**；若 framer 内部按 XGMII 习惯（字 0 位先出）组织，**必须整字镜像** | 【同级侦察转述】`P7B_LIB_SURVEY.md:26-28,272,304-310`；与 example 注释 "gearbox modes transmit data **MSb first**"（`gt_10gbr_example_stimulus_64b66b_async.v:88-89`【RTL】）**方向一致** |
| **为什么 example 的位反转在自环回里看不出来** | TX 反转 + RX 反转（`..._checking_...v:89-99`）在自环回里**互相抵消** ⇒ **自环回对绝对位序零判别力**。这正是 U3 必须靠外部设备（E2）才能定的原因 | 【推断，但由两段对称代码直接支撑】 |
| **不会**用的 6 位形式 | 官方 PCS 的 GT 子核虽然 `INTERNAL_PORT_ENABLED_TXHEADER_IN=1`（端口存在），但其 soft PCS 内部怎么用**读不到**（加密） | `w2_pcs64_baser_gt.xci:570`【工具】 |

**⇒ 给 P7b 的可操作常数**：
- **数据块：`txheader = 6'b000001`**（板级已验证）
- **控制块：`txheader = 6'b000010`** —— 【推断】因为（a）合法同步头只有 `01`/`10` 两个，
  （b）example 已把 `01` 认领为 data，所以 control 只能取另一个值。
  ⚠️ **这一条没有板级证据**（唯一能证伪的方式见 §10 实验 E1）。
- `txheader[5:2] = 4'b0000` 恒成立。

⚠️ **"低 2 位 = 同步头"是【网文·未核原文】+【推断】的合成结论，不是本机可核的产物。**
本机能确证的只有三件：（i）example 送 `6'b000001` 且注释说这是 data；
（ii）`txheader` 在 wizard 里**逐位直通**到原语（`gt_10gbr_gtwizard_gtye4.v:1885`）；
（iii）原语端口 `GTYE4_CHANNEL_TXHEADER` 就是 6 bit（`GTYE4_CHANNEL.v:807`）。
**没有任何本地文件写着"bit0 = TxB&lt;1&gt;"。** 请按 §10 的 E1 做一次板级证伪。

### 2.4 `txsequence`（7 位）—— 计数范围与相位

| 项 | 结论 | 证据 |
|---|---|---|
| 本配置要不要用 | **不用**。example 注释原文："txsequence is not used for 64B/66B **async gearbox** data transmission when a wide user data width is used"，恒接 `7'd0` | `gt_10gbr_example_stimulus_64b66b_async.v:111-112`【RTL】 |
| 板级验证 | P7a 双向各 600 s / 6.003 Tbit **零错**，全程 `txsequence=0` | `P7A_RESULT.md:206-213`【板级】 |
| 7 位计数的**存在意义** | 给**同步** gearbox 用：64B/66B 时计数器 0→32 循环、`TXSEQUENCE[6]` 必须为 0；当 `TX_DATA_WIDTH == TX_INT_DATAWIDTH` 时**每两个 TXUSRCLK2 才 +1**；数据在计数 32（8字节/4字节）处停顿 | 【网文·未核原文】UG578 "Frequency of TXSEQUENCE / TXSEQUENCE PAUSE" 表 |
| 异步 gearbox 的差异 | 异步 gearbox 只定义 `TXSEQUENCE[0]` 一个用途（"header 何时出现"），**8 字节或 16 字节接口时 `TXSEQUENCE[0]` 接 `1'b0`** | 【网文·未核原文】UG578 异步 gearbox 章 |
| ⚠️ 冲突提示 | 官方 PCS 的 GT 子核把 `txsequence_in` **端口使能了**（`w2_pcs64_baser_gt.xci:613`），说明官方 soft PCS 可能**不是**恒 0。**未核实官方驱动了什么值。** 但我们的用法已被 P7a 板级背书 | 【工具】+【未核实】 |

**相位/计数范围（本配置）：无相位要求，恒 0。** 如果将来改用同步 gearbox（本设计没有），才需要 0→32 计数器。

### 2.5 33:32 这个比值 —— 上级推测**成立**，但要理解对位置

- 恒等式：`161.1328125 MHz × 32 = 156.25 MHz × 33 = 5156.25 MHz`，
  而 `10.3125 GBd / 64 = 161.1328125 MHz`（**raw / 无 gearbox 的 64 位接口频率**）。
- 含义：**gearbox 前的 64 位通路**跑 161.1328125 MHz（`10.3125 Gbaud / 64`），
  **gearbox 后的 64 位通路**跑 156.25 MHz；33 个"前"字 = 2112 bit = 32 个 66 bit 块 = 32 个"后"字。
  差的 64 bit = 32 块 × 2 bit 同步头。**33:32 说的正是这个**。
- **fabric 侧（我们接的那一侧）跑的是 `156.25 MHz`，不是 `161.1328125 MHz`**；后者只在 GT 内部。
- 本地证据：`C_TX_USRCLK2_FREQUENCY = 156.2500000`（【工具】`gt_10gbr_stub.v:17` 的 CORE_GENERATION_INFO）；
  实现时钟报告 `6.400 ns / 156.250 MHz`（【工具】`p7a_top_timing_summary_routed.rpt:166-167`）；
  P7a 板级比率 `0.999995 ≈ 1.000000`（gearbox 在通路里；raw 会读 `1.031250`）（【板级】`P7A_RESULT.md:212,216`）。

---

## 3. RX 重组与对齐

### 3.1 怎么把 `rxdata/rxdatavalid/rxheader/rxheadervalid` 拼成连续字节流

**本配置下（8 字节接口 + 异步 gearbox）几乎不需要"拼"**：

- `rxdatavalid[0]` 在异步 gearbox + 8 字节接口下**每个 RXUSRCLK2 拍恒为 1**，
  `rxheadervalid[0]` 同理恒 1 ⇒ **一拍一个字，无空洞、无停顿**。
  - 【网文·未核原文】UG578 Table 4-47：8 字节接口下 `RXHEADERVALID[0]` 每个 RXUSRCLK2 拍恒为 `1'b1`；
    异步 gearbox "allows valid data to be **continuously** received every RXUSRCLK2 cycle"（对比同步 gearbox 需要盯 `RXDATAVALID`）。
  - 【板级】**实测吻合**：P7a 的 `hdrs_cnt == bits_cnt/64` 逐位成立（`93801019148 == 6003265225472/64`）
    ⇒ `rxheadervalid[0]` 有效率 **100%**（`P7A_RESULT.md:113,227`）；
    状态字里 `rxdv(ch0,ch1)=33` ⇒ 两通道的 `rxdatavalid[1:0]` 都恒为 `2'b11`（`p7a_board_stdout.txt:252,293,309,447,584,602`【板级】）。
- 因此 RX 重组 = **逐拍取 `gtwiz_userdata_rx_out` 的对应 64 bit + 对应 `rxheader[1:0]`**，
  按同步头 `01`（数据块）/ `10`（控制块）分流；控制块再按 802.3 Cl.49 的字节 0 类型字段 + `/S/ /T/ /E/ /I/` 码解析。
- ⚠️ **`rxdatavalid[1]` / `rxheadervalid[1]` 的实际含义与取值未被本地/官方材料确证**
  （§10 的"未核实"表）。P7a 把 `[1:0]` 一起采了，读数都是 `1`，所以**两 bit 都恒 1** 是观测事实，
  但**"`[1]` 在本配置下应该是 0"是推断**。建议 P7b 只用 `[0]`，并把 `[1]` 接进调试观察。

### 3.2 ⭐ `rxgearboxslip` 的精确握手协议

| 项 | 内容 | 证据 |
|---|---|---|
| 时钟域 | **RXUSRCLK2**（本设计 = `clk_rx`，156.25 MHz） | 【网文·未核原文】UG578 RX async gearbox 章；本设计实例 `p7a_top.v:312-322`【RTL】 |
| 电平/脉宽 | **高有效，1 个 RXUSRCLK2 拍**就够了；两次 slip 之间**必须至少拉低 1 拍**才能再次生效 | 【网文·未核原文】UG578："Asserting it for one RXUSRCLK2 cycle changes the data alignment" |
| 作用 | 让 gearbox 内容**滑到下一个可能的块对齐**（重新切 66 bit 窗口） | 同上 |
| **成功怎么判** | **GT 不给"已对齐"状态位**。`rxstartofseq_out` 是"序列计数=0"，**不是对齐成功指示**。**判据必须由 fabric 自己造**：块同步状态机（UG578 给的参考状态机：`LOCK_INIT→RESET_CNT→TEST_SH→VALID_SH/INVALID_SH→GOOD_64→SLIP`；`sh_cnt` 上限 64、`sh_invalid_cnt` 上限 16；锁上后允许 64 拍窗口内 ≤15 个坏头） | 【网文·未核原文】UG578 块同步章 |
| **关键时序** | **每次 slip 之后要等 32 个 RXUSRCLK2 拍再去看同步头**（否则会连续猛滑、滑过头） | 【网文·未核原文】UG578（论坛引 UG578 p.304） |
| 官方怎么做 | `w2_pcs64_baser_gt.xci:491` 把 `rxgearboxslip_in` 端口使能（`=1`）⇒ 官方 soft PCS 自己实现块同步 FSM 并驱动它 | 【工具】 |
| example 怎么做（本地可读） | 简单暴力的"重滑直到锁"：`rxgearboxslip_ctr_int` 每拍 +1，`!prbs_match_out` 时**每 256 拍**脉冲一次 `&ctr`（即 `rxgearboxslip_out <= &rxgearboxslip_ctr_int`）；一旦 match 就拉低 | `gt_10gbr_example_checking_64b66b_async.v:109-125`【RTL】 |
| P7a 的用法 | 把 example 的自滑与"VIO 强制单拍脉冲"**或**起来 → `rxgearboxslip_int[0..1]`。脉冲由观测域 toggle 经 2 级同步 + 边沿检测产生（**精确 1 拍**） | `p7a_top.v:310-322`；`p7a_tgl_sync.v`【RTL】 |
| 板级负对照（证明了它是真手段） | 强制滑一下 ⇒ Δerr **16640/16628**、`ref_down_latched 00→11`、随后 6 s 零错重锁、`bits` 推进 6.08e10 | `P7A_RESULT.md:112`【板级】 |

**⇒ 给 P7b 的协议实现（照抄 P7a 已经验证过的形状）**：
1. 用 **1 拍脉冲**驱动 `rxgearboxslip`（不要用长电平）；
2. 滑完**等 ≥32 拍**（保险起见按 64 拍）再去采样同步头；
3. 统计"连续 64 个有效同步头且其中坏头 ≤15"来判 block lock（这是 UG578 参考状态机的判据）；
4. **两个通道各自独立滑动**（P7a 当前是把一个公共脉冲同时给了两个通道 —— 注意这会让两通道同时抖动，
   P7b 若要单通道独立重锁，应改成 per-channel 源）。

### 3.3 block lock / 对齐状态怎么读

**本设计（`gt_10gbr`）没有任何 block-lock 输出。** 可用材料只有三个：

| 材料 | 能不能当 block lock 用 | 证据 |
|---|---|---|
| `rxheader[1:0]` ∈ {`01`,`10`} | ✅ **是唯一可用的判据**（statistical：连续 64 个好头） | §3.2 |
| `rxstartofseq_out[1:0]/ch` | ❌ 不是对齐指示，是"序列计数=0"。原语存在、本设计接了但没用 | `GTYE4_CHANNEL.v:601`；`gt_10gbr_stub.v:32,70` |
| `stat_rx_block_lock`（官方 PCS 有） | ❌ **本设计没有**（要自己造） | `w2_pcs64_baser.veo:87`（对照） |

### 3.4 误码指示

| 想要 | 本设计有没有 | 证据 |
|---|---|---|
| `rxnotintable` / `rxdisperr` | **无**（8b10b 遗留） | §1.4 |
| GT 内部 PRBS 错误指示 | **无**（端口未生成，`rxprbserr_out()` 悬空） | `gt_10gbr.v:740-741` |
| 64b/66b 块级错误（`bad_code`/`framing_err`/`hi_ber`） | **无**（那是官方 soft PCS 的活） | `w2_pcs64_baser.veo:84-96`（对照） |
| **唯一可用的物理层误码量** | **连续坏同步头计数**（同步头 ≠ 01/10）。P7a 的做法：`hdre` 计数 = `rxheader != 首个观测值`；单元门里注入 5 个头错 ⇒ `hdre=5` | `p7a_counters.v:38,151-214`；`P7A_RESULT.md:115`【RTL+板级】 |
| FCS / 帧级误码 | 在 MAC 层（见姊妹文档） | — |

> ⚠️ 注意 P7a 的 `hdre` 判据是"**相对锁定后第一个观测值**"的偏离，**不是**"是否为合法同步头"。
> 因为 example 全程只发数据块（头恒 `01`），这个近似成立；**换成真实以太网（数据块/控制块交替）后
> `hdre` 会立刻爆表，不能直接复用**。P7b 必须换成"头 ∈ {01,10} 才算合法"的判据。

---

## 4. 启动/复位序列

### 4.1 依赖顺序（来自 IP 内部复位控制器的本地 RTL，**不是猜的**）

复位控制器在 IP 内部（`LOCATE_RESET_CONTROLLER=CORE`），上电后**自动跑**，`reset_all` 接 0 也能起来。
两个子状态机（`gtwizard_ultrascale_v1_7_gtwiz_reset.v`【RTL】）：

```
【reset-all FSM】 :134-141
  ST_RESET_ALL_INIT        : 等 gtpowergood            (:164-169)
  ST_RESET_ALL_BRANCH      : TX 使能 ⇒ 先复位 TX PLL    (:173-179)
  ST_RESET_ALL_TX_PLL      : 拉 pll_and_datapath 复位
  ST_RESET_ALL_TX_PLL_WAIT : 等 gtwiz_reset_tx_done    (:190-204)
  (RX) ST_RESET_ALL_RX_PLL/_DP → ST_RESET_ALL_RX_WAIT : 等 gtwiz_reset_rx_done  (:219-227)

【TX FSM】 :331-337
  BRANCH → PLL → DATAPATH
  WAIT_LOCK      : 等 qpll0lock                       (:389-397)
  WAIT_USERRDY   : 等 gtwiz_userclk_tx_active **且** 定时器到  (:401-408)
  WAIT_RESETDONE : 等 txresetdone                     (:411-418)
  IDLE           : 若 PLL 失锁 ⇒ tx_done 自动掉        (:422-425)

【RX FSM】 :589-596
  BRANCH → PLL → DATAPATH → WAIT_LOCK
  WAIT_CDR       : 等 rxcdrlock                       (:666-671)
  WAIT_USERRDY   : 等 gtwiz_userclk_rx_active **且** 定时器到  (:676-683)
  WAIT_RESETDONE : 等 rxresetdone
  IDLE
```

**⇒ 硬依赖链（用一句话记住）**：
`gtpowergood` → `qpll0lock` → **`userclk_tx_active`** → `txresetdone` → **`reset_tx_done`**
（RX 侧把 `qpll0lock` 换成 `rxcdrlock`）。

### 4.2 什么时候可以开始往 TX 推数据？

| 判据 | 结论 | 依据 |
|---|---|---|
| **最低安全线** | `gtwiz_userclk_tx_active_out == 1`。因为端口 `gtwiz_userdata_tx_in` / `txheader_in` 的时钟域就是 `tx_usrclk2`，**用户时钟没起来就没有时钟沿可言**；example 也正是拿这个当复位条件：`example_stimulus_reset_int = gtwiz_reset_all_in \|\| ~gtwiz_userclk_tx_active_in` | `gt_10gbr_example_stimulus_64b66b_async.v:73`【RTL】；`p7a_top.v:232-239` 同样接法 |
| **语义上的"链路就绪"** | `gtwiz_reset_tx_done_out == 1`（它隐含 `userclk_tx_active` 已到）。**保守做法：用 `reset_tx_done` 当"允许发帧"的门** | 同上 FSM |
| 顺序自由 | 时间上 `userclk_tx_active` 一定早于 `reset_tx_done`（FSM 顺序决定），所以**两个门都能用**，只是含义不同 | §4.1 |
| 之前推数据会怎样 | 在 `reset_tx_done` 之前 TX 数据通路仍处于复位态，**推了也不出线**；P7a 的 PRBS 全程在 `tx_active` 之后才跑，没有"提前推"的观测 | 【推断】（无观测） |
| ⚠️ 重复位语义 | **PLL 失锁会让 `tx_done` 自己掉回 0** ⇒ 若 P7b 用 `reset_tx_done` 当发帧门，必须**同时处理"门掉了要停发/重来"**，不能只在上升沿放行一次 | `gtwiz_reset.v:422-425`【RTL】 |

### 4.3 RX 什么时候数据才可信

**要同时满足（按强度递增）**：

1. `gtwiz_userclk_rx_active_out == 1`（时钟可用；P7a 用它当 `clk_rx` 域复位释放条件 `p7a_top.v:315,343`）；
2. `gtwiz_reset_rx_done_out == 1`（复位序列走完；P7a 把它或进 checker 复位：`p7a_top.v:259,269`）；
3. `gtwiz_reset_rx_cdr_stable_out == 1`（CDR 已锁；对应 FSM 的 `WAIT_CDR`）;
4. **fabric 自己跑完块同步（block lock）** —— 这是**GT 不管的一段**（§3.3）。
   P7a 用 PRBS 匹配当近似；P7b 必须换成同步头统计。

### 4.4 一个真实的坑（P7a 踩过、P7b 会再踩）

**`userclk_tx_active` 的正确生成条件不是随手的**。wizard example 的顶层里这几个 hook 线是**故意悬空的**
（`wire [0:0] hb0_gtwiz_userclk_tx_reset_int; assign gtwiz_userclk_tx_reset_int[0:0] = hb0_...;`
—— 右值没有驱动源），意思是"**交给用户填**"：

```
gt_10gbr_example_top.v:120-121   wire [0:0] hb0_gtwiz_userclk_tx_reset_int;
                                 assign gtwiz_userclk_tx_reset_int[0:0] = hb0_gtwiz_userclk_tx_reset_int;
gt_10gbr_example_top.v:145-146   （RX 侧同形）
```

**p7a_top 填的是**（这两行是 P7b 应该直接抄的配方）：

```verilog
assign gtwiz_userclk_tx_reset_int[0] = ~(&txprgdivresetdone_int & &txpmaresetdone_int);  // p7a_top.v:162
assign gtwiz_userclk_rx_reset_int[0] = ~(&rxprgdivresetdone_int & &rxpmaresetdone_int);  // p7a_top.v:163
```

### 4.5 example 的"重试"逻辑（可选，看 P7b 要不要）

`gt_10gbr_example_init.v` 是一个**可选的**看门狗：监控 `tx_init_done_in` / `rx_init_done_in` /
`rx_data_good_in`，超时就重发 `reset_all`，最多 4 次。参数：
`P_TX_TIMER_DURATION_US = 30000`（30 ms）、`P_RX_TIMER_DURATION_US = 130000`（130 ms）
（`gt_10gbr_example_init.v:61-62`【RTL】）。注释里明说 `tx_init_done_in` 应接
"`gtwiz_reset_tx_done_out`，**或**（若 TX buffer bypass）它与 `gtwiz_buffbypass_tx_done_out` 的与"
（`:96-99`）。**本设计没有 buffbypass 控制器**（§1.4）⇒ 只接 `reset_tx_done` 就够。
**P7a 没用这个模块**（`p7a_top.v` 里没有 `example_init` 实例），P7b 可自行决定。

---

## 5. 时钟

| 时钟 | 标称 | 来源 | 自由振荡 / 恢复 | 证据 |
|---|---|---|---|---|
| `gtwiz_userclk_tx_usrclk2_out`（`clk_tx`） | **156.25 MHz**（6.400 ns） | `TXOUTCLK` → BUFG_GT → usrclk2 | **自由振荡**（源自 QPLL0 ← 本板 Y2 156.25 MHz 晶振） | 时钟报告 `src4 = GTYE4_CHANNEL_X0Y4/TXOUTCLK`→`gtwiz_userclk_tx_srcclk_out[0]`（`p7a_top_clock_utilization_routed.rpt:83,66`）；`p7a_top_timing_summary_routed.rpt:167,185`；`C_TX_USRCLK2_FREQUENCY=156.25`【工具】 |
| `gtwiz_userclk_rx_usrclk2_out`（`clk_rx`） | **156.25 MHz**（6.400 ns）标称 | `RXOUTCLK` → BUFG_GT → usrclk2 | **恢复时钟侧**（CDR 从线路恢复；`RX_XCLK_SEL="RXDES"`） | 时钟报告 `src1 = GTYE4_CHANNEL_X0Y4/RXOUTCLK`→`gtwiz_userclk_rx_srcclk_out[0]`（`:80,63`）；`RX_XCLK_SEL="RXDES"`（channel wrapper `:1080`） |
| `gtwiz_reset_clk_freerun_in`（p7a: `clk_obs`） | **156.25 MHz** | 核心板 Y1 100 MHz → MMCM（`clk_gen_p6b`） | 自由振荡（独立于 GT） | `p7a_top.v:82-95,176`；`p7a_top.v:16-23` 头注释 |
| GT 参考钟 | **156.25 MHz** | Y2 → `MGTREFCLK0_225` = V7/V6 → `IBUFDS_GTE4` | 自由振荡 | `p7a_top.v:56-57,100-112` |
| （GT 内部）`TXPROGDIVCLK` / `RXPROGDIVCLK` | 156.25 MHz | `TXOUTCLKSEL=RXOUTCLKSEL=3'b101` + `TXPROGDIV_FREQ_VAL=156.25` | 分别派生自 TX / RX 侧 | `p7a_ip_config.txt:16-17`【工具】；channel wrapper `:948,1184` |

### 5.1 是否同源 / 有无 ppm 偏差 —— **这是 P7b 必须当成"异步"处理的一条**

- **Vivado 把它们当两个独立时钟**：时钟摘要里列出的是
  `gtwiz_userclk_rx_srcclk_out[0]` 与 `gtwiz_userclk_tx_srcclk_out[0]` **两条**（各 6.400 ns），
  时钟交互表里**没有**两者之间的路径（只有各自的 `async_default` 组）
  （`p7a_top_timing_summary_routed.rpt:155-167,179-185,196-212`【工具】）。
  ⇒ 工具**没有**声明任何相位/频率关系，**跨 TX/RX 域必须自己做 CDC**。
- **两者物理上是否同源**：TX 侧来自 QPLL0（本地晶振）；RX 侧来自 CDR 恢复时钟（`RXDES`）。
  在自环回里两者名义上锁在同一晶振上，但**跨的是对端 CDR + 光模块**。
  ⚠️ **未核实**：`RXPROGDIVCLK` 的分频器输入到底是"恢复时钟"还是"RX PLL"，我没能从本地材料确证。
- **P7a 的板级实测**：整窗比率 `0.999995`（= **−5 ppm**），59 个子窗全部同值；
  项目自己的诚实注记：一致性解释是"RX 恢复时钟与本地 156.25 MHz 观测时钟之间的**准同步频差**"，
  但"**5 ppm 是真实频差还是测量效应，本轮没查**"（`P7A_RESULT.md:204,212,234-238`）。
- **10GBASE-R 标准允许每端 ±100 ppm** ⇒ 真实对接第三方设备时，TX/RX 频差**可能到 200 ppm**。
  **⇒ P7b 的合同条款：RX 域与 TX 域一律按异步处理（异步 FIFO / 灰码指针），
  任何"TX 和 RX 同一时钟所以可以直接连"的假设都不成立。**

---

## 6. PRBS 的当前状态 & 换成真实以太网要改什么

### 6.1 事实

| 问题 | 答案 | 证据 |
|---|---|---|
| GT **内部** PRBS 发生器/检查器现在什么值？ | **关闭**：`TXPRBSSEL = 4'b0000`、`RXPRBSSEL = 4'b0000`（每通道），且 `TXPRBSCNTRESET` 未生成 | `gt_10gbr.v:650`（`.txprbssel_in(8'H00)`）、`:573`（`.rxprbssel_in(8'H00)`）；原语侧 tie 值同为 `4'b0000`（channel wrapper `:983,1243`）【RTL】 |
| 它能不能被打开？ | **不能（在现设计里）**：`INTERNAL_PORT_ENABLED_{TX,RX}PRBSSEL_IN = 0`、`TXPRBSFORCEERR_IN=0`、`RXPRBSCNTRESET_IN=0` ⇒ **用户端口没生成**，值在 IP 里硬接 | `gt_10gbr.xci:526-527,603-604`【工具】 |
| PRBS 是 GT 内部做的还是 fabric 做的？ | **fabric 侧做的**。`gt_10gbr_prbs_any.v` = XAPP884 的可参数化 PRBS 核（`gt_10gbr_example_stimulus_64b66b_async.v:122-134` 的 `prbs_any_gen_inst` / `gt_10gbr_example_checking_64b66b_async.v:137-149` 的 `prbs_any_chk_inst`，`NBITS=64`） | 【RTL】 |
| 8b10b 收发器现在什么状态？ | `tx8b10ben_in = 0`、`rx8b10ben_in = 0`、`tx8b10bbypass = 0` ⇒ 全部关闭 | `gt_10gbr.v:467,591-592` |
| GT 的 `rxprbserr` / `rxprbslocked` 能用吗？ | **不能**：`.rxprbserr_out(), .rxprbslocked_out()` 在 IP 顶层就悬空了 | `gt_10gbr.v:740-741`【RTL】 |

### 6.2 换成真实以太网数据要改什么

**GT 侧：什么都不用改。** 因为

1. GT 内部 PRBS 本来就是关的（§6.1）；PRBS 完全是 fabric 的 `prbs_any` 模块；
2. `gtwiz_userdata_tx_in` / `txheader_in` / `txsequence_in` 在 wizard 里**逐位直通**到原语
   （`gt_10gbr_gtwizard_gtye4.v:1885,1923` 与 `:2210,2224`；`assign txdata_int = gtwiz_userdata_tx_userdata_int`，`:3828`）；
3. `gtwiz_userdata_rx_out` / `rxheader_out` / `rxheadervalid_out` / `rxdatavalid_out` 同样是**直通**
   （`gt_10gbr_gtwizard_gtye4.v:1979-1985`）。

**要做的是"替换 fabric 里的两端"**：

```
删掉：  u_stim0/u_stim1 (gt_10gbr_example_stimulus_64b66b_async)   -- p7a_top.v:232-248
        u_chk0 /u_chk1 (gt_10gbr_example_checking_64b66b_async)    -- p7a_top.v:258-276
改成：  TX: <自己的 64b/66b 组帧器> → gtwiz_userdata_tx_in[..] + txheader_in[..]
        RX: gtwiz_userdata_rx_out[..] + rxheader[..] + rxheadervalid[0] → <自己的解帧器>
              并自带块同步 FSM（驱动 rxgearboxslip，§3.2）
（gt_10gbr_prbs_any.v 只在 example 的两个模块里被引用，一起删掉即可）
```

⚠️ **两条不能照抄 example 的地方**：
- example 的 checker **完全不看 `rxheader`**（它的端口里根本没有 rxheader）；P7b 必须看。
- example 的 `hdre`-式误码判据（"偏离首个观测值"）在数据/控制块交替后会失效（§3.4）；
  P7a 的 `p7a_counters.v` 也不能直接复用成 P7b 的链路健康判据。

---

## 7. 官方成帧参考实现的检索结果（对应原问题 7a/7b/7c）

### 7a) `xxv_ethernet_v5_0_vl_rfs.sv` —— **是加密的，零明文 RTL**

**文件**：`_proj_10g/lic_deny_ctrl_prj/lic_deny_ctrl.gen/sources_1/ip/w2_pcs64_baser/hdl/xxv_ethernet_v5_0_vl_rfs.sv`（21,560,191 B / 280,035 行）

| 检查项 | 结果 |
|---|---|
| 开头是什么 | **第 1–2 行是空行，第 3 行就是 `` `pragma protect begin_protected ``** ⇒ **文件里没有任何明文 license 头注释**（原问题要求的"license 头注释原文"**不存在**；下方给出同目录**明文**文件的同族头注释作为替代） |
| 加密？ | ✅ IEEE-1735 加密。`` `pragma protect `` 出现 **35 次**；`begin_protected` 在 :3、`end_protected` 在 :280034 ⇒ **整个模块体都在保护壳里** |
| 明文 RTL？ | ❌ **零**。全文件 `^module` / `^endmodule` **一处都没有** |
| 关键词命中 | `xgmii|XGMII|gearbox|GEARBOX|0xFB|0xFD` 全文件**只有 2 行命中**，且都落在 `end_protected` 之后的收尾区（**不是** 可读 RTL） |
| 结论 | **这条路（读官方 RTL 抄成帧逻辑）走不通**。没有"明文版的 xxv_ethernet" |

**替代的 license 头注释原文**（同目录 `w2_pcs64_baser.v:1-45`，明文，AMD 标准头；这份就是同一个 PCS-only IP 的 wrapper）：

```
// ------------------------------------------------------------------------------
//   (c) Copyright 2020-2021 Advanced Micro Devices, Inc. All rights reserved.
//
//   This file contains confidential and proprietary information
//   of Advanced Micro Devices, Inc. and is protected under U.S. and
//   international copyright and other intellectual property
//   laws.
//
//   DISCLAIMER
//   This disclaimer is not a license and does not grant any
//   rights to the materials distributed herewith. Except as
//   otherwise provided in a valid license issued to you by
//   AMD, and to the maximum extent permitted by applicable
//   law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
//   WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
//   AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
//   BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
//   INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
//   (2) AMD shall not be liable (whether in contract or tort,
//   including negligence, or under any other theory of
//   liability) for any loss or damage of any kind or nature
//   related to, or arising under or in connection with these
//   materials, including for any direct, or any indirect,
//   special, incidental, or consequential loss or damage
//   (including loss of data, profits, goodwill, or any type of
//   loss or damage suffered as a result of any action brought
//   by a third party) even if such damage or loss was
//   reasonably foreseeable or AMD had been advised of the
//   possibility of the same.
//
//   CRITICAL APPLICATIONS
//   AMD products are not designed or intended to be fail-
//   safe, or for use in any application requiring fail-safe
//   performance, such as life-support or safety devices or
//   systems, Class III medical devices, nuclear facilities,
//   applications related to the deployment of airbags, or any
//   other applications that could lead to death, personal
//   injury, or severe property or environmental damage
//   (individually and collectively, "Critical
//   Applications"). Customer assumes the sole risk and
//   liability of any use of AMD products in Critical
//   Applications, subject only to applicable laws and
//   regulations governing limitations on product liability.
//
//   THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
//   PART OF THIS FILE AT ALL TIMES.
```

### 7b) `_proj_10g/vivado_prj/.../gt_10gbr/` 下有没有"真正的 10GBASE-R example design"？—— **没有**

目录结构（`synth/` 与 `sim/` 同构）：

```
gt_10gbr/
├── doc/    gtwizard_ultrascale_v1_7_changelog.txt
├── hdl/    gtwizard_ultrascale_v1_7_*.v（23 个 helper：reset / userclk / userdata / cal / bit_sync …）
├── sim/    gt_10gbr.v + gt_10gbr_gtwizard_gtye4.v + gt_10gbr_gtye4_{channel,common}_wrapper.v + 2 个原语模型
├── synth/  同上 + gt_10gbr.xdc / gt_10gbr_ooc.xdc
├── tcl/    example_scriptext.tcl（**加密**）
├── gt_10gbr/example_design/   ← 唯一的 example design
│     gt_10gbr_example_bit_sync.v            gt_10gbr_example_checking_64b66b_async.v
│     gt_10gbr_example_init.v                gt_10gbr_example_reset_sync.v
│     gt_10gbr_example_stimulus_64b66b_async.v  gt_10gbr_example_top.v  gt_10gbr_example_top.xdc
│     gt_10gbr_example_top_sim.v             gt_10gbr_example_wrapper.v
│     gt_10gbr_example_wrapper_functions.v   gt_10gbr_prbs_any.v
├── gt_10gbr.{veo,vho,sv,stub.v,xdc,dcp,xml,sim_netlist.v…}
```

**关键结论：本 IP 的 example design 就是"PRBS 版"**，没有第二套。
判据：`gt_10gbr_ex_tcl:56-63` 列出的 example 文件清单里，stimulus/checking 都带 `64b66b_async` 后缀；
而 `gt_10gbr_example_stimulus_64b66b_async.v:122-134` 里干的活是实例化 `prbs_any`。
⇒ **wizard 对 `64B66B_ASYNC` 只给 PRBS example，不给 MAC/成帧 example。**

（wizard 的 ttcl 模板目录里确实有 `_caui_` / `_64b67b_` 变体，但**都是加密的**
—— `C:/AMDDesignTools/2025.2/Vivado/data/ip/xilinx/gtwizard_ultrascale_v1_7/ttcl/*.ttcl` 全是 `XlxV50EB…` 开头的编译 Tcl。）

### 7c) `C:\AMDDesignTools\2025.2\` 下的示例/文档 —— **有成帧参考的"说明书"，没有明文 RTL**

| 位置 | 内容 | 价值 |
|---|---|---|
| `…/Vivado/data/ip/xilinx/gtwizard_ultrascale_v1_7/` | `component.xml`（**无端口描述文本**，已 grep 确认）、`hdl/`（23 个 helper，明文，但是 GT 适配层不是成帧层）、`rules/GTYE4/`、`xgui/` | 端口语义**查不到**（component.xml 的 `<spirit:description>` 不存在） |
| `…/Vivado/data/ip/xilinx/xxv_ethernet_v5_0/` | 官方 10GBASE-R/25G MAC+PCS 的 IP 目录（我们 license 被锁的那个） | 加密 |
| `…/Vivado/data/ip/xilinx/ten_gig_eth_pcs_pma_v6_0/` | 老一代 10GBASE-R PCS/PMA | 未展开（本次没查它的明文程度）【未核实】 |
| `…/Vivado/data/verilog/src/unisims/GTYE4_CHANNEL.v`（5,813 行） | 原语仿真模型，**列出全部端口/参数（无描述文本）** | 端口位宽的权威来源（`TXHEADER[5:0]` :807、`TXSEQUENCE[6:0]` :845、`RXHEADER[5:0]` :575、`RXHEADERVALID[1:0]` :576、`RXDATAVALID[1:0]` :572、`RXGEARBOXSLIP` :739、`RXSTARTOFSEQ[1:0]` :601） |
| `D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\lic_deny_ctrl_prj\…\w2_pcs64_baser\` | ⭐ **本次最有价值的替代证据**：官方 10GBASE-R PCS-only 核的**明文端口表 + 明文 GT 子核配置** | §2.2 / §7d |

### 7d) ⭐ 意外收获：官方 PCS-only 核的**明文外壳**就是最好的"官方怎么做成帧"的规格说明

虽然 RTL 加密，但三件明文已经足够给 P7b 定接口（逐条见 §2.2 / §3）：

1. `w2_pcs64_baser.veo:57-110` —— **fabric 面是 XGMII**（`tx_mii_d[63:0]` + `tx_mii_c[7:0]` + `rx_mii_d/c`）；
2. 同一份 `.veo` 列出**全部块级状态**：`block_lock` / `framing_err` / `hi_ber` / `bad_code` /
   `valid_ctrl_code` / `rx_error[7:0]` / `local_fault` / `rx_status` / `fifo_error`（`:80-97`）；
3. `ip_0/w2_pcs64_baser_gt.xci` + `ip_0/synth/w2_pcs64_baser_gt_gtye4_channel_wrapper.v`
   —— 官方 10GBASE-R 用的 **GT 配置（与本设计逐字相同）**，且**暴露 `txheader`/`txsequence`/`rxheader`/`rxheadervalid`/`rxdatavalid`/`rxgearboxslip`**
   （`:570,613,491,675,678,679`）⇒ **官方 soft PCS 就是在这套端口上做的成帧。**
4. 它还有**测试图案通路**：`ctl_tx_test_pattern_*` / `ctl_tx_prbs31_test_pattern_enable_0` /
   `ctl_tx_test_pattern_seed_{a,b}_0[57:0]`（`veo:105-112`，**58 位种子 = 802.3 的加扰器多项式阶数**）。

> ⭐ 第 4 条顺带给出一个**强提示（【推断】）**：官方 PCS 的 PRBS31 测试图案是**58 位种子**的，
> 说明**加扰/解扰器在官方 PCS 里是 soft logic 实现的**（58 = 802.3 Cl.49 的 `G(x)=1+x^39+x^58`）。
> 若成立，则我们手上的 GT **可能不做加扰**，P7b 需要自己做 scrambler/descrambler。
> **这条我没有直接证据，必须按 §10 的 E2/E3 去证。**

---

## 8. 本地文档：UG578 **找不到**（明确说明）

**结论：本机没有 UG578，也没有任何 64b/66b / gearbox 的本地 PDF/HTML 文档。**

查过的位置与结果：

| 位置 | 结果 |
|---|---|
| `D:\repo\XCKU5PMini\资料\PDF\` | 只有 `ug575-ultrascale-pkg-pinout.pdf` / `ds922` / `MT40A512M16LY` / `N25Q128A13ESE40F` / `RTL8211E` / `TPS548B28` / `tps565201` / `XCKU5P-1FFVB676` —— **没有 UG578** |
| `C:\AMDDesignTools\2025.2\` 全盘 `find -iname "*ug578*"` | **0 命中** |
| `C:\AMDDesignTools` 全盘 `-iname "*.pdf"`（depth ≤5） | 只有 SystemC 许可、dfu-util 手册、DocNav 自带 pdfjs 的示例 PDF、`ug968-xilinx-documentation-navigator.pdf` |
| `C:\AMDDesignTools\DocNav\` | 只有 DocNav 程序与 `resources/`，**没有下载任何 PDF 文档**（DocNav 是按需联网下载的） |
| `D:\` 全盘 `find -maxdepth 6 -iname "*ug578*"` | **0 命中** |

**因此本文所有 UG578 的说法都是【网文·未核原文】**（`docs.amd.com` 被网络策略拒绝，见证据强度表）。
**冲突时的裁决规则（按任务要求）**：**以本地生成物为准**。
本地生成物给出的硬事实是：端口位宽（`GTYE4_CHANNEL.v`）、属性取值（channel wrapper 的 `.GTYE4_CHANNEL_*`）、
`txheader` 逐位直通、`txsequence` 恒 0（example + 板级 6 Tbit 零错）、`GEARBOX_MODE=5'b10001`。

**替代证据（本文实际依赖的本地材料）**：
`.xci` 参数、channel wrapper 的 `GTYE4_CHANNEL_*` 属性、`gt_10gbr_stub.v/.veo` 的端口注释、
example design 的 RTL 注释（AMD 自己写的英文注释）、`GTYE4_CHANNEL.v` 原语端口表、
布局后回读报告 `p7a_readback.txt`、时钟/时序报告、**官方 PCS-only 核的明文外壳**（§7d）。

---

## 9. 给设计者的合同（一句话 + 一张图）

### 9.1 一句话

> **TX 侧我要提供：** 在 `clk_tx`（156.25 MHz）上，**每个时钟沿**一个 64 位净荷字 + 一个 6 位头
> （数据块 `6'b000001` / 控制块 `6'b000010`，高 4 位恒 0），`txsequence` 恒 `7'd0`；
> **一拍一个 64b/66b 块，没有 valid/ready，不能停顿**（要停就发 idle 控制块）。
>
> **RX 侧我能拿到：** 在 `clk_rx`（156.25 MHz，**与 `clk_tx` 无确定关系，必须当异步**）上，
> 每个时钟沿一个 64 位净荷字 + 6 位头（`[1:0]` = 同步头）+ `rxheadervalid[0]`（本配置恒 1）
> + `rxdatavalid[0]`（本配置恒 1）；**块边界/对齐要我自己用 `rxgearboxslip` 找、自己判 lock，
> 误码要用"同步头合法性"自己统计 —— GT 不给任何 block_lock / bad_code / hi_ber 信号。**

### 9.2 一张图

```
                 ┌──────────────── gt_10gbr（GT wizard IP）─────────────────┐
   clk_tx ──────▶│ TXUSRCLK2                                               │
   [63:0] ──────▶│ gtwiz_userdata_tx_in  ──▶ [64b/66b gearbox + 加/剥 2bit  │──▶ GTY ──▶ SFP A
   [5:0]  ──────▶│ txheader_in  (=6'b000001 data / 6'b000010 ctrl)          │
   [6:0]=0 ─────▶│ txsequence_in                                           │
                 │                                                          │
   [63:0] ◀──────│ gtwiz_userdata_rx_out ◀── [gearbox] ◀────────────────── │◀── GTY ◀── SFP B
   [5:0]  ◀──────│ rxheader_out   ([1:0]=sync header 01/10)                 │
   [1:0]  ◀──────│ rxheadervalid_out ([0] 恒 1)                            │
   [1:0]  ◀──────│ rxdatavalid_out    ([1:0] 恒 2'b11，板级实测)            │
   [1:0]  ──────▶│ rxgearboxslip_in   (1 拍脉冲；滑后等 ≥32 拍再判)          │
   [1:0]  ◀──────│ rxstartofseq_out   (序列计数=0；**不是** lock 指示)        │
                 └──────────────────────────────────────────────────────────┘
   ↑ 我自己要写的（GT 没有的）：802.3 Cl.49 组帧/解帧 · 块同步 FSM ·
     idle/S/T/E 生成 · block_lock / hi_ber / local_fault 计数 · 加扰（待证，见 E2）
```

---

## 10. 开放问题清单（逐条写"未核实"+下一步怎么查）

### 10.0 对 `P7A_SPEC.md` §9 清单的更新

| P7a 原编号 | 原问题 | 本次状态 |
|---|---|---|
| §9.2 | "`RXHEADER[5:0]` 的字段编码没解码" | **部分解决**：`[1:0]` = 2 bit 同步头（【网文·未核原文】）；`[2:0]` 由 `RXHEADERVALID[0]` 限定；`[5:3]` 是第二组头。**本地无文档，仍是网文证据** |
| §9.4 | "GTY RX gearbox 是否用同步头自动对齐未确证" | **已确证方向**：gearbox **不会**自动找对齐；**块同步必须由 fabric 做**，用 `rxgearboxslip` 反馈（【网文·未核原文】UG578 块同步章 + 官方 PCS 使能 `rxgearboxslip_in` 的旁证） |
| §9.6 | "`txheader_in` 6 bit 逐位含义未确证" | **收敛为假说 H1**（见下），有 3 条独立线索但**仍无本地硬证据** |
| §9.12 | "`rxdatavalid_out` 锁住后的实际占空比未确证" | ✅ **已解决（板级）**：`rxdatavalid[1:0]` 两通道**恒 `2'b11`**（`p7a_board_stdout.txt:252,293,309,447,584,602`），且 `hdrs_cnt == bits_cnt/64` 说明 `rxheadervalid[0]` 恒 1 ⇒ **`bits_cnt` 可以用 `rxdatavalid` 当使能，也可以用"每拍 +1"** |

### 10.1 上级假说 H1 的核实结论

> **H1：`txheader[5:0]` 在 gearbox 模式下可能只有低 2 位是 64b/66b 同步头，高 4 位无意义。**

**判定：证实（但在证据强度上是"网文 + 推断"，不是本机可核产物）。**

| H1 的分支 | 判定 | 依据 |
|---|---|---|
| 只有低 2 位是同步头 | **证实** | 【网文·未核原文】UG578 TXHEADER 表（`[1:0]` 为同步头，`[4:3]` 用于 16 字节/CAUI，未用位必须 0）；与 example 恒接 6'b000001 自洽 |
| 高 4 位无意义（必须 0） | **证实** | 同上 + example 取 `6'b000001`（高 4 位正是 0） |
| **GT 只做 gearbox，不做 XGMII→块的编码** | **证实** ⭐ | §2.2 的决定性对照：官方 PCS-only 核用**逐字相同**的 GT 配置，却把 XGMII 摆在 fabric 面 ⇒ 编码必在 GT 之外 |
| ~~GT 做加扰~~ ⇒ **GT 不加扰**（**方向相反**） | ⚠️ **2026-09-29 TL 复核更正**：原行把"gearbox / 加扰 / 不做编码"**三件事捆成一个断言**并标"证实"，而所引 §2.2 只支持其中**两件** —— "编码在 GT 之外"**既推不出加扰在 GT 之外，也推不出加扰在 GT 之内**。加扰一问与本文 **U2 是同一个问题** ⇒ **以 U2（未核实）为准**。<br>⚠️ **危害**：若照原行行事（以为 GT 会加扰），就会把**未加扰**的数据送给真网卡 ⇒ **链路直接死，且是安静失效**。<br>（2026-09-29 起 P7b 改用官方 `xxv_ethernet`，编解码与加扰由该核内部负责 ⇒ 本问**对 P7b 已不构成风险**；保留此条是为 P7a 的范围限定、并防后人误读。） | 旁证方向**相反**且较强：`P7B_LIB_SURVEY.md:528` 明述 "（GT 内部代替时用；**Xilinx async gearbox 不加扰**，所以要 0）"、`:323` "**Xilinx 的 async gearbox 不解扰**"；该库在 **soft logic** 里实现 58 位加扰器（`eth_phy_10g_tx_if.v:135-149`，多项式 `58'h8000000001`、种子 `{58{1'b1}}`、位置在**编码器之后**、**同步头不加扰**）；我方 `build_p7a.tcl` 与生成的 `gt_10gbr` IP 目录 **`grep -i scrambl` 均无命中**（`:828-829`）⇒ 排除法结论一致。**但仍属"第三方明述 + 排除法"，无 Xilinx 手册明文。** |
| `SYNC_DATA=2'b10` + `BIT_REVERSE(1)` = `2'b01` 与 example 一致 | **接受为强旁证**（来自同级侦察转述 `P7B_LIB_SURVEY.md:300-310`；本文未独立复核该库源码）。⇒ **两个互相独立的实现（Xilinx example / verilog-ethernet）在"送给 GTY 的 header 值"上完全一致**，这是 H1 最强的一条外部支撑 | — |
| 附带结论：GTY 的 fabric 字是 **MSb-first**（`txdata[63]` 先出线） | **接受为方向性线索**（同源：BIT_REVERSE 同时翻 data 与 hdr）；与 example 注释 "gearbox modes transmit data **MSb first**"（`gt_10gbr_example_stimulus_64b66b_async.v:88-89`）方向一致。**仅方向，不构成逐位确证** | U3 |

### 10.2 【未核实】逐条

| # | 未核实项 | 为什么重要 | 下一步怎么查 |
|---|---|---|---|
| **U1** | `txheader = 6'b000010` 是否就是本 GT 的"控制块"取值（**没有板级证据**） | 决定 P7b 能不能发 `/S/` 起始块 —— **没有它就连不成以太网帧** | **实验 E1**（见下） |
| **U2** | GT 内部**是否做 802.3 加扰/解扰**（`G(x)=1+x³⁹+x⁵⁸`） | 决定 P7b 是自己写 scrambler 还是直接送明文 | **实验 E2 / E3** |
| **U3** | `txdata` 的 64 bit ↔ 线上 8 字节的**字节/位序**（哪个 bit 先上线路；`txdata[63:56]` 是不是第 0 字节） | 决定 8 字节在 64 位字里的摆放与字节内位序 | ⭐ 已有**方向性线索**（§2.3 末两行）：`verilog-ethernet` 的 `BIT_REVERSE(1)` 说明 **GTY 是 MSb-first（`txdata[63]` 先出线）**，且它在 KU5P 板级 wrapper 里写死；但**本文未独立复核该库源码**，也**没有本设计的板级/文档证据** ⇒ 仍按 U 处理。**定案只能靠实验 E2/E3**（自环回因对称而零判别力） |
| **U4** | `rxheader[5:2]` 在本配置下的实际取值 | 若 P7b 用"头恒 01/10"作判据，多出的位会不会污染比较 | 上板读一次 `rxheader[5:0]` 的**全 6 位**（P7a 已经读了：**恒 `0x01`**，`p7a_board_stdout.txt:343`）⇒ 实际是已解决：**全 6 位 = 0x01**，但那只在"全数据块"的流量下成立 |
| **U5** | `rxdatavalid[1]` / `rxheadervalid[1]` 在本配置下的**应该**取值（实测都是 1） | 若 P7b 用 `rxdatavalid[0]` 当使能则无关；若用 `&rxdatavalid` 就可能被 `[1]` 的语义坑到 | 只接 `[0]`；把 `[1]` 接进调试观察窗 |
| **U6** | `RXPROGDIVCLK` 的分频器输入是"恢复时钟"还是"RX PLL" | 决定 RX 域是否真的跟对端频率走（影响 CDC 深度设计） | 查 UG578 RX PLL/PROGDIV 章（**本地无**）；或做变温/变对端时钟实验 |
| **U7** | P7a 实测那 **−5 ppm** 是真实频差还是测量效应 | 影响 CDC FIFO 的余量假设 | 换一个独立参考钟测同一比率；或对端换成第三方设备再测 |
| **U8** | 官方 PCS 里 `txsequence` 到底驱动什么值（端口被使能了，但 RTL 加密） | 若官方并非恒 0，说明我们恒 0 可能丢功能 | 无法读 RTL；只能靠 P7a 的板级背书（6 Tbit 零错） |
| **U9** | `total_latency` / gearbox FIFO 深度（`RXGBOX_FIFO_LATENCY` DRP 0x269） | 影响 P7b 的端到端延迟预算 | 读 DRP；或对环回做延迟测量 |
| **U10** | `GTYE4_CHANNEL_RXBUF_EN/TXBUF_EN = "FALSE"` 与 `.xci` 的 `RX/TX_BUFFER_MODE=1` 的**关系** | 看起来矛盾，但**Async gearbox 的正确用法就是 bypass 弹性缓冲**（由 gearbox FIFO 做相位补偿），官方 PCS 的取值**与我们逐字相同** ⇒ 这条**已经基本闭环**（不再是风险），但"为什么 GUI 显示 1 而原语是 FALSE"的**映射语义**未核实 | 不必再查（official 一致即可）；若要查，看 PG182 的 BUFFER_MODE 语义 |

### 10.3 三个"决定性实验"（都要求板子与外部标准设备）

> ⚠️ 按纪律，本报告**不做**这些实验，只登记。

| 实验 | 内容 | 能一次解决 |
|---|---|---|
| **E1** | 在**现有 P7a 位流**上加一条：把 `txheader` 从常量 `6'b000001` 改成**可经 VIO 选择**（`01`/`10`/`00`/`11`），用自环回读 `rxheader` + 观察 `prbs_match`/`hdre` 是否掉 | **U1**（控制块取值）、**U3**（半个） |
| **E2** | **对端换成标准 10GBASE-R 设备**（⭐ 对端 Linux 机 `192.168.0.38` 上有 **SFC9120 10G 网卡**，见记忆 `eco-linux-peer-box.md`）：让 KU5P 的 SFP 接该网卡的 SFP+ 口，跑一次真链路 | **U2 + U3 + 整份接口合同**（这是唯一能同时定"加扰/字节序/控制码"的判据；自环回是**对称**的，永远证不了绝对位序） |
| **E3** | 若 E2 不方便：用一台**支持 10GBASE-R 的交换机/测试仪**或第三方 SFP+ 网卡做对端，抓一个**已知以太网帧**回来，逐字节比对 | **U2 + U3** |

**最强的一条建议**：**P7b 在写组帧器之前，先做 E2。**
理由：自环回的对称性使 `txdata` 的绝对位序在数学上**不可观测**（TX 反转 + RX 反转互相抵消，
example 的位反转正是这个道理），继续用自环回只能验证"自洽"，无法验证"正确"。
项目历史上多次"安静失效"事故，源头正是这类"自洽但不对标"的判据。

---

## 11. 证据索引（全部引用过的文件 + 行号）

### 11.1 本设计（P7a）源码与工程

| 文件 | 行号 | 内容 |
|---|---|---|
| `_proj_10g/rtl/p7a_top.v` | 82-95, 176 | `clk_obs` = MMCM 156.25 MHz，接 `gtwiz_reset_clk_freerun_in` |
| | 100-112 | `IBUFDS_GTE4` on `MGTREFCLK0_225` (V7/V6) |
| | 117-144 | GT 接口线声明（`txheader_int[11:0]` / `txsequence_int[13:0]` / `rxdatavalid_int[3:0]` / `rxheader_int[11:0]` / `rxheadervalid_int[3:0]` / `rxgearboxslip_int[1:0]`） |
| | 146-147 | `clk_tx` / `clk_rx` = usrclk2[0] |
| | 162-163 | 用户时钟复位条件 `~(&*prgdivresetdone & &*pmaresetdone)` |
| | 165-206 | `gt_10gbr u_gt` 实例（全部端口连接） |
| | 211-224 | 每通道切片（`[63:0]`/`[127:64]`；headervalid `[1:0]`/`[3:2]`） |
| | 232-248 | 两个 PRBS stimulus 实例 |
| | 250-253 | `txheader_int` / `txsequence_int` 组装 |
| | 258-276 | 两个 PRBS checker 实例 |
| | 307 | `gtwiz_reset_all_int[0] = gt_reset_level`（来自 VIO） |
| | 310-322 | `rxgearboxslip` = example 自滑 **OR** VIO 强制单拍脉冲 |
| | 312-317 | `p7a_tgl_sync`：观测域 toggle → RX 域 1 拍脉冲 |
| | 409-493 | VIO 打包与 status 字位图 |
| `_proj_10g/rtl/gt_10gbr_example_stimulus_64b66b_async.v` | 58-65 | 端口（`txheader_out[5:0]` / `txsequence_out[6:0]` / `txdata_out[63:0]`） |
| | 73 | `reset = gtwiz_reset_all \|\| ~tx_active` |
| | 88-98 | **位反转** `txdata_out[i] = txdata_int[63-i]`，注释 "gearbox modes transmit data MSb first" |
| | 105-106 | `assign txheader_out = 6'b000001;` + 注释 "tie txheader to the 'data' type" |
| | 111-112 | `assign txsequence_out = 7'd0;` + 注释 |
| | 122-134 | `prbs_any #(CHK_MODE=0, INV_PATTERN=1, POLY_LENGHT=31, POLY_TAP=28, NBITS=64)` |
| `_proj_10g/rtl/gt_10gbr_example_checking_64b66b_async.v` | 58-66 | 端口（`rxdatavalid_in[1:0]` / `rxgearboxslip_out` / `prbs_match_out`） |
| | 89-99 | **位反转** `rxdata_int[i] = rxdata_in[63-i]` |
| | 109-125 | **滑位 hunt**：`rxgearboxslip_ctr_int` 每拍 +1，`!match` 时每 256 拍脉冲 `&ctr` |
| | 137-158 | `prbs_any #(CHK_MODE=1, ...)` |
| `_proj_10g/rtl/p7a_counters.v` | 38 | `hdre_cnt` 语义 = "`rxheader != 参考值`" |
| | 101-106 | `ch0/1_rxdv` 声明为 `[1:0]` |
| | 151-214 | `hdr_ref` 取锁定后首个 `rxheader`；偏离计数 |
| `_proj_10g/rtl/p7a_tgl_sync.v` | 全文 | toggle → 1 拍脉冲（`rxgearboxslip` 的脉冲整形） |

### 11.2 本设计生成物（Vivado 产物）

| 文件 | 行号 | 内容 |
|---|---|---|
| `…/ip/gt_10gbr/gt_10gbr_stub.v` | 17 | `CORE_GENERATION_INFO`：`TX/RX_DATA_ENCODING=4`、`*_USER/INT_DATA_WIDTH=64`、`*_OUTCLK_FREQUENCY=156.25`、`C_FREERUN_FREQUENCY=156.25` |
| | 19-31 | 完整端口清单（**没有** `rxnotintable`/`rxdisperr`/`rxprbserr`/buffbypass） |
| | 32 | `syn_black_box` 位宽串：`txheader_in[11:0]` / `txsequence_in[13:0]` / `rxdatavalid_out[3:0]` / `rxheader_out[11:0]` / `rxheadervalid_out[3:0]` / `rxstartofseq_out[3:0]` / `rxgearboxslip_in[1:0]` |
| `…/gt_10gbr/gt_10gbr.veo` | 57-98 | 实例化模板（端口注释） |
| `…/gt_10gbr/synth/gt_10gbr.v` | 467 | `rx8b10ben_in(2'H0)` |
| | 573 | ⭐ `rxprbssel_in(8'H00)`（内部 PRBS 关闭） |
| | 592 | `tx8b10ben_in(2'H0)` |
| | 616 / 659 | `txheader_in` / `txsequence_in` 向上引出 |
| | 650 | ⭐ `txprbssel_in(8'H00)`（内部 PRBS 关闭） |
| | 740-741 | `rxprbserr_out()` / `rxprbslocked_out()` **悬空** |
| `…/synth/gt_10gbr_gtwizard_gtye4.v` | 85-93 | `RX_DATA_DECODING__*` 枚举（4 = `64B66B_ASYNC`） |
| | 118-126 | `TX_DATA_ENCODING__*` 枚举（4 = `64B66B_ASYNC`） |
| | 1817 / 1885 / 1923 | `rxgearboxslip_int = rxgearboxslip_in` / `txheader_int = txheader_in` / `txsequence_int = txsequence_in`（**逐位直通**） |
| | 1979-1985 | `rxdata_out` / `rxdatavalid_out` / `rxheader_out` / `rxheadervalid_out` 直通 |
| | 2156-2262 | 到 `GTYE4_CHANNEL` 原语的连接（含 `TXHEADER`/`TXSEQUENCE`/`RXGEARBOXSLIP`/`RXHEADER`/`RXHEADERVALID`） |
| | 3806-3828 | TX userdata helper 实例；`assign txdata_int = gtwiz_userdata_tx_txdata_int` |
| | 3864-3872 | RX userdata helper 实例 |
| `…/synth/gt_10gbr_gtye4_channel_wrapper.v` | 567 | ⭐ `GTYE4_CHANNEL_GEARBOX_MODE (5'b10001)` |
| | 680 / 1109 | ⭐ `RXBUF_EN("FALSE")` / `TXBUF_EN("FALSE")` |
| | 904 / 1160 | ⭐ `RXGEARBOX_EN("TRUE")` / `TXGEARBOX_EN("TRUE")` |
| | 948 / 1184 | `RXOUTCLKSEL_VAL (3'b101)` / `TXOUTCLKSEL_VAL (3'b101)` |
| | 983 / 1243 | `RXPRBSSEL_VAL (4'b0000)` / `TXPRBSSEL_VAL (4'b0000)` |
| | 1033 / 1279 | `RX_DATA_WIDTH (64)` / `TX_DATA_WIDTH (64)` |
| | 1080 | ⭐ `RX_XCLK_SEL ("RXDES")` |
| | 904-996 | 其它 RX 属性（`RXSLIDE_MODE("OFF")` 等） |
| `…/hdl/gtwizard_ultrascale_v1_7_gtwiz_userdata_tx.v` | 53-96 | 用户宽度 → 原语宽度的映射（**补零在 MSB**，宽度<128 时） |
| `…/hdl/gtwizard_ultrascale_v1_7_gtwiz_userdata_rx.v` | 81-83 | ⭐ `gtwiz_userdata_rx_out[63:0] = rxdata_in[63:0]`（**低半字直通、不反转**） |
| `…/hdl/gtwizard_ultrascale_v1_7_gtwiz_reset.v` | 134-141 / 164-169 / 173-179 / 190-204 / 219-227 | reset-all FSM |
| | 331-337 / 389-397 / 401-408 / 411-418 / 422-425 | TX 复位 FSM（含 **PLL 失锁 ⇒ tx_done 掉回 0**） |
| | 589-596 / 666-671 / 676-683 | RX 复位 FSM（`WAIT_CDR` = rxcdrlock） |
| | 754 | `gtwiz_reset_rx_cdr_stable_out = rxcdrlock_sync` |
| `…/gt_10gbr/example_design/gt_10gbr_example_top.v` | 77-78 | `hb_gtwiz_reset_clk_freerun_in` / `hb_gtwiz_reset_all_in` 顶层输入 |
| | 120-121, 145-146 | ⭐ userclk reset 的 hook 线**故意悬空**（交用户填） |
| | 174-176 | `hb0_gtwiz_reset_all_int = 1'b0` |
| `…/example_design/gt_10gbr_example_top.xdc` | 80-81 | `create_clock -period 6.4` on freerun / refclk（**156.25 MHz**） |
| `…/example_design/gt_10gbr_example_init.v` | 61-62 | `P_TX_TIMER_DURATION_US=30000` / `P_RX_TIMER_DURATION_US=130000` |
| | 96-99, 127-130 | 注释：`tx/rx_init_done_in` 该接什么（含 buffbypass 的条件分支） |
| `…/gt_10gbr/gt_10gbr_ex.tcl` | 56-63 | example design 文件清单（**确认只有 PRBS 版**） |
| `…/p7a_prj.srcs/sources_1/ip/gt_10gbr/gt_10gbr.xci` | 35-53 | 用户参数（`64B66B_ASYNC` / 64 / 10.3125 / 156.25 / BUFFER_MODE=1 / OUTCLK=PROGDIVCLK） |
| | 491, 526-527, 603-604, 655-661, 691-695 | `INTERNAL_PORT_ENABLED_*`（PRBS/对齐类端口未生成） |
| | 753, 755, 802, 804 | `C_TX/RX_BUFFBYPASS_MODE=0` / `C_TX/RX_BUFFER_MODE=1` |
| `…/p7a_prj.gen/…/gt_10gbr/gt_10gbr_ex.tcl` | 全 | example 工程生成脚本（含 `generate_target example`） |
| `_proj_10g/tcl/build_p7a.tcl` | 61-63, 171-196 | 拷贝 example 文件、`generate_target example` |
| `_proj_10g/obs/probe_p7a.tcl` | 26, 132-138, 186-199 | VIO 探针映射 + `decode_status`（含 `rxdv` 解码式） |
| `_proj_10g/reports/p7a_readback.txt` | 5-20 | ⭐ 布局后回读 `GEARBOX_MODE=5'b10001` / `TX|RXGEARBOX_EN=TRUE` / `TX|RX_DATA_WIDTH=64` |
| `_proj_10g/reports/p7a_ip_config.txt` | 1-25 | ⭐ `EFF CONFIG.*`（含 `TX/RX_OUTCLK_SOURCE = TX/RXPROGDIVCLK`、`MISMATCHES = 0`） |
| `…/p7a_prj.runs/impl_1/p7a_top_clock_utilization_routed.rpt` | 63, 66 | `gtwiz_userclk_{rx,tx}_srcclk_out[0]` 各由 1 个 BUFG_GT 驱动，周期 6.400 |
| | 80, 83 | ⭐ `src1 = GTYE4_CHANNEL_X0Y4/RXOUTCLK`、`src4 = …/TXOUTCLK` |
| `…/p7a_prj.runs/impl_1/p7a_top_timing_summary_routed.rpt` | 155-167 | 时钟摘要：**两条** 156.250 MHz 用户时钟 |
| | 179-185 | 每时钟 WNS/WHS |
| | 196-212 | 时钟交互表：**两时钟之间无路径**（只有各自的 `async_default`） |

### 11.3 板级读数（P7a 验收）

| 文件 | 行号 | 内容 |
|---|---|---|
| `_proj_10g/board_scratch/logs/p7a_board_stdout.txt` | 249-250 | 原始 status 字（十进制大整数） |
| | 252, 293, 309, 447, 584, 602 | ⭐ `hdr_ref(ch0)=0x01 hdr_ref(ch1)=0x01 … rxdv(ch0,ch1)=33`（`rxdatavalid[1:0]` 恒 `2'b11`） |
| | 343-347 | 5 次采样 `hdr_ref=0x01`、`hdrs_cnt` 单调、`hdr_err_cnt=0/0` |
| | 357 | `LEG3_HDR_REF = ch0=0x01 (1) ch1=0x01 (1)` |

### 11.4 项目文档

| 文件 | 行号 | 内容 |
|---|---|---|
| `P7A_RESULT.md` | 109, 111, 113 | P2c/P2e/P2g 判据读数 |
| | 204-218 | 板级验收原始读数块（RATE / RATIO / BER 上界 / 判决） |
| | 225-238 | 逐项说明 + **诚实的第三条（−5 ppm 未查）** |
| | 282, 296, 310 | 状态字读数复述 |
| | 408 | "6-bit `rxheader` 的编码未解码，2-bit 64B/66B sync header 不在 fabric 可观测面上" |
| `P7A_SPEC.md` | 130, 155, 186-187, 212 | `TX/RX_BUFFER_MODE=1` 与 EFF CONFIG |
| | 218-236 | example design 的定位（存在、带 PRBS、判据钝） |
| | 352-358 | GT 端口清单（含 `txheader_in` / `rxgearboxslip_in` / `rxheader_out`） |
| | 394-397 | ⭐ "`txheader_in` 是 fabric 侧最容易漏的一根线" |
| | 404-413 | "fabric 数据在 raw 与 gearbox 下都透明"（→ 自环回不能证明 gearbox，也**不能证明位序**） |
| | 422-443 | `GEARBOX_MODE` / `TX|RXGEARBOX_EN` A/B 回读 |
| | 456-458 | 33:32 / 频率恒等式 |
| | 464-474 | 腿 3 判据 + 负对照 A |
| | 487-494 | "属性是配置不是运行"的告诫 |
| | 723-747 | ⭐ §9「我没确证的」12 条（本文 §10.0 逐条更新） |

### 11.5 官方参考（明文外壳）

| 文件 | 行号 | 内容 |
|---|---|---|
| `_proj_10g/lic_deny_ctrl_prj/…/w2_pcs64_baser/w2_pcs64_baser.veo` | 57-110 | ⭐ **fabric 面 = XGMII**：`tx_mii_d_0[63:0]`(:98)、`tx_mii_c_0[7:0]`(:99)、`rx_mii_d_0[63:0]`(:78)、`rx_mii_c_0[7:0]`(:79) |
| | 80-97 | ⭐ 全部块级状态：`framing_err`(:84)、`block_lock`(:87)、`hi_ber`(:90)、`local_fault`/`valid_ctrl_code`/`status`/`bad_code`/`error[7:0]`/`fifo_error` |
| | 60-71 | 时钟：`rx_core_clk_0`(:62)、`tx_mii_clk_0`(:70)、`rx_clk_out_0`(:71) |
| | 105-112 | 测试图案：`ctl_tx_test_pattern_seed_{a,b}_0[57:0]`、`ctl_tx_prbs31_test_pattern_enable_0` |
| `…/w2_pcs64_baser/ip_0/w2_pcs64_baser_gt.xci` | 32-53 | ⭐ GT 配置（`64B66B_ASYNC`/64/64/10.3125/156.25/QPLL0/BUFFER_MODE=1/`{TX,RX}PROGDIVCLK`） |
| | 491, 570, 613, 675, 678, 679 | ⭐ `rxgearboxslip_in` / `txheader_in` / `txsequence_in` / `rxdatavalid_out` / `rxheader_out` / `rxheadervalid_out` **端口均使能** |
| | 162-168 | `LOCATE_RESET_CONTROLLER=CORE` |
| `…/ip_0/synth/w2_pcs64_baser_gt_gtye4_channel_wrapper.v` | 567, 680, 904, 948, 1033, 1080, 1109, 1160, 1184, 1279 | ⭐ 与原语属性**逐项与本设计相同** |
| `…/w2_pcs64_baser/hdl/xxv_ethernet_v5_0_vl_rfs.sv` | 1-3 | ⭐ 加密证据：第 1-2 行空行、第 3 行 `pragma protect begin_protected` |
| | 3, 280034 | `begin_protected` / `end_protected`（全文 35 处 `pragma protect`） |
| `…/w2_pcs64_baser/w2_pcs64_baser.v` | 1-45 | ⭐ AMD 标准 license 头注释**明文原文**（§7a 已抄录） |

### 11.6 工具链内的原语/文档

| 文件 | 行号 | 内容 |
|---|---|---|
| `C:\AMDDesignTools\2025.2\Vivado\data\verilog\src\unisims\GTYE4_CHANNEL.v` | 572, 575, 576, 601 | `RXDATAVALID[1:0]` / `RXHEADER[5:0]` / `RXHEADERVALID[1:0]` / `RXSTARTOFSEQ[1:0]` |
| | 739, 768, 785-786, 807, 840, 845 | `RXGEARBOXSLIP` / `RXPRBSSEL[3:0]` / `TX8B10B*` / `TXHEADER[5:0]` / `TXPRBSSEL[3:0]` / `TXSEQUENCE[6:0]` |
| | 1134, 1256 | `RXGEARBOX_EN_REG` / `TXGEARBOX_EN_REG` |
| `C:\AMDDesignTools\2025.2\Vivado\data\ip\xilinx\gtwizard_ultrascale_v1_7\` | — | `component.xml` **无端口描述**；`ttcl/*.ttcl` **全加密**；`tcl/` 与 `xgui/` grep `txheader` **0 命中** |

### 11.7 网页（**均未核原文**；`docs.amd.com` 被网络策略拒绝）

- UG578 "UltraScale Architecture GTY Transceivers" —— TX gearbox / TXHEADER / TXSEQUENCE 表、RX 异步 gearbox（Table 4-47）、
  RXGEARBOXSLIP、块同步状态机（`LOCK_INIT…SLIP`、`sh_cnt≤64`、`sh_invalid_cnt≤16`、slip 后等 32 拍）、
  `RXBUF_EN`/`RX_XCLK_SEL`（`RXDES` 用于弹性缓冲**或异步 gearbox**）
  URL：`https://docs.amd.com/v/u/en-US/ug578-ultrascale-gty-transceivers`
- UG576（GTH，同族文档）块同步/gearbox 描述：`https://twiki.cern.ch/twiki/pub/Main/EpicSH/UG576_2021.pdf`
- AMD 论坛（slip 后 `RXHEADERVALID` 短暂异常的实测反馈）：
  `https://adaptivesupport.amd.com/s/question/0D54U00006nV1TwSAK/...`
- 开源 `verilog-ethernet`（`eth_phy_10g.v` / `xgmii_baser_enc_64.v`，`HDR_WIDTH=2`、`SYNC_DATA=2'b10`+`BIT_REVERSE(1)`、
  issue #33 "fully custom PCS in soft logic"）—— **【上级侦察转述】，本文未独立复核**

---

## 12. 一分钟速查卡（打印用）

```
数据块 header = 6'b000001        控制块 header = 6'b000010（U1，待板级证实）
txsequence    = 7'd0             其余 header 位 = 0
TX 时钟 = clk_tx 156.25MHz        RX 时钟 = clk_rx 156.25MHz（← 当异步！）
TX 推数据门 = gtwiz_userclk_tx_active_out（板级验证过的配方见 p7a_top.v:162）
RX 数据可信 = rx_active & rx_done & rx_cdr_stable & 【自己做出来的 block lock】
块对齐     = 1 拍脉冲 rxgearboxslip → 等 ≥32 拍 → 数连续 64 个好头（坏头 ≤15）
误码指示   = 无（自己数同步头）；rxprbserr 悬空；rxnotintable/rxdisperr 不存在
GT 内部 PRBS = 关闭（TXPRBSSEL=RXPRBSSEL=4'b0000），PRBS 在 fabric
要自己写的 = 802.3 Cl.49 组帧/解帧 + 块同步 FSM + idle/S/T/E + block_lock/hi_ber 计数 + （可能）加扰
位序线索   = GTY 是 MSb-first（txdata[63] 先出线）；XGMII 习惯要整字镜像（BIT_REVERSE=1）—— 仍属 U3，未定案
先做 E2（对端 = 192.168.0.38 的 SFC9120 10G 网卡）再写代码 —— 自环回证不了绝对位序
姊妹侦察   = notes/P7B_LIB_SURVEY.md（开源库硬证据）/ notes/P7B_DATAPATH_CONTRACT.md（下游 MAC 合同）
```
