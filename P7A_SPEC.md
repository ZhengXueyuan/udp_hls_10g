# P7A_SPEC.md —— 闸 0 施工规格书

**目标（P7a）**：证明这块板（`xcku5p-ffvb676-1-e`）上的 **10G PCS/PMA 通路（含 64b/66b gearbox）真的在跑**，
方法是 SFP A ↔ SFP B 经 AOC 外部环回测出 **BER < 1e-12**，**并且有正证据证明 gearbox 真的在通路里**。

**为什么这是当前最大的未知数**：2026-09-27 的 iBERT 轮把**模拟链路**测透了
（外部环回 BER < 2.4×10⁻¹²，双向各 1.239 Tbit 零错误），但那一轮 **`TXGEARBOX_EN=FALSE`、`DATAWIDTH` 被钳在 80**
⇒ GT 跑的是 **raw**，**PCS/gearbox 一层是空白**。

**本规格书的状态**：所有"工具能力/器件参数"结论都附**工具原始输出**；闸 0 **未烧板**（板子载着 P6b 冻结位流）；
所有 Vivado 实验都在独立 scratch 工程 `udp_hls_10g/_p7a_probe/` 里做，**只跑 OOC 综合 + 布局**，未跑 `launch_runs` 全流程。

---

## 0. 一页结论（TL;DR）

| 问题 | 结论 |
|---|---|
| wizard 提供 10GBASE-R 预设吗？ | **GUI 里有**（`presets/GTY-10GBASE-R.tcl`，加密文件），**Tcl/batch 里没有** —— `CONFIG.TX_PROTOCOL` 这个参数**不存在**（`[Vivado 12-4371]`）。batch 里只能直接设 GT 原语参数。 |
| 对本器件可用吗？ | ✅ 可用。`IPDEF_SUPPORTED_PARTS` 显式列出 `xcku5p-ffvb676-1-e`。 |
| license 干净吗？ | ✅ **干净，且"免 license"已直证**（⚠️ 本行 2026-09-29 复核更正）：在位 license 下 `IS_LOCKED=0` / `LOCK_DETAILS = IP is not locked` / `USED_LICENSE_KEYS = <>`；**把 `Xilinx.lic` 藏掉后同样干净**（P2j / `_proj_10g/reports/p7a_lic_deny_stdout.txt`，恢复已核对 MD5）⇒ §9.1 那条已闭。⚠️ 同轮"`xxv_ethernet` 被锁"是**藏 license 造成的**，**不能**反推"该 IP 平时不可用 / 要另买 license"（见 §1.2 末的复核更正）。 |
| fabric 侧接口 | **64 bit/ch @ 156.25 MHz**（实测，不是预期）。时钟名 `gtwiz_userclk_{tx,rx}_usrclk2_out`。 |
| 有现成 example 带 PRBS 吗？ | ✅ **有**。`generate_target example` 产出 PRBS31 发生器/校验器（XAPP884 `prbs_any`）+ gearbox 滑位 hunt + 内建 VIO。 |
| 建议路线 | **用 example 的 PRBS 三件套当零件，自己写 top**（判据要自己控，见 §2）。 |
| gearbox 正证据 | **三条腿**：① 布局后回读 `TXGEARBOX_EN/RXGEARBOX_EN/GEARBOX_MODE`（**已实测有区分能力**）② fabric 时钟 156.25 vs 161.1328125（**已实测**）③ 上板 PRBS 锁 + `rxgearboxslip` 负对照。**主位流 1 次**（负对照孪生可选 +1 次）。 |
| 最大的一条坑 | example 的 `link_status_out` 是**漏桶**判据，**不能**当零误码证据（见 §1.5 / §5.1）。 |

---

## 1. 工具事实核实（每条给工具原始输出）

### 1.1 IP 存在、版本、器件支持

原始输出（`_p7a_probe/p1_stdout.txt`）：

```
CMD: get_ipdefs -filter {NAME == gtwizard_ultrascale}
RC = 0
IPDEFS = <xilinx.com:ip:gtwizard_ultrascale:1.7>
COUNT = 1
IPDEF_VLN = xilinx.com:ip:gtwizard_ultrascale:1.7
IPDEF_NAME = gtwizard_ultrascale
IPDEF_VER  = 1.7
IPDEF_LICKEYS =
IPDEF_SUPPORTED_FAMILIES = <kintexuplus:ALL:Production>
```

`IPDEF_SUPPORTED_PARTS` 里显式含 `xcku5p-ffvb676-1-e`（同一列表里还有 `xcku5p-ffvb676-1-i/-1L-i/-2-*/-3-e` 等）。

> ⚠️ 本工程踩过的坑：`get_ipdefs` 必须用 **`-filter {NAME == ...}`**，用 `-name` 在本机 2025.2 返回 0 并报
> `[Coretcl 2-175] No Catalog IPs found`。另外 `get_ipdefs` **需要先有打开的工程**，否则报
> `ERROR: [Common 17-53] User Exception: No open project.`（本轮实测踩到）。

### 1.2 license 结论（含读数的区分能力）

**结论：在位 license 下 gtwizard 是干净的。** 原始输出（`_p7a_probe/p5_stdout.txt`，一次原子配置后 generate）：

```
GENERATE_ALL rc = 0
IS_LOCKED = 0
LOCK_DETAILS = IP is not locked
USED_LICENSE_KEYS = <>
EXAMPLE_TARGET rc = 0
```

早一轮（`p1_stdout.txt`）在**默认配置**下也是：

```
IS_LOCKED_AT_CREATE = 0
USED_LICENSE_KEYS_AT_CREATE =
IS_LOCKED_AFTER_GENERATE = 0
LOCK_DETAILS = IP is not locked
USED_LICENSE_KEYS =
```

**这个读数有区分能力**（反证来自本机 `_lic/deny_stdout.txt`，`xxv_ethernet` 在 `Xilinx.lic` 被改名后的形态）：

```
DENY_A_IS_LOCKED = 1
DENY_A_LOCK_DETAILS = * IP 'w2_pcs64_baser' requires one or more mandatory licenses but no valid
                      licenses were found. However license checkpoints may prevent use of this IP ...
DENY_A_USED_LICENSE_KEYS = {{implementation {xxv_eth_mac_pcs@2025.05 design_linking}
                                          {xxv_eth_basekr@2025.05 design_linking}
                                          {xxv_tsn_802d1cm@2025.05 design_linking}} ...}
WARNING: [IP_Flow 19-2162] IP 'w2_pcs64_baser' is locked: ...
CRITICAL WARNING: [filemgmt 20-1365] Unable to generate target(s) for the following file is locked
```

⇒ 同一台机、同一版本下，"被锁"的形态长什么样是**已知**的（`IS_LOCKED=1` + `LOCK_DETAILS` 明说 + `USED_LICENSE_KEYS`
里出现 `design_linking` 键），而 gtwizard 的读数是 `IS_LOCKED=0` + `LOCK_DETAILS = IP is not locked` + `USED_LICENSE_KEYS` **空**。

**⚠️ 但"免 license"没有被直接证明**：缺的是"**把 `Xilinx.lic` 藏掉**之后 gtwizard 仍然干净"这一条负对照。
本机 `C:\AMDDesignTools\2025.2\data\ip\core_licenses\` 里 `Xilinx.lic`（7445 B，MD5 `9bab9853d542567cbae9e2152f04223e`）**一直在位**，
所以现在的"干净"也可能只是"license 恰好可用"。

**建议**：把这条负对照作为 **P7a 的板前闸**（不烧板，只建工程，约 5 分钟）：
按 `_lic/tcl_b_deny.tcl` 的写法（**改名 → 建 IP + generate → 读 `IS_LOCKED`/`USED_LICENSE_KEYS` → 恢复**，
必须带 `PREGUARD` 检查，因为残留的 `Xilinx.lic.HIDDEN` 会让后续 `ABORT`）。
- 若负对照确认干净 ⇒ 可以对外声称"免 license"，且不依赖本机安装目录。
- 若负对照显示被锁 ⇒ 仍然走 wizard 路线（本机 license 在位，工程可交付），只是**不能**声称免 license。

> ⭐ **2026-09-29 复核更正（本条已兑现 + 一处被纠正的延伸）**
> 1. **负对照已补做并通过**：P7a 的 **P2j** 就是这条闸，读数在 `_proj_10g/reports/p7a_lic_deny_stdout.txt`
>    —— 藏掉 `Xilinx.lic` 后 gtwizard 仍 `IS_LOCKED=0` / `LOCK_DETAILS = IP is not locked` /
>    `USED_LICENSE_KEYS = <>` / `generate_target all rc=0` / 7 个 RTL 落盘，恢复已核对
>    （MD5 前后同为 `9bab9853d542567cbae9e2152f04223e`，无残留 `.HIDDEN`）。⇒ **"gtwizard 免 license"成立**
>    （见 `P7A_RESULT.md` §3.4，该结论**保留、不撤回**）。
> 2. **必须纠正的一步延伸**：这里引的 `_lic/deny_stdout.txt` 是**在"把 license 藏起来"的状态下**测的，
>    ⇒ 它**不能**反推出"`xxv_ethernet` 锁着 / 不可用 / 要另外买 license"。**事实相反**：license 在位时
>    `xxv_ethernet 5.0` 的三种 CORE 配置 `IS_LOCKED` **建时/配后/生成后全 0**、`CONFIG.*` 均可设、
>    `generate_target all` **产出完整 RTL**（`_lic/prep_stdout.txt:89,97,207/226,234,344/363,371,481`），
>    而 `Xilinx.lic` 里本就有 `INCREMENT xxv_eth_mac_pcs xilinxd 2025.11 permanent uncounted`
>    （同批 `xxv_eth_basekr`/`l_eth_baser`/`l_eth_mac_pcs`/`ten_gig_eth_mac` 等同样 `permanent`）。
>    藏起来才锁，**锁定形态**恰恰是"有区分能力"的证据，不是"该 IP 平时不可用"的证据。
>    补充：**缺 license 的失败形态是综合期硬失败**（`_lic/syn_stdout.txt:868,871`：
>    `Fatal Error. License Check failed for secure IP for feature 'xxv_eth_mac_pcs@2025.05'` /
>    `Feature: Internal_bitstream`），**不是**"位流能出但跑几小时就停"的位流超时。
>    ⚠️ 且那次综合实验建在 **Kintex-7 `xc7k70tfbv676-1`**（`syn_stdout.txt:60,61,784,785` 的
>    `does not support the current project part 'xc7k70tfbv676-1'`）⇒ **它对 KU5P 没有权威性**，
>    引用时必须标注（KU5P 那部分的证据是 `_lic/prep_stdout.txt`，那条是 2026-09-27 phase A 在
>    **本器件**上做的）。

### 1.3 ⭐ "10GBASE-R 预设"在 Tcl 里不存在 —— batch 的正确做法

**（a）没有 protocol 参数。** 原始输出（`p1_stdout.txt` / `p2_vivado.log`）：

```
SET CONFIG.TX_PROTOCOL = <10GBASE-R> => FAIL : ERROR: [Common 17-39] 'set_property' failed due to earlier errors.
ERROR: [Vivado 12-4371] Cannot find parameter 'TX_PROTOCOL' on IP 'p1_gt'.
ERROR: [Vivado 12-1342] Failed to set property 'CONFIG.TX_PROTOCOL' on IP 'p1_gt'.
ERROR: [Vivado 12-4371] Cannot find parameter 'RX_PROTOCOL' on IP 'p1_gt'.
ERROR: [Vivado 12-4371] Cannot find parameter 'TX_USER_CLOCKING_SOURCE' on IP 'p2_gt'.
```

对 `C:\AMDDesignTools\2025.2\data\ip\xilinx\gtwizard_ultrascale_v1_7\component.xml` 直接 grep
`spirit:name="[A-Z_]*PROTOCOL[A-Z_]*"`：**0 命中**。⇒ standalone wizard 的 92 个可设参数里**根本没有 protocol 这一项**。

**（b）但预设文件是有的，只是 GUI 专用。** `presets/` 目录共 87 个文件、其中 **45 个 `GTY-*.tcl`**，
含 **`GTY-10GBASE-R.tcl`**、`GTY-10GBASE-KR.tcl`、`GTY-CAUI_10`、`GTY-CPRI_10G` 等。
**这些文件是加密的**（直接读出来是二进制乱码）⇒ 只能在 GUI 里点，batch 调用不了。

**（c）batch 里唯一的办法 = 直接设 GT 原语参数，而且有现成的黄金参照。**
本机已有一份 **`xxv_ethernet` 内部生成的 10GBASE-R 64-bit GT 实例**：
`D:\repo\XCKU5PMini\_probe2\p3_xxv_pcs64\p3_xxv_pcs64.gen\sources_1\ip\p3_xxv_pcs64\ip_0\p3_xxv_pcs64_gt.xci`。
它的参数就是我们要的那一套（实测读出）：

```
C_TX_DATA_ENCODING      = 4          C_RX_DATA_DECODING      = 4
C_TX_INT_DATA_WIDTH     = 64         C_RX_INT_DATA_WIDTH     = 64
C_TX_USER_DATA_WIDTH    = 64         C_RX_USER_DATA_WIDTH    = 64
C_TX_BUFFER_MODE        = 1          C_RX_BUFFER_MODE        = 1
C_TX_LINE_RATE          = 10.3125    C_RX_LINE_RATE          = 10.3125
C_TX_REFCLK_FREQUENCY   = 156.25     C_RX_REFCLK_FREQUENCY   = 156.25
C_TX_OUTCLK_FREQUENCY   = 156.2500000
```

**（d）枚举值必须用字符串，不是数字索引。** 原始输出（`p2_vivado.log`）：

```
ERROR: [IP_Flow 19-3461] Value '4' is out of the range for parameter 'Encoding(TX_DATA_ENCODING)'
      for IP 'p2_gt' . Valid values are - 8B10B, 64B66B_ASYNC, 64B66B_ASYNC_CAUI, RAW, 64B66B,
      64B66B_CAUI, 64B67B, 64B67B_CAUI
ERROR: [IP_Flow 19-3461] Value '0' is out of the range for parameter 'PLL type(TX_PLL_TYPE)'
      ... Valid values are - QPLL0, QPLL1
ERROR: [IP_Flow 19-3461] Value '2' is out of the range for parameter 'TXOUTCLK source(TX_OUTCLK_SOURCE)'
      ... Valid values are - TXOUTCLKPMA, TXOUTCLKPCS, TXPROGDIVCLK
```

数字映射在生成的 HDL `define` 里（`*_gtwizard_gtye4.v`，工具原文）：

```verilog
`define ..._RX_DATA_DECODING__RAW 0 / __8B10B 1 / __64B66B 2 / __64B66B_CAUI 3
`define ..._RX_DATA_DECODING__64B66B_ASYNC 4 / __64B66B_ASYNC_CAUI 5 / __64B67B 6 / ...
```

⇒ **10GBASE-R = `64B66B_ASYNC`（编码 4）+ 64-bit 内部数据宽度 + 使能 buffer。**

### 1.4 ⭐ 参数设置的四个硬性顺序/形式约束（踩过的坑，必须写进构建脚本）

| # | 约束 | 不遵守时的工具原文 |
|---|---|---|
| a | `TX_INT_DATA_WIDTH=64` 只有在 `TX_USER_DATA_WIDTH=64` **之后**设才被接受 | `[IP_Flow 19-3461] Value '64' is out of the range for parameter 'Internal data width(TX_INT_DATA_WIDTH)' for IP 'p3_gt' . Valid values are - 32` |
| b | `TX_REFCLK_FREQUENCY` 与 `RX_REFCLK_FREQUENCY` **必须原子同设**（一个 `set_property -dict`） | `[IP_Flow 19-3478] Validation failed for parameter 'Actual Reference clock (MHz)(RX_REFCLK_FREQUENCY)' ... 'RX and TX frequencies do not allow for PLL sharing'` |
| c | `TX/RX_REFCLK_SOURCE` 默认是 `clk1`，本板只焊 `MGTREFCLK0`(clk0)，**两边都要设且要一致** | `[IP_Flow 19-3478] ... The TX and RX REFCLK sources must match for each quad in order to use QPLL0, see channels X0Y4 X0Y5` |
| d | `LOCATE_*` 的合法值是 `CORE` / `EXAMPLE_DESIGN`，**不是 0/1** | `[IP_Flow 19-3461] Value '0' is out of the range for parameter 'Include transceiver COMMON in the(LOCATE_COMMON)' ... Valid values are - CORE, EXAMPLE_DESIGN` |

**(b) 的机理（值得记住）**：`p4_matrix.tcl` 的 A/B/C/D **四个变体全部**在这一条上失败。
逐条设 `TX_REFCLK_FREQUENCY=156.25` 时 RX 仍是默认 `64.453125` ⇒ 校验报"不允许共享 PLL" ⇒ **整条 `set_property` 回滚**；
紧接着设 RX=156.25 时 TX 又退回 64.453125 ⇒ 镜像失败。**中间态永远非法，所以单条永远设不进去。**
`p5_final.tcl` 用一次 `set_property -dict` 把整套参数（含两个频率）原子提交 ⇒ `ATOMIC_SET rc = 0`，一次过。

**(a) 的机理**：`TX_INT_DATA_WIDTH` 的静态 choice 表是 `16/20/32/40/64/80`
（`component.xml:15188 <spirit:name>choice_list_ab750e25</spirit:name>`），
动态合法集由加密的 `rules/GTYE4/tx_gtye4_rules.tcl` 按 user 宽度算出来 ⇒ 必须 user 先定。

**验证过的完整配方**（`p5_final.tcl`，一次 `set_property -dict`）：

```tcl
set cfg [dict create \
    CONFIG.CHANNEL_ENABLE        {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING      {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING      {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH    {64} \
    CONFIG.RX_USER_DATA_WIDTH    {64} \
    CONFIG.TX_INT_DATA_WIDTH     {64} \
    CONFIG.RX_INT_DATA_WIDTH     {64} \
    CONFIG.TX_BUFFER_MODE        {1} \
    CONFIG.RX_BUFFER_MODE        {1} \
    CONFIG.TX_LINE_RATE          {10.3125} \
    CONFIG.RX_LINE_RATE          {10.3125} \
    CONFIG.TX_PLL_TYPE           {QPLL0} \
    CONFIG.RX_PLL_TYPE           {QPLL0} \
    CONFIG.TX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.RX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.TX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.TX_OUTCLK_SOURCE      {TXPROGDIVCLK} \
    CONFIG.RX_OUTCLK_SOURCE      {RXPROGDIVCLK} \
    CONFIG.LOCATE_RESET_CONTROLLER       {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING       {CORE} \
    CONFIG.LOCATE_RX_USER_CLOCKING       {CORE} \
    CONFIG.LOCATE_COMMON                 {CORE} \
    CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} ]
set_property -dict $cfg [get_ips gt_10gbr]
```

回读（`p5_stdout.txt`，全部 OK）：

```
EFF CONFIG.TX_DATA_ENCODING = <64B66B_ASYNC>      EFF CONFIG.RX_DATA_DECODING = <64B66B_ASYNC>
EFF CONFIG.TX_INT_DATA_WIDTH = <64>               EFF CONFIG.RX_INT_DATA_WIDTH = <64>
EFF CONFIG.TX_USER_DATA_WIDTH = <64>              EFF CONFIG.RX_USER_DATA_WIDTH = <64>
EFF CONFIG.TX_BUFFER_MODE = <1>                   EFF CONFIG.RX_BUFFER_MODE = <1>
EFF CONFIG.TX_PLL_TYPE = <QPLL0>                  EFF CONFIG.RX_PLL_TYPE = <QPLL0>
EFF CONFIG.TX_LINE_RATE = <10.3125>               EFF CONFIG.RX_LINE_RATE = <10.3125>
EFF CONFIG.TX_REFCLK_FREQUENCY = <156.25>         EFF CONFIG.RX_REFCLK_FREQUENCY = <156.25>
```

### 1.5 ⭐ example design：存在、带 PRBS、**且判据是钝的**

**target 名字是 `example`，不是 `example_design`。** 原始输出：

```
ERROR: [Vivado 12-1773] No legal targets specified.  Supported targets for this IP are:
       all elaborate_boundary block_model instantiation_template synthesis simulation example changelog.
       File: 'p2_gt.xci'.
```

`generate_target example` rc = 0（`p5_stdout.txt`），产出 `gt_10gbr/example_design/`，含：

| 文件 | 作用（读源码得来） |
|---|---|
| `gt_10gbr_prbs_any.v` | XAPP884 PRBS 核（`CHK_MODE/INV_PATTERN/POLY_LENGHT/POLY_TAP/NBITS`） |
| `gt_10gbr_example_stimulus_64b66b_async.v` | PRBS31 发生器：`POLY_LENGHT=31, POLY_TAP=28, NBITS=64, INV_PATTERN=1`；`txheader_out = 6'b000001`；`txsequence_out = 7'd0`；**含 gearbox 需要的 64-bit 位序反转** |
| `gt_10gbr_example_checking_64b66b_async.v` | PRBS31 校验器，输出 `prbs_match_out`；**自动用 `prbs_match_out` 反馈脉冲 `rxgearboxslip`**（原文注释："Use the PRBS checker lock indicator as feedback, **periodically pulsing the rxgearboxslip until lock is achieved**"） |
| `gt_10gbr_example_top.v` | 顶层 + 链路 FSM + **内建 VIO**（`probe_in0=link_status_out`、`probe_in1=link_down_latched_out`、`probe_out5=link_down_latched_reset_vio_int`） |
| `gt_10gbr_example_top.xdc` | **已经把 refclk 钉到本板的 V7/V6**，`create_clock -period 6.4` |
| `gt_10gbr_example_bit_sync.v` / `_reset_sync.v` | CDC 同步器 |

example 顶层的端口（对我们极友好）：

```verilog
module gt_10gbr_example_top (
  input  wire mgtrefclk0_x0y1_p, mgtrefclk0_x0y1_n,   // → V7/V6
  input  wire ch0_gtyrxn_in, ch0_gtyrxp_in,           // SFP A RX
  output wire ch0_gtytxn_out, ch0_gtytxp_out,         // SFP A TX
  input  wire ch1_gtyrxn_in, ch1_gtyrxp_in,           // SFP B RX
  output wire ch1_gtytxn_out, ch1_gtytxp_out,         // SFP B TX
  input  wire hb_gtwiz_reset_clk_freerun_in,
  input  wire hb_gtwiz_reset_all_in,
  input  wire link_down_latched_reset_in,             // 可当"开始计时"的控制脚
  output wire link_status_out,                        // PRBS 锁
  output reg  link_down_latched_out = 1'b1 );         // 粘滞
```

#### ⚠️⚠️ 本规格书里最重要的一条坑：example 的链路判据是**漏桶**，不是零误码判据

`gt_10gbr_example_top.v:466-505`（原文注释 + 代码）：

> "Implement an example link status state machine using a simple **leaky bucket** mechanism.
> The link status indicates the continual PRBS match status ... **while being tolerant of occasional bit errors**."

```verilog
ST_LINK_DOWN: if (prbs_error) link_ctr <= 0;                  // 需连续 67 拍无误码才上链
              else if (link_ctr < 67) link_ctr <= link_ctr+1; else sm_link <= ST_LINK_UP;
ST_LINK_UP  : if (prbs_error) begin
                  if (link_ctr > 33) begin
                      link_ctr <= link_ctr - 34;              // 一次错只扣 34（满分 67）
                      if (link_ctr == 34) sm_link <= ST_LINK_DOWN;
                  end else begin link_ctr <= 0; sm_link <= ST_LINK_DOWN; end
              end else if (link_ctr < 67) link_ctr <= link_ctr + 1;
```

⇒ **孤立单次误码会让 `link_ctr` 从 67 掉到 33；要连着两拍错才掉链。**
所以 **`link_down_latched_out == 0` 不能当"零误码"证据** —— 它会放过孤立误码。
这正好是本工程铁律①"空读数 ≠ 真 0"的同类陷阱。**BER 必须自己数**（见 §5）。

### 1.6 构建次数

| 项 | 次数 |
|---|---|
| P7a 主位流 | **1** |
| 负对照孪生位流（RAW，可选，见 §4.3） | +1 |
| 腿 1/腿 2 的 A/B 对照 | **0**（闸 0 已用 OOC 综合+布局做完，见 §4.1/§4.2） |
| 板前 license 负对照（§1.2 建议） | 0（只建工程）· ✅ **已执行（2026-09-29 复核更正）** = P7a 的 **P2j**，读数 `_proj_10g/reports/p7a_lic_deny_stdout.txt` |

---

## 2. 推荐的实现路线

### 2.1 路线 1（**推荐**）：wizard（10GBASE-R 64-bit, 2ch）+ 自己写外壳

- 用 §1.4 的原子配方建 wizard，`CHANNEL_ENABLE = {X0Y4 X0Y5}`（SFP A / SFP B）。
- **把 example design 的三个文件拷进自己的工程**（`prbs_any.v`、`stimulus_64b66b_async.v`、`checking_64b66b_async.v`），
  原样实例化 —— 它们已经处理好了 gearbox 的位序反转与滑位 hunt。
- **自己写 top**：加 §5.2 的三个计数器 + VIO 快照 + 复位/开始控制 + SFP 控制脚。
- **理由**：
  1. 判据完全可控（example 的 FSM 太钝，见 §1.5）；
  2. 不改 `.gen/` 里的自动生成物（重新 `generate_target` 会覆盖）；
  3. example 的 PRBS 三件套已经解决了两件麻烦事（gearbox 位序反转、滑位 hunt），白捡。

### 2.2 路线 2（备选，最省事但判据最弱）：直接把 `generate_target example` 出的工程当设计

- 只有 `link_status_out` / `link_down_latched_out` 两个观测，**给不出 BER 数**，只能给"漏桶没掉"。
- 只适合"先看看能不能通"的一次性冒烟测试，**不能用于 P7a 的验收判据**。

### 2.3 路线 3（不推荐）：`xxv_ethernet` 的 PCS/PMA-only

- ~~本工程已判定它的"standalone BASE-R 免费"是**文档级承诺、license manager 未实现**（`_lic/deny_stdout.txt` 实证）。~~
  ⚠️ **2026-09-29 复核更正：这句推理是错的，已作废。** `_lic/deny_stdout.txt` 是**在把 `Xilinx.lic`
  藏起来的状态下**测的（实测：`IS_LOCKED=1`、连 `CONFIG.*` 都改不了、0 个 RTL 落盘），
  在那种状态下**本来就该被锁** ⇒ 它不能证明"license manager 未实现"。**license 在位**时的实测是：
  `xxv_ethernet 5.0` 三种 CORE 配置 `IS_LOCKED` 全 0、`generate_target all` 产出完整 RTL
  （`_lic/prep_stdout.txt`，2026-09-27 phase A，**在本器件 KU5P 上**），且 `Xilinx.lic` 里本就有
  `INCREMENT xxv_eth_mac_pcs … permanent uncounted` ⇒ **PCS/PMA-only 这条路是可用的**，
  它被排除的理由只剩"会拖进 MAC/AXI 层次、判据不如路线 1 直接"（下一行），**不是** license。
- 而且会拖进 MAC/AXI 层次，判据反而不如路线 1 直接。
- **但它内部生成的那份 GT 实例是一份极有价值的黄金参照**（§1.3(c)）—— 用来对照参数，不用来当设计。

### 2.4 是否需要 example design？

| 用 | 不用 |
|---|---|
| ✅ **PRBS 三件套当零件**（省掉自己写图案器与 gearslip hunt，且它已按 64b66b 模式特化） | ❌ 不把 example 顶层当最终设计（判据太钝、且是自动生成物） |

---

## 3. fabric 侧接口（实测）

### 3.1 端口清单

来自 `_p7a_probe/pj_fin/p5_fin.gen/sources_1/ip/gt_10gbr/synth/gt_10gbr.v`（模块端口声明，原文）：

```
input  wire [0 : 0]     gtwiz_userclk_tx_reset_in;
output wire [0 : 0]     gtwiz_userclk_tx_srcclk_out;
output wire [0 : 0]     gtwiz_userclk_tx_usrclk_out;
output wire [0 : 0]     gtwiz_userclk_tx_usrclk2_out;      <-- ★ TX fabric 时钟
output wire [0 : 0]     gtwiz_userclk_tx_active_out;
input  wire [0 : 0]     gtwiz_userclk_rx_reset_in;
output wire [0 : 0]     gtwiz_userclk_rx_srcclk_out;
output wire [0 : 0]     gtwiz_userclk_rx_usrclk_out;
output wire [0 : 0]     gtwiz_userclk_rx_usrclk2_out;      <-- ★ RX fabric 时钟（恢复时钟域）
output wire [0 : 0]     gtwiz_userclk_rx_active_out;
input  wire [0 : 0]     gtwiz_reset_clk_freerun_in;        <-- 156.25 MHz 自由跑时钟
input  wire [0 : 0]     gtwiz_reset_all_in;
input  wire [0 : 0]     gtwiz_reset_tx_pll_and_datapath_in;
input  wire [0 : 0]     gtwiz_reset_tx_datapath_in;
input  wire [0 : 0]     gtwiz_reset_rx_pll_and_datapath_in;
input  wire [0 : 0]     gtwiz_reset_rx_datapath_in;
output wire [0 : 0]     gtwiz_reset_rx_cdr_stable_out;
output wire [0 : 0]     gtwiz_reset_tx_done_out;
output wire [0 : 0]     gtwiz_reset_rx_done_out;
input  wire [127 : 0]   gtwiz_userdata_tx_in;              <-- ★ 2ch × 64 bit
output wire [127 : 0]   gtwiz_userdata_rx_out;
input  wire [0 : 0]     gtrefclk00_in;                     <-- → V7/V6
output wire [0 : 0]     qpll0outclk_out; qpll0outrefclk_out;
input  wire [1 : 0]     gtyrxn_in;  gtyrxp_in;
output wire [1 : 0]     gtytxn_out; gtytxp_out;
input  wire [1 : 0]     rxgearboxslip_in;                  <-- ★ gearbox 滑位（负对照要用）
input  wire [11 : 0]    txheader_in;                       <-- ★ 2ch × 6bit TX 同步头
input  wire [13 : 0]    txsequence_in;
output wire [1 : 0]     gtpowergood_out;
output wire [3 : 0]     rxdatavalid_out;                   <-- 2ch × 2bit
output wire [11 : 0]    rxheader_out;                      <-- ★ 2ch × 6bit RX 同步头
output wire [3 : 0]     rxheadervalid_out;                 <-- ★ 2ch × 2bit
output wire [1 : 0]     rxpmaresetdone_out; rxprgdivresetdone_out; txpmaresetdone_out; txprgdivresetdone_out;
output wire [3 : 0]     rxstartofseq_out;
```

**本配置下没有**：`rxslide_in`、DRP 端口、`gtrefclk01_in`（因为 `LOCATE_COMMON=CORE` 只带一路 refclk）。

### 3.2 位宽与时钟（**实测**，不是预期）

来自 `gt_10gbr.v` 实例化处（原文）：

```
C_TX_USER_DATA_WIDTH                       = 64
C_TX_INT_DATA_WIDTH                        = 64
C_TX_USRCLK_FREQUENCY                      = 156.2500000
C_TX_USRCLK2_FREQUENCY                     = 156.2500000
C_TX_OUTCLK_FREQUENCY                      = 156.2500000
C_TX_USER_CLOCKING_RATIO_FUSRCLK_FUSRCLK2  = 1
C_RX_USRCLK_FREQUENCY                      = 156.2500000
C_RX_USRCLK2_FREQUENCY                     = 156.2500000
C_RX_OUTCLK_FREQUENCY                      = 156.2500000
C_TXPROGDIV_FREQ_VAL                       = 156.25
C_TX_MASTER_CHANNEL_IDX                    = 4
```

⇒ **64 bit/ch @ 156.25 MHz**，`USRCLK2 == USRCLK`（ratio=1），**不是** 66bit、也**不是** 32bit@312.5MHz。
（对照：32-bit 内部宽度的配置会是 32bit@322.265625 MHz —— `C_RX_OUTCLK_FREQUENCY=322.2656250`，
见 `_probe2/.../eth10g_macpcs64_gt.xci`。）

### 3.3 复位

- `LOCATE_RESET_CONTROLLER = CORE` ⇒ **reset controller 在 IP 里**，外部只需给
  `gtwiz_reset_clk_freerun_in`（156.25 MHz）+ `gtwiz_reset_all_in`，然后等
  `gtwiz_reset_tx_done_out` / `gtwiz_reset_rx_done_out`。
- example design 的做法（`gt_10gbr_example_init.v`）可以直接抄。

### 3.4 ⚠️ `txheader_in` 是 fabric 侧最容易漏的一根线

64b66b 模式下 **TX 必须给数据块的同步头**。example 给的是**常量 `6'b000001`**
（`gt_10gbr_example_stimulus_64b66b_async.v`：`assign txheader_out = 6'b000001;`）。
不接（=0）时 TX 会发 `00` 同步头 ⇒ 接收端不认作数据块。

---

## 4. ⭐ gearbox 在通路里的正证据方案

### 4.0 为什么 fabric 侧 PRBS 不够

两种模式下 fabric 数据都是**透明**的：`gtwiz_userdata_tx_in` 的 64 bit 在 raw 与 gearbox 下都会被原样送出、
在 RX 侧原样收回（gearbox 只是在中途插入/剥掉 2 bit 同步头）。**所以 PRBS 通了不能证明 gearbox 在跑。**

而且：**`rxheader_out` / `rxheadervalid_out` 这两个端口在 RAW 构建里也存在**（实测：`rb_raw` 与 `rb_pos` 的
channel wrapper 都在**同样的行号** 347/348 有 `GTYE4_CHANNEL_RXHEADER` / `GTYE4_CHANNEL_RXHEADERVALID`）
⇒ **"端口在不在"不是判据**。

⇒ 判据必须落在**原语属性**、**时钟频率**、**gearbox 独有行为**这三处。

### 4.1 腿 1 —— 布局后回读原语属性（静态，无板）★ 首选

**Tcl（跑在实现后的 design 上）：**

```tcl
open_run impl_1          ; # 或 open_checkpoint <routed.dcp>
foreach c [get_cells -hier -filter {REF_NAME =~ GTYE4_CHANNEL*}] {
    puts "$c GEARBOX_MODE=[get_property GEARBOX_MODE $c] \
             TXGEARBOX_EN=[get_property TXGEARBOX_EN $c] \
             RXGEARBOX_EN=[get_property RXGEARBOX_EN $c] \
             TX_DATA_WIDTH=[get_property TX_DATA_WIDTH $c]"
}
```

**闸 0 实测结果**（`_p7a_probe/p7_stdout.txt`，两个构建都跑了 OOC 综合 **+ `place_design` rc=0**）：

| 读回项 | 10GBASE-R 构建 | **RAW 构建（负对照）** |
|---|---|---|
| `GEARBOX_MODE` | `5'b10001` | `5'b00000` |
| `TXGEARBOX_EN` | `TRUE` | `FALSE` |
| `RXGEARBOX_EN` | `TRUE` | `FALSE` |
| `TX_DATA_WIDTH` | `64` | `64` |
| `RX_DATA_WIDTH` | `64` | `64` |

- **合成后（POST_SYNTH）与布局后（POST_PLACE）读数完全一致** ⇒ "要能在**布局后**从网表里读回来"这条成立（实测，不是推断）。
- **写出的网表文本里同样可读**（`nl_pos.v` / `nl_raw.v`）：
  ```
  pos:  2 × .GEARBOX_MODE(5'b10001)   2 × .TXGEARBOX_EN("TRUE")   2 × .RXGEARBOX_EN("TRUE")
  raw:  2 × .GEARBOX_MODE(5'b00000)   2 × .TXGEARBOX_EN("FALSE")  2 × .RXGEARBOX_EN("FALSE")
  ```
- ⇒ **判据有区分能力，已证**（不是"设计正确性"，是"读数能分辨"）。

### 4.2 腿 2 —— fabric 时钟频率（静态，无板）★ 最便宜、最有说服力

`CONFIG.TXPROGDIV_FREQ_VAL`（闸 0 实测，`p7_stdout.txt`）：

| | 10GBASE-R 构建 | RAW 构建（负对照） |
|---|---|---|
| `TXPROGDIV_FREQ_VAL` | **156.25 MHz** | **161.1328125 MHz** |

- `10.3125e9 / 66 = 156.25e6`；`10.3125e9 / 64 = 161.1328125e6`。**两个数恰好就是这两个除法。**
- **为什么这能证明 gearbox 在通路里**：64 bit × 156.25 MHz = **10.0 Gbit/s 净荷**，
  而线速率是 **10.3125 Gbaud**。差的 3.125% = **2/64**，
  **唯一能补上这 2 bit 的就是 64b/66b gearbox**。若 gearbox 不在通路，fabric 侧必然是 161.1328125 MHz。
- 这条还能升级成**上板可测的独立观测**（见 §5.4 的可选加强项）。

### 4.3 腿 3 —— 功能判据 + 负对照（上板）

**正证据：**
1. `link_status_out` 拉高（PRBS31 锁住）；**同时** `link_down_latched` 从未置位（弱，因为漏桶，见 §1.5）；
2. ⭐ **`rxheader_out` 在 `rxheadervalid_out` 有效的每一拍等于同一个常量**。
   TX 端 example 送常量 `6'b000001`，链路锁住后 RX 侧应当稳定复现。
   - ⚠️ 我**没有解码** 6-bit `RXHEADER` 的字段含义（见 §9.2），所以判据写成"**稳定性**"而不是"等于某个具体值"：
     先在锁住后采样 N 拍记录唯一值，再统计偏离数（= `hdr_err_cnt`，见 §5.2）。

**负对照 A（上板，0 额外构建）：脉冲 `rxgearboxslip_in`。**
- 从 VIO 打一拍 `rxgearboxslip` ⇒ **`link_status_out` 必须掉，然后重新锁上**。
- **判据的区分逻辑**：raw 构建里根本没有 gearbox 可滑，这个动作**没有意义**（滑不动/无效）。
  ⇒ 只有 gearbox 在位才可能"滑一下就断、再滑回来"。
- ⚠️ 注意：example 的 checking 模块**自己就会**在 `!prbs_match_out` 时周期性脉冲 `rxgearboxslip`
  （位序 hunt）。所以观测时要**区分"hunt 造成的滑"和"我打的滑"** —— 建议在 `link_status_out` 稳定后
  再打滑，并观察 `link_status_out` 的下降沿计数。

**负对照 B（上板，1 额外构建，可选）：RAW 孪生位流。**
- 只改 `TX_DATA_ENCODING/RX_DATA_DECODING = RAW`，其余完全相同。
- **期望**：PRBS **永远锁不上**（raw 64-bit 通路没有位对齐机制，收到的 PRBS 是任意位旋转，
  而 `prbs_any` 无 slip 能力 ⇒ 永久失配）。
- **但它只是加分项**：若因某种巧合锁上了，这条负对照就失效。
  ⇒ **不能把验收建立在它上面**；主证据是腿 1 + 腿 2 + 负对照 A。

### 4.4 ⚠️ 避免"判据循环"

**不要**只看 `TXGEARBOX_EN=TRUE` 就宣称"gearbox 真的在通路里跑" —— 属性是**配置**，不是**运行**。
验收必须 **腿 1 ∧ 腿 2 ∧ 腿 3** 同时成立：

| 腿 | 证明了什么 |
|---|---|
| 1 | 硬件被配置成 64b/66b（不是 raw） |
| 2 | fabric 接口是**66/64 速率**的接口 ⇒ 必须有 gearbox 才能与 10.3125 Gbaud 对账 |
| 3 | 该配置下 PRBS 真的通了、且 gearbox 独有行为（滑位）可观测 |

---

## 5. BER 测量方案

### 5.1 图案与校验语义（读源码得来，不要凭记忆）

- 图案：**PRBS31**，`prbs_any #(CHK_MODE=1, INV_PATTERN=1, POLY_LENGHT=31, POLY_TAP=28, NBITS=64)`，每通道独立。
- `gt_10gbr_prbs_any.v:170-190` 的关键一行（工具原文）：
  ```verilog
  assign prbs_msb[I+1] = CHK_MODE == 0 ? prbs_xor_a[I] : data_in_i[I];   // 校验模式：LFSR 用收到数据重新播种
  assign prbs_xor_b[I] = prbs_xor_a[I] ^ data_in_i[I];
  DATA_OUT <= prbs_xor_b;
  ```
  ⇒ **LFSR 用收到的数据重新播种**，`DATA_OUT = 收到 ^ 期望`。
  - **单个位错只污染一个字**，之后自动恢复（⇒ "错字数"是干净的孤立错误计）；
  - **位旋转（错位）会让所有字永久失配**（⇒ "锁不上"专指错位，这正是 `rxgearboxslip` hunt 要解决的）。
- `prbs_match_out <= ~(|error_vector)`（`checking` 模块），每拍重新评估。

### 5.2 计数器（**必须自己加**，example 不带任何计数器）

| 信号 | 域 | 含义 |
|---|---|---|
| `err_word_cnt[ch]` | `rx_usrclk2` | `!prbs_match_out` 时 +1（宽 32 bit 够；保守可 48） |
| `bits_cnt[ch]` | `rx_usrclk2` | `link_status`（或 `rxdatavalid`）有效时 +64 |
| `hdr_err_cnt[ch]` | `rx_usrclk2` | `rxheadervalid` 有效且 `rxheader` ≠ 记录常量时 +1（补同步头覆盖，见 §8/R3） |
| `snap_*` | 同上 | **原子快照寄存器**：VIO `probe_out` 一个脉冲把三个计数器**同时**打进快照 |

⚠️ **快照是必须的**：多比特计数器在 JTAG 读的瞬间会翻滚（**"空读数 ≠ 真 0"的同类陷阱**）。
`_proj_mdio` 里那个 16 bit 只读寄存器没这个问题，**计数器有**。
⚠️ 另需一根 VIO 输出的"清零/开始"脉冲（**必须自加边沿检测**：JTAG 一次提交几十 ms vs 一次事务几十 µs）。

### 5.3 观测通道 = **VIO over JTAG**（复用 `_proj_mdio/probe_phy.tcl` 的配方）

**为什么不用 PCIe**：本板 PCIe 端点只认"FPGA 配置先于主机 POST"，主机开机时若 FPGA 跑的是无 PCIe 的设计，
根端口直接放弃链路，事后补烧救不回来（四种主机侧手段实测全无效，见 `udp_hls_10g/CLAUDE.md`）。
⇒ 每次观测都要重烧 + 重启主机。**VIO 不用重启，几十 ms 一次事务，读计数器绰绰有余。**

**VIO 打包建议**（探针名 = RTL 连接的网络名，见 `_proj_mdio/probe_phy.tcl` 头注释的五个坑）：

```
probe_in0 [64]  {err_word_cnt_ch1, err_word_cnt_ch0}   (或拆成两个 32 bit 探针)
probe_in1 [64]  {bits_cnt_ch1, bits_cnt_ch0}
probe_in2 [16]  {hdr_err_cnt_ch1, hdr_err_cnt_ch0}
probe_in3 [16]  {link_status_out, link_down_latched_out, reset_done, gtpowergood, sfp*_rx_los, ...}
probe_out0 [1]  snapshot_pulse      (边沿检测)
probe_out1 [1]  counter_clear_pulse (边沿检测)
probe_out2 [1]  rxgearboxslip_pulse (负对照 A)
probe_out3 [1]  link_down_latched_reset_pulse
```

⚠️ **`C_CLK_INPUT_FREQ_HZ`**：VIO 的 `clk` 用 156.25 MHz，要按 `_ibert/constr/ibert_top.xdc` 的写法给 `dbg_hub` 设：

```tcl
set_property C_CLK_INPUT_FREQ_HZ 156250000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER true [get_debug_cores dbg_hub]
```

### 5.4 判定门限与"跑多久才算够"

- 统计：0 错观察 B bit ⇒ BER 的 95% 置信上界 ≈ **3/B**。
- 目标 **BER < 1e-12** ⇒ **B ≥ 3×10¹² bit**；fabric 净荷 10.0 Gbit/s ⇒ **≥ 300 s**。
- **建议门限：连续 10 分钟（≈ 6×10¹² bit）零错** ⇒ BER < **5×10⁻¹³**（95% CL，相对 1e-12 有 2× 余量）。
- ⚠️ **正证据不可省（铁律①）**：同一次读数里必须同时满足
  1. `bits_cnt ≠ 0`；
  2. `bits_cnt / 实测秒数 ≈ 1.0×10¹⁰ ± 0.1%`（**可独立复算**）；
  3. `bits_cnt` 与 `err_word_cnt` 的**两通道都要**读（双向：X0Y4→AOC→X0Y5 与 X0Y5→AOC→X0Y4）。
  否则"0 错"可能只是计数器没在跑。

**可选加强项（把腿 2 变成上板可测的独立观测）**：
在 fabric 里放两个自由跑计数器，一个由 `rx_usrclk2` 驱动、一个由板上的 **100 MHz `SYS_CLK`**
（Y1 差分晶振 → `SYS_CLK_P/N` = T25/U25，bank 65）驱动，在固定的 freerun 窗口内比比值：
- gearbox 下 `rx_usrclk2 / 100MHz = 156.25/100 = 25/16`；
- raw 下 = `161.1328125/100 = 33/20.48`（≈1.611328125）。
⇒ **两个都是精确有理数，比率可精确判别**。这比读 `TXPROGDIV_FREQ_VAL`（构建期属性）更强，是**运行期**证据。
代价：需要把 100 MHz 时钟引入 fabric（板上已有）+ 两个计数器 + VIO。**列为可选**。

### 5.5 归因分界（用 iBERT 先验）★

**物理前提已确认**（来源：**用户 2026-09-29 确认**）：
两个 SFP28 模块 + AOC 环回线**仍在板上、未动**，与 2026-09-27 iBERT 那一轮**完全相同**。

**先验基线（直接适用于这条链路）**：同板同线（SFP A ↔ SFP B 经 AOC 外部环回）在 2026-09-27
已测到 **BER < 2.4×10⁻¹²（双向各 1.239 Tbit 零错误）**，优于 10GBASE-R 的 1e-12 要求
⇒ **模拟链路本身（FPGA 球 → 核心板 → 板对板连接器 → 底板 → SFP 笼 → 模块 → AOC → 返回）已达要求。**

⇒ **归因分界**：
- 若 P7a 测到**明显更差**（1e-10 量级、或根本锁不上）⇒ 差异**首先归因到 gearbox/PCS 这一层**，
  **不是**模拟链路。这是本轮最有用的分界线。
- 若 P7a 也到 <1e-12 ⇒ "**这块板能做 10G（含 PCS/gearbox）**"这句话**第一次被完整证明**。

⚠️ 一处口径差异要写清楚：iBERT 那轮测的是 **GT 层（raw，无 gearbox）** 的 BER；
P7a 测的是 **fabric 净荷**的 BER。两者的关系是"净荷 BER ≈ 线路 BER × (64/66 的放大)"——
量级一致，但**不是同一个测点**，对比时不要当成同一件事。

---

## 6. 引脚 / 时钟约束清单

**用本工程已实测更正过的版本，不要再抄厂商 XDC。**

```tcl
# ============================================================ GT 参考时钟
# 核心板差分有源晶振（丝印位号 Y2）已换成 156.25 MHz → 网络 MGT225_CLK0_P/N → ball V7/V6
# wizard 生成 example design 时**已经**写好了下面两行（因为 quad 225 的 common 是 GTYE4_COMMON_X0Y1）
set_property PACKAGE_PIN V7 [get_ports mgtrefclk0_x0y1_p]      ; # MGTREFCLK0_225
set_property PACKAGE_PIN V6 [get_ports mgtrefclk0_x0y1_n]
create_clock -name clk_mgtrefclk0_x0y1_p -period 6.400 [get_ports mgtrefclk0_x0y1_p]
create_clock -name clk_freerun           -period 6.400 [get_ports hb_gtwiz_reset_clk_freerun_in]

# ============================================================ GT 串行脚：**不用手写**
# wizard 自带 XDC 有：set_property LOC GTYE4_CHANNEL_X0Y4 / X0Y5 [get_cells ...GTYE4_CHANNEL_PRIM_INST]
# 串行脚由 channel LOC 自动推导 —— 依据：iBERT 工程的 XDC **只有 refclk 的 PACKAGE_PIN**，
# 没有 GT 串行脚的 PACKAGE_PIN，而它跑通了（_ibert/ibert_ku5p/.../ibert_ku5p_0.xdc:45-49）
#   set_property LOC GTYE4_CHANNEL_X0Y4 [get_cells QUAD0.u_q/CH[0].u_ch/u_gtye4_channel]
#   set_property LOC GTYE4_COMMON_X0Y1  [get_cells QUAD0.u_q/u_common/u_gtye4_common]

# ============================================================ ⚠️ SFP 控制脚（厂商两份 XDC 都错）
# 三态判别实验定案（2026-09-27）：
#   v1 只驱动 B11/C9 低  -> 4 个 GT 全黑（RX_BER 0.50）
#   v2 四脚全驱动低      -> 链路立起，未接线通道仍是 0.49（完美对照）
#   v3 只驱动 C11/D9 低  -> 链路依然立起
#   => TX_DIS 在 C11 / D9；RX_LOS 在 B11 / C9。厂商把每对脚 P/N 对调了。
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sfp1_tx_dis]   ; # ★ 必须驱动 **低**
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports sfp2_tx_dis]   ; # ★ 必须驱动 **低**
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp1_rx_los]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp2_rx_los]

# ============================================================ debug hub
set_property C_CLK_INPUT_FREQ_HZ 156250000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER true      [get_debug_cores dbg_hub]
```

### ⚠️ 必须记住的四条

1. ⚠️⚠️ **`SFP1_TX_DIS = C11` / `SFP2_TX_DIS = D9` 必须显式驱动低。**
   悬空被 10k 上拉拉高 ⇒ **光模块发射永久关断** ⇒ 现象是"**两方向全黑**"，
   **极易被误判成"板子做不了 10G"**。这是本板最难查的一类假故障。
2. ⚠️ **命名陷阱**：XDC 里的 `Y2` 是 **ball 编号**（SFP A 的 RX+），与**晶振位号 Y2** 不是一回事；
   同一份厂商 `PCIe.xdc` 里二者相邻出现（`gt_refclk1_P = V7` 与 `aurora_rxp[0] = Y2`），极易混淆。
3. ⚠️ **quad / refclk 站点命名**：quad 225 的 common 是 `GTYE4_COMMON_X0Y1`，
   所以 wizard 生成的 refclk 端口叫 `mgtrefclk0_x0y1_p/n` —— **这个 `x0y1` 是 common 站点号，不是 channel 号**
   （channel 是 X0Y4/X0Y5）。wizard 已经把它生成成 V7/V6 了，**别改**。
4. **通道映射**：SFP A = quad 225 ch0 = **X0Y4**；SFP B = quad 225 ch1 = **X0Y5**
   （iBERT `_ibert/m2_loopback.tcl:133-134` 实测：`gtA (SFP A, X0Y4)` / `gtB (SFP B, X0Y5)`）
   ⇒ **外部环回是 X0Y4 ↔ X0Y5**。

### 与 `_ibert/constr/ibert_top.xdc` 的一致性核对

| 项 | `_ibert` | 本规格书 | 结论 |
|---|---|---|---|
| `gt_refclk0_P/N` 引脚 | V7 / V6 | V7 / V6 | ✅ 一致 |
| refclk 周期 | `6.400` | `6.400` | ✅ 一致 |
| `SFP1_TX_DIS` | C11 | C11 | ✅ 一致 |
| `SFP1_RX_LOS` | B11 | B11 | ✅ 一致 |
| `SFP2_TX_DIS` | D9 | D9 | ✅ 一致 |
| `SFP2_RX_LOS` | C9 | C9 | ✅ 一致 |
| `dbg_hub C_CLK_INPUT_FREQ_HZ` | 156250000 | 156250000 | ✅ 一致 |

**无冲突。** （`_ibert` 的 v1/v2/v3 三版 XDC 中 v3 与 `constr/ibert_top.xdc` 逐字节相同 —— 已在闸 0 用 `diff` 核对。）

---

## 7. 复用清单（别重造）

### `D:\repo\XCKU5PMini\_ibert\`（本板已跑通的 GT 工程）

| 可复用 | 内容 |
|---|---|
| `constr/ibert_top.xdc` | refclk 引脚/周期（V7/V6 @6.400）、**SFP 四脚（含 PULLUP 与"厂商两份 XDC 都错"的理由注释）**、`dbg_hub C_CLK_INPUT_FREQ_HZ` —— **直接抄** |
| `m2_loopback.tcl:133-134` | X0Y4/X0Y5 = SFP A/B 的**实测**映射 |
| `m1_program.tcl` | **烧录安全闸**：IDCODE `04A62093` + 设备数 = 1 才烧；`REGISTER.CONFIG_STATUS.BIT[14]_DONE_PIN` 判 DONE；VIO 心跳自检。P7a 的烧录脚本只需把 `connect_hw_server` 改成 `connect_hw_server -url 192.168.0.38:3121` |
| `m1.bat` | bat 写法（`-mode batch -source ... -log ... -journal ...`） |

**不可复用**：iBERT 的协议配置 —— `C_PROTOCOL_QUAD1 = "Custom_1_/_10.3125_Gbps"`、
`C_PROTOCOL_DATAWIDTH_1 = 80`、实测 `TXGEARBOX_EN=FALSE`。**那正是 P7a 要取代的东西。**
iBERT 的观测方式（`get_hw_sio_gts` 读 `RX_BER` / `RX_RECEIVED_BIT_COUNT`）P7a **用不上**（我们不用 IBERT IP），
但"用 JTAG 读计数器"这个形态是一致的。

### `D:\repo\XCKU5PMini\_proj_mdio\`（本工程已验证的 VIO over JTAG 配方）

| 可复用 | 内容 |
|---|---|
| `probe_phy.tcl` 头注释 | **五个 API 坑**：① `.ltx` 必须挂到 hw_device，否则 `get_hw_probes` 返回空 + `[Labtools 27-1974]`；② **探针名 = 连接的网络名**（不是 `probe_outN`）；③ `refresh_hw_vio`/`commit_hw_vio` 传 **core 不传探针**（否则 `[Labtoolstcl 44-186]`）；④ `INPUT_VALUE` 是**该探针 radix 的字符串**（默认 HEX，`"c0000"` 不是数）；⑤ `OUTPUT_VALUE` 要按 radix **补足位宽**（5-bit @HEX 要 2 字符，否则 `[Designutils 20-1474]`） |
| `build_mdio.tcl` | `create_ip -name vio` + `CONFIG.C_NUM_PROBE_IN/C_PROBE_IN0_WIDTH/...` 的打包写法；工程创建 + 时序报告骨架 |
| `probe_phy.tcl` 的 `vset`/`vget`/`findprobe` 三个 proc | 直接抄 |

⚠️ **两个必须自己补的**：
1. 读**多比特计数器**要加**原子快照**寄存器（§5.2）—— `_proj_mdio` 的 16 bit 只读寄存器没这个问题；
2. **脉冲型控制**（`rxgearboxslip`、计数器清零、`link_down_latched_reset`）**必须自加边沿检测**
   （JTAG 一次提交几十 ms vs 一次事务几十 µs）。

### wizard 自带（`generate_target example`）

- `gt_10gbr_prbs_any.v` —— XAPP884 PRBS 核（PRBS31 / 64 bit）
- `gt_10gbr_example_stimulus_64b66b_async.v` / `gt_10gbr_example_checking_64b66b_async.v`
  —— PRBS 收发生 + **gearbox 位序反转** + **`rxgearboxslip` hunt**（这两件是最容易自己写错的）
- `gt_10gbr_example_bit_sync.v` / `_reset_sync.v` —— CDC 同步器
- `gt_10gbr_example_top.xdc` —— refclk 引脚/时钟约束
- `gt_10gbr_example_top.v` 里的 VIO 打包（`probe_in0/1`）可作起点

### `udp_hls_10g/board/` 现有工程

- `build_p6a_ku5p.tcl` 的工程创建 + `report_timing_summary` + WNS/WHS 打印骨架
- KU5P 的 `create_project -force ... -part xcku5p-ffvb676-1-e` 流程

---

## 8. 风险表

| # | 风险 | 现象 | 早期信号 | 缓解 | 验证手段 |
|---|---|---|---|---|---|
| **R1** | ~~**"免 license"未直证**~~ ⇒ ✅ **已闭（2026-09-29 复核更正）** | 换机/升级后被 design_linking 锁 | `IS_LOCKED=1`；`USED_LICENSE_KEYS` 出现 `xxv_eth_mac_pcs@... design_linking` | **已执行**：藏 license 负对照通过（gtwizard 仍 `IS_LOCKED=0`/`USED_LICENSE_KEYS=<>`/7 个 RTL 落盘），恢复已核对 MD5 ⇒ **"gtwizard 免 license"成立**（§1.2 末 / `P7A_RESULT.md` §3.4） | `_proj_10g/reports/p7a_lic_deny_stdout.txt`（P2j） |
| **R2** | ⭐ **`link_down_latched==0` 被误当零误码** | **漏桶**容忍孤立错误（一次错只扣 34/67）⇒ 结论虚高 | 单次错后 `link_ctr` 67→33 但不掉链 | **自己加 `err_word_cnt`**，判据**不用** example 的 FSM | 计数器与 `bits_cnt` 对账（§5.4） |
| **R3** | **同步头 2 bit/66 不被 fabric PRBS 覆盖** | gearbox 头位错误在净荷里不可见 | `hdr_err_cnt > 0` 而 `err_word_cnt == 0` | 加 `hdr_err_cnt`（`rxheadervalid && rxheader ≠ 常量`） | ⚠️ 机理**未确证**（§9.5）—— 先测出来再说 |
| **R4** | ⚠️⚠️ **`TX_DIS` 悬空** | 两方向全黑，**误判成"板子做不了 10G"** | `link_status_out` 恒低；`rxpmaresetdone` 正常但 PRBS 永不锁 | **显式驱动 C11/D9 低** | 三态实验已定案；P7a 里同时读 `sfp{1,2}_rx_los` |
| **R5** | **AOC 环回接反/松动** | 一通道锁另一通道不锁，或全黑 | 单向通 | 用 iBERT 那轮同一条 AOC（用户 2026-09-29 确认仍在位） | 与 iBERT 先验对照（§5.5） |
| **R6** | **参数设不下去**（顺序陷阱） | 构建脚本报 `19-3461`/`19-3478`，配置静默回默认 | `TX_INT_DATA_WIDTH` 落到 32；`REFCLK_FREQUENCY` 落到 64.453125 | 严格按 §1.4 顺序；**两个 refclk 频率原子设** | 构建脚本里**回读并断言**每个 `EFF` 参数（§1.4 末） |
| **R7** | **VIO 读多比特计数器撕裂** | 计数器读数偶尔离谱、不重复 | `bits_cnt` 与理论值偏离很大 | **原子快照寄存器** | 连读 3 次应一致 + 与秒数对账 |
| **R8** | **`rxgearboxslip` 从未滑到位** | PRBS 永不锁，但 GT 一切正常 | `link_status_out` 恒低、`rxdatavalid` 有活动 | example 的自动 hunt 已覆盖；VIO 手动滑作后备 | 读 hunt 计数器 / `rxsliderdy_out` |
| **R9** | **156.25 MHz 域时序** | 净荷偶发出错 | 实现后时序报告 | 闸 G 已证 KU5P @6.4 ns 数据面 WNS +0.426 / 0 fail；本例逻辑更少 | `report_timing_summary`，要求 **0 失败端点** |
| **R10** | **把 example 生成物当源码改** | 重新 `generate_target` 后改动被覆盖 | — | 只把 example 的 3 个 `.v` **拷进自己工程**，**不改 `.gen/`** | 构建脚本引用自己目录下的副本 |
| **R11** | ⭐ **判据循环**：只看 `GEARBOX_EN=TRUE` 就宣称"gearbox 在通路里" | 属性真但 datapath 没跑 | — | 腿 1 **∧** 腿 2 **∧** 腿 3 同时满足（§4.4） | §4 三条腿 |
| **R12** | **物理前提变化** | 模块/AOC 被拔 | 全黑 | 已由用户确认在位（2026-09-29） | ⚠️ **本阶段未用 RX_LOS 复核**（不烧板）；下一阶段首步读 `sfp{1,2}_rx_los` |
| **R13** | **`TX_OUTCLK_SOURCE` 选错源** | 用户时钟频率不对 ⇒ `usrclk2` 频率与 156.25 不符 | 实现时 `create_clock` 冲突 / 时序全红 | 保守取与黄金参照一致的值（`C_TX_OUTCLK_SOURCE=4`，见 §1.3(c)） | 回读 `C_TX_USRCLK2_FREQUENCY`（应为 156.25） |

---

## 9. 我没确证的（诚实列出）

1. ~~**"gtwizard 免 license"没有被直接证明。**~~ ⚠️ **2026-09-29 复核更正：已补做并直证。**
   当时只证了"license 在位时 `IS_LOCKED=0` / `USED_LICENSE_KEYS` 空"；缺的那条负对照（把 `Xilinx.lic`
   藏掉后 gtwizard 仍干净）**已在 P7a 的 P2j 补做并通过**：`IS_LOCKED=0` / `LOCK_DETAILS = IP is not locked` /
   `USED_LICENSE_KEYS = <>` / `generate_target all rc=0` / 7 个 RTL 落盘，恢复已核对 MD5
   （`_proj_10g/reports/p7a_lic_deny_stdout.txt` + `p7a_lic_deny_state.txt`）。⇒ **"gtwizard 免 license"成立。**
   ⚠️ **同时纠正一处被误延伸的推理**：同轮 `xxv_ethernet` 被 `design_linking` 锁是"**藏了 license**"的
   直接后果（`_lic/deny_stdout.txt` 本身就是在藏 license 的状态下测的），**不能**反推"`xxv_ethernet`
   平时锁着 / 要另买 license"。license 在位时它在 **KU5P** 上是 `IS_LOCKED=0` + 完整 RTL
   （`_lic/prep_stdout.txt`）；详见 §1.2 末与 §2.3 的复核更正。
   （`_lic/syn_stdout.txt` 那次综合实验建在 **Kintex-7 `xc7k70tfbv676-1`**，**对 KU5P 无权威性**，
   只可用来读"缺 license 的失败形态 = 综合期硬失败"这一条。）
2. **`RXHEADER[5:0]` 的字段编码没解码**（本地没查到 UG578 的对应表）。所以 §4.3 的判据写成"**稳定性**"
   而不是"等于某个具体值"。
3. **RAW 构建里 `rxheader_out`/`rxheadervalid_out` 的实际运行值未知。** 只确证了**端口存在**
   （两个 wrapper 同样有 `RXHEADER`/`RXHEADERVALID`，行号一致）⇒ "读 header 能不能当独立判据"要上板才知道。
4. **GTY RX gearbox 是否用同步头做自动对齐未确证。** example 的注释暗示它靠软逻辑 `rxgearboxslip` 手动 hunt，
   但我没读 UG578 确认。
5. **同步头位错误是否会在 fabric 净荷里消失（R3 的机理）未确证。**
6. **`txheader_in` 在 64-bit 内部宽度下 6 bit 的逐位含义未确证**；只知道 example 送常量 `6'b000001`。
7. **example design 的完整工程能否直接实现出位流没试** —— 本阶段只到 OOC 综合 + 布局，**没跑 `launch_runs` 全流程**。
8. **`C_TX_OUTCLK_SOURCE` 取 `TXPROGDIVCLK` 是否最优未对照。** 我的原子配置被工具接受并存成 `4`
   （与 `xxv_ethernet` 黄金参照的 `C_TX_OUTCLK_SOURCE=4` 一致），但我没单独验证"换别的源会怎样"。
9. **p3 里"`RX_REFCLK_SOURCE` 设了但校验仍读 `clk1`"那个现象**在 p5（原子设）里没有再出现
   ⇒ 可能只是**逐条设**的副作用，但我**没有单独复现确认**。
10. **两个 SFP28 模块 + AOC 的物理在位**由**用户 2026-09-29 口头确认**（与 2026-09-27 iBERT 那轮相同）；
    **我没有用自己的仪器复核**（本阶段不烧板）。
11. **`hdr_err` / 同步头计数器 + `bits_cnt` 的实现代价（LUT/FF、对 156.25 MHz 时序的影响）未评估** ——
    只做了 GT IP 的 OOC 综合，没做**含计数器**的整设计综合。
12. **`rxdatavalid_out` 在锁住后的实际占空比未确证**（我只知道它是 2 bit/ch）。`bits_cnt` 若用
    `rxdatavalid` 当使能，必须先实测它的行为；保守做法是用 `link_status` 当使能。
13. ⭐ **范围限定：本轮的图案是"未加扰"的 PRBS31**（2026-09-29 复核补记）—— 已确证 **GT 不做
    802.3 加扰**（58 位加扰器在 **soft logic**：`eth_phy_10g_tx_if.v:135-149`；
    UG576 原文 "Scrambling of the data is done in the interconnect logic"，
    `_proj_10g/notes/P7B_BASER_TABLES.md:341`；我方 `_proj_10g/tcl/build_p7a.tcl` 与生成 IP
    **零命中 `scrambl`**，`P7B_LIB_SURVEY.md:828`）⇒ **GT 是纯 gearbox + PMA**。
    ⇒ **P7a 证明了"这条物理通路能跑 10.3125 GBd"，没有证明"802.3 的加扰 + PCS 能跑"。**
    （物理层结论不受影响：PRBS31 与加扰后的 64b/66b 都是宽带近直流平衡。）
    该待办与两个决定性实验（**E2/E3**）已写在 `_proj_10g/notes/P7B_PHY_IFACE.md` §10.2 **U2** —— 本处只交叉引用。

---

## 10. 本阶段产生的文件（都在 `udp_hls_10g/_p7a_probe/`）

> ⚠️ **2026-09-29 TL 更正**：本节原写"工具核实用，**不进 git**" —— 那会与 §1.1/§1.2/§1.3/§3.1
> **本规格书自己引用的 `p*_stdout.txt`** 冲突（引文都在那些文件里，不入库就**证据索引悬空**）。
> ⇒ **改判：被引用的小体积文本读数入库**（`*_stdout.txt` / `*.tcl` / `run_p*.bat` / `clockInfo.txt`，
> 合计约 324 KB）；**Vivado 工程目录与网表/位流仍排除**（`pj_fin/`、`rb_*/`、`nl_*.v`、`.Xil`、`*.log`、`*.jou`）
> —— 它们可由 `p*.tcl` 重跑得到，且体积大。与 P6b 那轮的裁决同一条原则：
> **报告/规格引用的东西必须真的在库里**（对比 `P6B` 那轮给三个 scratch 目录加窄口径放行）。

| 文件 | 内容 | 入库? |
|---|---|---|
| `p1_wizard.tcl` / `p2_wizard.tcl` / `p3_wizard.tcl` | 探路：ipdef 查询、枚举值拼写、target 名 | ✅ |
| `p4_matrix.tcl` | 参数顺序/形式的四变体矩阵（**证明逐条设 refclk 频率永远失败**） | ✅ |
| `p5_final.tcl` | ⭐ **可用配方**：一次 `set_property -dict` 原子提交 | ✅ |
| `p6_readback.tcl` / `p7_readback2.tcl` | ⭐ **gearbox A/B 回读**：两个构建各自 OOC 综合 + 布局 + 读原语属性 | ✅ |
| `p1..p7_stdout.txt` | 各轮**原始输出**（本规格书所有引文的出处） | ✅ |
| `*_vivado.log` / `*.jou` | 同一批读数的 Vivado 日志（与 `.txt` 重复且带头尾） | ❌ |
| `nl_pos.v` / `nl_raw.v` | 两个布局后网表文本（3.6 MB；**属性可由 `p7_readback2.tcl` 重跑复现**） | ❌ |
| `pj_fin/` / `rb_*/` | wizard 生成的工程与 example design（PRBS 三件套 + refclk XDC 可再生成） | ❌ |

**闸 0 未烧板**：板子当时仍载着 P6b 的冻结位流（已验收），留作对照。
