# P7B 侦察：`fpganinja/taxi` 接续项目 与 PR #96 来源核实

> **只读取证报告**。所有结论均带出处（URL / commit hash / 文件+行号）。
> 取数时间：**2026-09-29**。方法：`curl -k https://api.github.com/...` + `git clone` 到
> **系统临时目录** `C:\Users\zhxue\AppData\Local\Temp\taxi_recon\`（**未 clone 进本仓库**）。
> 未烧板、未综合、未做任何 git 写操作。
> ⚠️ 凡未查到的，一律写「未核实」，**不做推断填充**。

---

## 0. 结论速览（先读这 6 条）

| # | 结论 | 对我们的含义 |
|---|---|---|
| 1 | **`fpganinja/taxi` 存在**，默认分支 `master`，HEAD `cc70b270b910d369ab1ad7b3855e76399fd461f1`（2026-08-28），**活跃维护**（2026-08 有 80 个 commit） | 是活的接续项目 |
| 2 | ⭐ **许可变了：taxi = `CERN-OHL-S-2.0`（强互惠/传染），不是 MIT**。作者提供**付费商业许可**（info@fpga.ninja） | **法务决策点**。见 §3.1，这是本次最重要的发现 |
| 3 | **taxi 有等价的 10G PHY + 10G MAC**（改名前缀 `taxi_`），**PHY 层仍是 `xgmii_txd[63:0]` + `xgmii_txc[7:0]`** | 但 **MAC 层接口换成了 SV 的 AXI-stream**（`taxi_axis_if`）。见 §2.4 |
| 4 | ⭐ taxi 里有 **`RK_XCKU5P_F` 板级 10G 例子**，**器件 `xcku5p-ffvb676-2-e`**、**GTY `X0Y4/X0Y5`（quad 225）**、**refclk `V7/V6` @156.25MHz**、**SFP 引脚 `Y2/AA5`+`V2/W5`** —— **与我们板子逐项相同**（仅速度等级 −2 vs 我们的 −1） | **引脚/时钟/通道层面近乎 drop-in**，见 §2.5 |
| 5 | **PR #96 真实存在**（编号对得上），`state=open`、**`merged=False`**、`merged_at=None`。是 **KCU116 板**（`XCKU5P-2FFVB676E`，**−2**） | 但它是 **2021 年创建、零评论、未合并**的，别指望上游维护。见 §3.2 |
| 6 | ⚠️ **「配置与 P7a 逐项一致」不成立**。核心项（线速率/refclk/数据宽度/64B66B_ASYNC）**一致**，但 **FREERUN_FREQUENCY、SECONDARY_QPLL_ENABLE、RX_EQ_MODE、ENABLE_OPTIONAL_PORTS、DISABLE_LOC_XDC、LOCATE_RESET_CONTROLLER 共 6 项不一致**，且 **QPLL0 只是"推定"**（preset 加密，读不到） | 见 §4 逐项核对表 |

---

## 1. `fpganinja/taxi` 事实表

### 1.1 仓库元数据（来源：`https://api.github.com/repos/fpganinja/taxi`，2026-09-29）

| 字段 | 值 |
|---|---|
| `full_name` | `fpganinja/taxi` |
| URL | https://github.com/fpganinja/taxi |
| 站点 | https://fpga.taxi （README 另有文档站 https://docs.fpga.taxi/ ） |
| 描述 | `AXI, AXI stream, Ethernet, and PCIe components in System Verilog` |
| 默认分支 | **`master`** |
| 创建时间 | `2025-02-03T07:31:05Z` |
| `pushed_at`（最后 push） | **`2026-08-28T21:46:01Z`** |
| `updated_at`（含 issue 等） | `2026-09-29T06:15:45Z` |
| `archived` / `disabled` | **`false` / `false`**（未归档） |
| stars / forks / open issues | 955 / 149 / 31 |
| `license` (API) | **`key=cern-ohl-s-2.0`, `spdx_id=CERN-OHL-S-2.0`**，名称 *CERN Open Hardware Licence Version 2 - Strongly Reciprocal* |
| `fork` | `false`（**不是** verilog-ethernet 的 fork） |
| `owner.type` | `Organization`（FPGA Ninja, LLC；与作者个人号 `alexforencich` 区分） |

### 1.2 HEAD 与活跃度

- **HEAD = `cc70b270b910d369ab1ad7b3855e76399fd461f1`**，`2026-08-28 13:34:16 -0700`，作者 Alex Forencich，标题 `eth: Testbench cleanup`
  （来源：临时 clone 内 `git log -1 --format='%H%n%ad%n%an%n%s' --date=iso`）
- **分支**：只有 `master`（`git branch -a` 仅 `master` + `origin/master`）
- **⭐ tag 数 = 0**（`git tag | wc -l` → `0`）⇒ **零 release**
- 最近 10 个 commit（`git log -10`），可见**近期仍在改 eth 数据面**：

  ```
  cc70b27 2026-08-28 eth: Testbench cleanup
  2361a6c 2026-08-28 ci: Update cocotbext-eth
  8afb79a 2026-08-27 eth: Add gearbox delay compensation for BASE-R RX
  cfff289 2026-08-24 eth: Update timestamp precision threshold
  1a9e3f2 2026-08-24 eth: Fix sync signal width
  f19a6a8 2026-08-24 eth: Add gearbox delay compensation for BASE-R TX
  2f2fe72 2026-08-20 eth: Add PTP_TS_FNS_W parameter to MACs
  e80a9c2 2026-08-17 apb: Testbench cleanup
  cb7c807 2026-08-17 eth: Update testbenches to use cocotb.parametrize
  32d838e 2026-08-15 axis: Update testbenches to use cocotb.parametrize
  ```
- 逐月 commit 数（`git log --format='%ad' --date=format:'%Y-%m' | sort | uniq -c`）尾部 12 个月：
  `2025-09:23, 2025-10:23, 2025-11:70, 2025-12:26, 2026-01:26, 2026-02:92, 2026-03:125, 2026-04:56, 2026-05:20, 2026-06:34, 2026-07:62, 2026-08:80`
  ⇒ **持续活跃，无停滞迹象**。

### 1.3 许可（逐字）

`taxi/LICENSE` 第 1 行（仓库根，13708 字节）：

```
CERN Open Hardware Licence Version 2 - Strongly Reciprocal
```

同文件 Preamble 逐字（说明三档变体）：

```
CERN has developed this licence to promote collaboration among
hardware designers and to provide a legal tool which supports the
freedom to use, study, modify, share and distribute hardware designs
and products based on those designs. Version 2 of the CERN Open
Hardware Licence comes in three variants: CERN-OHL-P (permissive); and
two reciprocal licences: CERN-OHL-W (weakly reciprocal) and this
licence, CERN-OHL-S (strongly reciprocal).
```

**README「License」节逐字**（`taxi/README.md`）—— 这段是决定性的：

```
Taxi is provided by FPGA Ninja, LLC under either the CERN Open Hardware Licence
Version 2 - Strongly Reciprocal (CERN-OHL-S 2.0), or a paid commercial license.
Contact info@fpga.ninja for commercial use.  Note that some components may be
provided under less restrictive licenses (e.g. example designs).

Under the strongly-reciprocal CERN OHL, you must provide the source code of the
entire digital design upon request, including all modifications, extensions,
and customizations, such that the design can be rebuilt.  If this is not an
acceptable restriction for your product, please contact info@fpga.ninja to
inquire about a commercial license without this requirement.  License fees
support the continued development and maintenance of this project and related
projects.

To facilitate the dual-license model, contributions to the project can only be
accepted under a contributor license agreement.
```

**仓内许可分布（实测，非宣称）** —— `grep -rho 'SPDX-License-Identifier: .*' src/ | sort | uniq -c`：

```
    592 SPDX-License-Identifier: CERN-OHL-S-2.0
    319 SPDX-License-Identifier: MIT
```

**⇒ 是混合许可仓库**，但 **10G 核心文件全部是 CERN-OHL-S-2.0**（逐个核实，见下表）。
MIT 的 319 个大多落在 `example/` 下（`src/eth/` 内 MIT 652 / CERN 230，MIT 集中在 `src/eth/example/...`）。

**商用免费吗？**
**不是无条件免费。** 免费路径 = CERN-OHL-S-2.0，**附带强互惠义务**（"you must provide the source code of *the entire digital design* upon request, including all modifications, extensions, and customizations"）。
不想要该义务 ⇒ **必须联系 `info@fpga.ninja` 购买商业许可**。

### 1.4 与 `verilog-ethernet` 的关系：**继任（改名）**，不是"另一个库"

证据三条，互相独立：

1. **`verilog-ethernet` 自己的 README 有 Deprecation Notice**（逐字，`master` 分支）：
   ```
   ## Deprecation Notice

   This repository is superseded by https://github.com/fpganinja/taxi.  All new
   features and bug fixes will be applied there, and commercial support is also
   available.  As a result, this repo is deprecated and will not receive any
   future maintenance or support.
   ```
2. **该 README 是被最后一次 commit 改的**：`verilog-ethernet` HEAD = `77320a9471d19c7dd383914bc049e02d9f4f1ffb`，`2025-02-27T23:50:25Z`，**commit message = `Add deprecation notice`**
   （来源：`https://api.github.com/repos/alexforencich/verilog-ethernet/commits?per_page=1`）
3. **同一作者**：taxi 的 commit 作者是 `Alex Forencich`；taxi 首个 commit `5f87c2e`（`2025-02-02`）标题 `Initial commit`，**初始树里只有 `README.md`**（`git ls-tree --name-only 5f87c2e` → 仅 `README.md`）
   ⇒ **不是 git fork、不是快照拷贝**，是**逐模块重建**的重写项目（这也和"`.gitmodules` 从未存在"一致，见 §2.6）。

**模块改名规律**（旧 → 新）：

| 旧 `verilog-ethernet/rtl/` | 新 `taxi/src/eth/rtl/` |
|---|---|
| `eth_phy_10g.v` | `taxi_eth_phy_10g.sv` |
| `eth_mac_10g.v` | `taxi_eth_mac_10g.sv` |
| `eth_mac_phy_10g.v` | `taxi_eth_mac_phy_10g.sv` |
| `eth_phy_10g_tx_if.v` | `taxi_eth_phy_10g_tx_if.sv` |
| `axis_xgmii_tx_64.v` | `taxi_axis_xgmii_tx_64.sv` |
| （无对应，旧库 `rtl/` 是平铺的，**没有 `us/` 子目录**） | `us/taxi_eth_phy_10g_us_gt.sv` 等 |

**一处语言/风格变更（对我们有实际影响）**：旧库是 **Verilog-2001**（`.v`）、端口是裸 `wire`；
taxi 是 **SystemVerilog**（`.sv`）、顶层接口用 **SV interface 类型** `taxi_axis_if.snk` / `taxi_axis_if.src`。

---

## 2. taxi 里的 10G PHY + MAC（问题 A4）

### 2.1 **有**。文件清单（含行数，来源：临时 clone `wc -l`）

| 新文件（`taxi/src/eth/rtl/`） | 行数 | 旧库对应物 | SPDX |
|---|---|---|---|
| `taxi_eth_phy_10g.sv` | 190 | `rtl/eth_phy_10g.v` | `CERN-OHL-S-2.0` |
| `taxi_eth_phy_10g_tx.sv` / `_rx.sv` / `_tx_if.sv` / `_rx_if.sv` | — | `eth_phy_10g_{tx,rx,tx_if,rx_if}.v` | `CERN-OHL-S-2.0` |
| `taxi_eth_phy_10g_rx_ber_mon.sv` / `_rx_frame_sync.sv` / `_rx_watchdog.sv` | — | 同名旧物 | — |
| `taxi_eth_mac_10g.sv` | **1063** | `rtl/eth_mac_10g.v` | `CERN-OHL-S-2.0` |
| `taxi_eth_mac_10g_fifo.sv` | — | `eth_mac_10g_fifo.v` | — |
| `taxi_eth_mac_phy_10g.sv` | **1097** | `rtl/eth_mac_phy_10g.v` | `CERN-OHL-S-2.0` |
| `taxi_eth_mac_phy_10g_fifo.sv` / `_rx.sv` / `_tx.sv` | — | 同名旧物 | — |
| `taxi_xgmii_baser_enc.sv` | **401** | `xgmii_baser_enc.v` | `CERN-OHL-S-2.0` |
| `taxi_xgmii_baser_dec.sv` | **596** | `xgmii_baser_dec.v` | — |
| `taxi_axis_xgmii_tx_64.sv` / `_rx_64.sv` / `_tx_32.sv` / `_rx_32.sv` | — | 同名旧物 | — |
| `us/taxi_eth_phy_10g_us_gt.sv` | **1279** | （旧库无对应，见 §2.3） | `CERN-OHL-S-2.0` |
| `us/taxi_eth_phy_10g_us_gt_ll.sv` | — | — | — |
| `us/taxi_eth_phy_25g_us_gt.sv` | — | — | `CERN-OHL-S-2.0` |
| `us/taxi_eth_phy_10g_7_gt.sv`（7 系列） | — | — | — |
| `us/taxi_eth_phy_10g_us_gty_156.tcl` | — | — | `CERN-OHL-S-2.0` |
| `us/taxi_eth_phy_25g_us_gty_10g_156.tcl` | — | — | `CERN-OHL-S-2.0` |

**GTY 156.25 MHz 的 TCL 脚本齐全**（`ls src/eth/rtl/us/*.tcl`）：
`taxi_eth_phy_10g_us_gty_{156,161,322}.tcl`、`taxi_eth_phy_25g_us_gty_10g_{156,161,322}.tcl`、
`taxi_eth_phy_25g_us_gty_25g_{156,161,322}.tcl`、`_gth_*` 系列、
`taxi_eth_phy_1g_basex_us_gty_{125,156}.tcl`、`taxi_eth_mac_100g_us_gty_{156,161,322}.tcl`。
⇒ **156 = 156.25 MHz refclk**，与我们 Y2 晶振一致。

### 2.2 **接口是否还是 `xgmii_txd[63:0]` + `xgmii_txc[7:0]`？—— PHY 层：是；MAC 层：不是**

**PHY 层（`taxi_eth_phy_10g.sv`）仍然是裸 XGMII**（来源：`taxi/src/eth/rtl/taxi_eth_phy_10g.sv` 端口段）：

```systemverilog
module taxi_eth_phy_10g #
(
    parameter DATA_W = 64,
    parameter CTRL_W = (DATA_W/8),
    parameter HDR_W = 2,
    parameter logic TX_GBX_IF_EN = 1'b0,
    parameter logic RX_GBX_IF_EN = TX_GBX_IF_EN,
    parameter logic BIT_REVERSE = 1'b0,
    ...
    input  wire logic [DATA_W-1:0]  xgmii_txd,
    input  wire logic [CTRL_W-1:0]  xgmii_txc,
    ...
    output wire logic [DATA_W-1:0]  xgmii_rxd,
    output wire logic [CTRL_W-1:0]  xgmii_rxc,
    ...
    output wire logic [DATA_W-1:0]  serdes_tx_data,
    output wire logic               serdes_tx_data_valid,
    output wire logic [HDR_W-1:0]   serdes_tx_hdr,
    ...
    output wire logic               serdes_rx_bitslip,
```

⇒ `DATA_W=64` / `CTRL_W=8` ⇒ **`xgmii_txd[63:0]` + `xgmii_txc[7:0]` 保持**，`serdes_tx_hdr` 仍为 2 位。
**这一层与我们的需求（GT gearbox ↔ 64 位 XGMII）完全对应。**

**MAC 层（`taxi_eth_mac_10g.sv` / `taxi_eth_mac_phy_10g.sv`）已改为 SV interface**：

```systemverilog
    taxi_axis_if.snk                      s_axis_tx,
    taxi_axis_if.src                      m_axis_tx_cpl,
    taxi_axis_if.src                      m_axis_rx,
```
（来源：`taxi/src/eth/rtl/taxi_eth_mac_phy_10g.sv` 端口段第 61/62/67 行）

**对照旧库**（`verilog-ethernet@master:rtl/eth_mac_10g.v`，731 行，`http=200`）——**旧库 MAC 就是裸 XGMII**：

```
 81:    input  wire [DATA_WIDTH-1:0]        xgmii_rxd,
 82:    input  wire [CTRL_WIDTH-1:0]        xgmii_rxc,
 83:    output wire [DATA_WIDTH-1:0]        xgmii_txd,
 84:    output wire [CTRL_WIDTH-1:0]        xgmii_txc,
231:    .xgmii_rxd(xgmii_rxd),   232: .xgmii_rxc(xgmii_rxc),
269:    .xgmii_txd(xgmii_txd),   270: .xgmii_txc(xgmii_txc),
```

⇒ **迁移注意**：若我们要的是"GT gearbox ↔ 64 位 XGMII"，旧库的 `eth_mac_10g.v` 边界就是裸 XGMII；
taxi 里要经 `taxi_axis_xgmii_{tx,rx}_64.sv` 做 AXI-stream ↔ XGMII 转换，或直接用 PHY 层自己接。

### 2.3 ⭐ 关键架构变化：US/US+ 上 **64 位 @10G 走的是"25G 那一套"**

**决定性证据**（两个 `$fatal` 互斥）：

- `taxi/src/eth/rtl/us/taxi_eth_phy_10g_us_gt.sv`，第 **135–136** 行：
  ```systemverilog
  if (DATA_W != 32)
      $fatal(0, "Error: Interface width must be 32");
  ```
- `taxi/src/eth/rtl/us/taxi_eth_phy_25g_us_gt.sv`，第 **135–136** 行：
  ```systemverilog
  if (DATA_W != 64)
      $fatal(0, "Error: Interface width must be 64");
  ```

⇒ **`taxi_eth_phy_10g_us_gt` 只支持 32 位**；**64 位 10.3125Gbps 必须用
`taxi_eth_phy_25g_us_gt`（`DATA_W=64`）+ `taxi_eth_phy_25g_us_gty_10g_156.tcl`。**

与 README 自述一致（`taxi/README.md` 第 56 行逐字）：

```
The 10G/25G MAC/PHY/GT wrapper for 7-series/UltraScale/UltraScale+ supports GTX, GTH,
and GTY transceivers.  On UltraScale and UltraScale+, it can be configured for either a
32-bit or 64-bit datapath via the DATA_W parameter.  The 32-bit datapath supports 10G
only, while the 64-bit datapath can be used for either 10G or 25G.
```

**⚠️ 这是 taxi 与旧库的一个实质差异**：旧库的 KCU116 例子（PR #96）用的是
`eth_phy_10g #(.BIT_REVERSE(1))`（默认 `DATA_WIDTH=64`）+ **64 位 GT IP**；
taxi 的 KU5P 例子（`RK_XCKU5P_F`）用的是 **32 位**那一套（见 §2.5）。

### 2.4 依赖 / 子模块（问题 A6）

**✅ 没有 git submodule。** 三条独立证据：

1. `.gitmodules` **从未存在**：`git log --all --oneline -- .gitmodules` → **空输出**（clone 了完整历史）
2. `git ls-tree -r HEAD | awk '$1=="160000"'` → **空输出**（无 gitlink）
3. `find taxi -name .gitmodules` → 不存在

**取而代之的是 165 个符号链接**（`git ls-files -s | awk '$1=="120000"'`，计数 **165**），
例如 `src/eth/lib/taxi` 的 git 模式是 **`120000`**，内容 = **`../../../`**：

```
$ git ls-files -s src/eth/lib/taxi
120000 1b20c9fb816b63e210b545787d17dd0c2d4b7279 0	src/eth/lib/taxi
$ cat src/eth/lib/taxi
../../../
```

⇒ **库自包含、自引用**，`<subdir>/lib/taxi` 指回仓库根。**不需要额外拉取任何子模块**，
**不存在第三方 submodule 许可问题**。

（对比：**PR #96 里倒是有子模块** —— `example/KCU116/fpga_10g/lib/eth` 是 **gitlink**，
指向 sha **`11a54ed360106c9f6a2dbbdab67c7c5bd84ae617`**。来源：`/pulls/96/files` API，
`{"filename":"example/KCU116/fpga_10g/lib/eth","status":"added","sha":"11a54ed3..."}`。
⚠️ 该 sha 对应哪个仓库/哪个 commit，**未核实**。）

**模块级依赖**（不是 submodule，但要一起编译）——`taxi/src/eth/rtl/us/taxi_eth_phy_10g_us_gt.f` 逐字：

```
taxi_eth_phy_10g_us_gt.sv
taxi_eth_phy_25g_us_gt_apb.sv
../../lib/taxi/src/sync/rtl/taxi_sync_reset.sv
../../lib/taxi/src/sync/rtl/taxi_sync_signal.sv
../../lib/taxi/src/hip/rtl/us/taxi_gt_qpll_reset.sv
../../lib/taxi/src/hip/rtl/us/taxi_gt_rx_reset.sv
../../lib/taxi/src/hip/rtl/us/taxi_gt_tx_reset.sv
../../lib/taxi/src/apb/rtl/taxi_apb_if.sv
```

### 2.5 ⭐⭐ taxi 有 KU5P 板级例子 `RK_XCKU5P_F` —— 与我们板子近乎逐项相同

路径：`taxi/src/eth/example/RK_XCKU5P_F/`（README 第 238 行点名 `RK-XCKU5P-F (Xilinx Kintex UltraScale+ XCKU5P)`）。

**器件**（`fpga/fpga_10g/Makefile` 逐字）：

```make
FPGA_PART = xcku5p-ffvb676-2-e
FPGA_TOP = fpga
FPGA_ARCH = kintexuplus
```

**GT 参考钟与通道**（`fpga/syn/qsfp.xdc`）：

```
13:set_property -dict {LOC Y2  } [get_ports {qsfp_rx_p[0]}] ;# MGTYRXP0_225 GTYE4_CHANNEL_X0Y4 / GTYE4_COMMON_X0Y1
15:set_property -dict {LOC AA5 } [get_ports {qsfp_tx_p[0]}] ;# MGTYTXP0_225 GTYE4_CHANNEL_X0Y4 / GTYE4_COMMON_X0Y1
17:set_property -dict {LOC V2  } [get_ports {qsfp_rx_p[1]}] ;# MGTYRXP1_225 GTYE4_CHANNEL_X0Y5 / GTYE4_COMMON_X0Y1
19:set_property -dict {LOC W5  } [get_ports {qsfp_tx_p[1]}] ;# MGTYTXP1_225 GTYE4_CHANNEL_X0Y5 / GTYE4_COMMON_X0Y1
29:set_property -dict {LOC V7  } [get_ports {qsfp_mgt_refclk_p}] ;# MGTREFCLK0P_225
30:set_property -dict {LOC V6  } [get_ports {qsfp_mgt_refclk_n}] ;# MGTREFCLK0N_225
39:# 156.25 MHz MGT reference clock
40:create_clock -period 6.4 -name qsfp_mgt_refclk [get_ports {qsfp_mgt_refclk_p}]
```

**与我们 XCKU5PMini 的对照**（我们的来源：本仓库 `CLAUDE.md`「本板实测修正」+ `Demo/.../src/PCIe.xdc`）：

| 项 | `RK_XCKU5P_F`（taxi） | **我们 XCKU5PMini** | 判定 |
|---|---|---|---|
| 封装 | `ffvb676` | `ffvb676` | ✅ 同 |
| 器件 | `xcku5p-ffvb676-**2**-e` | `xcku5p-ffvb676-**1**-e` | ⚠️ **仅速度等级不同** |
| GT refclk 引脚 | `V7` / `V6` = `MGTREFCLK0_225` | `V7`/`V6` = `MGTREFCLK0_225` | ✅ 同 |
| refclk 频率 | `156.25 MHz`（`create_clock -period 6.4`） | `156.25 MHz`（Y2 晶振） | ✅ 同 |
| GTY 通道 | `X0Y4` / `X0Y5`（quad 225） | `X0Y4 X0Y5`（我们 P7a `CHANNEL_ENABLE`） | ✅ 同 |
| SFP ch0 RX/TX | `Y2` / `AA5` | `aurora_rxp[0]=Y2` / `aurora_txp[0]=AA5` | ✅ 同 |
| SFP ch1 RX/TX | `V2` / `W5` | `aurora_rxp[1]=V2` / `aurora_txp[1]=W5` | ✅ 同 |

⭐ **注意**：我们的 `udp_hls_10g/_proj_10g` 那边早先**独立**为自己的 `gt_10gbr` IP 选了
`CHANNEL_ENABLE = X0Y4 X0Y5` + `TX/RX_REFCLK_SOURCE = X0Y4 clk0 X0Y5 clk0`
（见 §4 表），**与这个例子的通道/refclk 选择完全相同**。⇒ 这套例子在**引脚/时钟/通道层面是可对标的**。

**该例子的数据面配置**（`fpga/fpga_10g/config.tcl` 逐字）：

```tcl
# 10G MAC configuration
dict set params CFG_LOW_LATENCY "1"
dict set params COMBINED_MAC_PCS "1"
dict set params MAC_DATA_W "32"
```

**它用的 GT IP 脚本**（`fpga/fpga_10g/Makefile` 逐字）：

```make
IP_TCL_FILES = $(TAXI_SRC_DIR)/eth/rtl/us/taxi_eth_phy_10g_us_gty_156.tcl
```

⇒ **32 位数据面 + 低延迟（`CFG_LOW_LATENCY=1`）+ 10G + 156.25MHz**。
⚠️ 与我们的 **64 位 P7a**（`TX_USER_DATA_WIDTH=64`）**不同**；且 `CFG_LOW_LATENCY=1`
对应的是 **`64B66B`（同步 gearbox + buffer bypass）**，而我们是 **`64B66B_ASYNC`**（见 §4.2）。

**该例子的许可**：`config.tcl` / `Makefile` 头部是 **`SPDX-License-Identifier: MIT`**（example design 属 README 说的
"some components may be provided under less restrictive licenses (e.g. example designs)"）。
它的 README「Licensing」节逐字：

```
* Toolchain
  * Vivado Standard (enterprise license not required)
* IP
  * No licensed vendor IP or 3rd party IP
```

**它**没有**任何 `-1` 速度等级的说明**；`README.md` 只写 `FPGA: xcku5p-ffvb676-2-e`。

**全仓速度等级扫描**（`grep -rhn -E 'FPGA_PART\s*=' src/eth/example/*/fpga/*/Makefile | sort -u`，36 个唯一 part）：
其中 `-1` 速度等级的**只有** `xcku3p-ffvb676-1-e`（KU3P，同封装同速度等级）。
⇒ **taxi 里没有任何 `xcku5p-*-1-*` 例子**。

### 2.6 Xilinx UltraScale+ / 10GBASE-R 的 GT 脚本内容（64 位 10G 那本）

`taxi/src/eth/rtl/us/taxi_eth_phy_25g_us_gty_10g_156.tcl`（**64 位 @10.3125 + 156.25MHz**，
与我们 P7a 拓扑同级）。关键行逐字：

```tcl
set base_name {taxi_eth_phy_25g_us_gty}
set preset {GTY-10GBASE-R}
set freerun_freq {125}
set line_rate {10.3125}
set refclk_freq {156.25}
set sec_line_rate $line_rate
set sec_refclk_freq $refclk_freq
set qpll_fracn [expr {int(fmod($line_rate*1000/2 / $refclk_freq, 1)*pow(2, 24))}]
set user_data_width {64}
set int_data_width $user_data_width
set rx_eq_mode {DFE}
...
# normal latency (async gearbox)
dict set config TX_DATA_ENCODING {64B66B_ASYNC}
dict set config TX_BUFFER_MODE {1}
dict set config TX_OUTCLK_SOURCE {TXPROGDIVCLK}
dict set config RX_DATA_DECODING {64B66B_ASYNC}
dict set config RX_BUFFER_MODE {1}
dict set config RX_OUTCLK_SOURCE {RXPROGDIVCLK}
```

它一次生成 **4 个 IP 变体**：`${base_name}_full`、`_ch`、`_ll_full`、`_ll_ch`
（`_ll` = low latency = `TX_DATA_ENCODING {64B66B}` + `TX_BUFFER_MODE {0}` + `RX_OUTCLK_SOURCE {RXOUTCLKPMA}`）。

⚠️ **与我们的 P7a 的差异**（见 §4）：`freerun_freq {125}`（我们 **156.25**）、
`SECONDARY_QPLL_ENABLE true`（我们 **false**）、`RX_EQ_MODE {DFE}`（我们 **AUTO**）、
以及一大票 `ENABLE_OPTIONAL_PORTS`（我们**为空**）。

**`sec_qpll_fracn` 的算术**：`10.3125*1000/2 / 156.25 = 33.0` ⇒ `fmod(...,1)=0` ⇒ **fracn = 0**。
与我们 P7a 的 `TX/RX_QPLL_FRACN_NUMERATOR = 0` **一致**，且与「QPLL0 以整数倍 66×156.25MHz 锁定」自洽。

### 2.7 taxi 的 US GT 包装器**不是即插即用**：它例化一个叫 `gt_ch_inst` 的占位模块

`taxi/src/eth/rtl/us/taxi_eth_phy_10g_us_gt.sv` 里 **6 处**例化名 `gt_ch_inst`
（行 **585 / 703 / 821 / 939 / 1057 / 1166**，每个器件族一处：

```
585:    gt_ch_inst (
703:    gt_ch_inst (
821:    gt_ch_inst (
939:    gt_ch_inst (
1057:    gt_ch_inst (
1166:    gt_ch_inst (
```

⇒ 调用方必须**自己提供** `gt_ch_inst` 这个薄壳（包住 `gtwizard` 生成的核）并匹配它的端口表。
该端口表要求 GT IP 暴露**大量可选端口**（在该 wrapper 里实际用到的）：

```
.drpclk_in( .drpen_in( .drpwe_in(
.qpll0reset_in( .qpll1reset_in( .qpll0pd_in(
.gtrefclk00_in( .gtrefclk01_in(
.txpolarity_in( .rxpolarity_in(
.txsysclksel_in( .rxsysclksel_in( .txpllclksel_in( .rxpllclksel_in(
.txdiffctrl_in( .txmaincursor_in( .txprecursor_in( .txpostcursor_in(
.txelecidle_in( .txinhibit_in( .txpdelecidlemode_in(
.rxcdrhold_in( .rxlpmen_in( .rxdfelpmreset_in(
```

⚠️ **我们的 `gt_10gbr` IP 的 `ENABLE_OPTIONAL_PORTS` 是空的**（见 §4 表）⇒ 端口集**不匹配**，
**要接 taxi 的包装器就得重新生成 GT IP**。

---

## 3. PR #96 的来源与内容（问题 B）

### 3.1 PR 事实表（来源：`https://api.github.com/repos/alexforencich/verilog-ethernet/pulls/96`，2026-09-29）

| 字段 | 值 |
|---|---|
| **存在？** | ✅ **存在，编号对得上** |
| `number` | **96** |
| `title` | **`Add Xilinx Kintex UltraScale+ KCU116 board`** |
| URL | https://github.com/alexforencich/verilog-ethernet/pull/96 |
| `user.login` | **`lschuermann`** |
| `created_at` | **`2021-10-11T08:35:56Z`** |
| `updated_at` | `2024-02-11T21:00:46Z` |
| `state` | **`open`** |
| `merged` | **`false`** |
| `merged_at` | **`null`** |
| `closed_at` | `null` |
| `mergeable_state` | `clean`（可合并但没人合） |
| `draft` | `false` |
| `comments` / `review_comments` | **0 / 0**（**零讨论**） |
| `commits` / `changed_files` | **1 / 9** |
| `additions` / `deletions` | **+1630 / −0** |
| `head` | `lschuermann:dev/kcu116-support`，sha **`7e570709f2844396ac6e3cc48538c1141175e4a9`** |
| `base` | `alexforencich:master`，sha `870cebb798fce9be3261c73a69c0a9858aac0d47` |

**⚠️ 三处必须点明的偏差（不是圆场的地方）**：

1. **板子不是 XCKU5PMini**，是 **Xilinx 官方 KCU116 评估板**。
2. **速度等级是 `-2`**，不是我们的 `-1`。**两处独立证据**：
   - PR body 逐字：*"This commit adds the Xilinx Kintex UltraScale+ KCU116 board featuring the **XCKU5P-2FFVB676E** FPGA and 4 zSFP cages."*
   - `example/KCU116/fpga_10g/README.md` 逐字：`*  FPGA: XCKU5P-2FFVB676E`
   - `example/KCU116/fpga_10g/fpga.xdc` 第 3 行逐字：`# part: xcku5p-ffvb676-2-e`
3. **它是「整个板级例子」，不是可组合的库文件。**

**PR body 其余关键内容**（逐字摘）：

```
XGMII PHYs are instantiated for all four cages in `fpga.v` and passed down to
`fpga_core.v`. Only the first (SFP 0) cage is connected to the instantiated UDP/IP core.

The I2C bus to the SFPs uses an I2C mux chip and is currently unsupported.

The reference clock for the GTY transceiver connected to the SFPs is generated by an
external, on-board Si5328 clock chip which must be configured to output a clock signal
of 156.25MHz before the transceiver can be used.
...
### Inclusion in verilog-ethernet
@alexforencich I've seen in some other PRs that you are not willing to accept pull
requests for hardware you don't have access to. ...
```

### 3.2 文件清单（来源：`/pulls/96/files` API）

```
  added     +25    -0    example/KCU116/fpga_10g/Makefile
  added     +37    -0    example/KCU116/fpga_10g/README.md
  added     +123   -0    example/KCU116/fpga_10g/common/vivado.mk
  added     +67    -0    example/KCU116/fpga_10g/fpga.xdc
  added     +58    -0    example/KCU116/fpga_10g/fpga/Makefile
  added     +23    -0    example/KCU116/fpga_10g/ip/gtwizard_ultrascale_0.tcl
  added     +1     -0    example/KCU116/fpga_10g/lib/eth          ← gitlink (submodule), sha 11a54ed3...
  added     +678   -0    example/KCU116/fpga_10g/rtl/fpga.v
  added     +618   -0    example/KCU116/fpga_10g/rtl/fpga_core.v
```

**它建的例子**：4 个 SFP28 笼（zSFP）各例化一个 XGMII PHY；**只有 SFP0 接 UDP/IP 回显核**
（`192.168.1.128:1234`，`netcat -u` 回显 + 应答 ARP）——`README.md` 逐字。

**它的 GT 例化方式：直接例化 gtwizard 核**（`rtl/fpga.v` 第 362 行 `gtwizard_ultrascale_0`），
手工连 `.gtwiz_userdata_tx_in({...})`、`.txheader_in({...})`、`.rxheader_out({...})`、
`.rxgearboxslip_in({...})`、`.gtyrxn_in/…`。**旧库没有 US GT 包装器**（旧库 `rtl/` 是平铺的，
无 `us/` 子目录 —— 见 `https://api.github.com/repos/alexforencich/verilog-ethernet/contents/rtl?ref=master`
的完整列表），所以只能手连。

**它的 PHY 例化（4 处，行 493 / 528 / 563 / 598）**，SFP0 那处逐字（`rtl/fpga.v` 行 493–511）：

```verilog
eth_phy_10g #(
    .BIT_REVERSE(1)
)
sfp_0_phy_inst (
    .tx_clk(sfp_0_tx_clk_int),
    .tx_rst(sfp_0_tx_rst_int),
    .rx_clk(sfp_0_rx_clk_int),
    .rx_rst(sfp_0_rx_rst_int),
    .xgmii_txd(sfp_0_txd_int),
    .xgmii_txc(sfp_0_txc_int),
    .xgmii_rxd(sfp_0_rxd_int),
    .xgmii_rxc(sfp_0_rxc_int),
    .serdes_tx_data(sfp_0_gt_txdata),
    .serdes_tx_hdr(sfp_0_gt_txheader),
    .serdes_rx_data(sfp_0_gt_rxdata),
    .serdes_rx_hdr(sfp_0_gt_rxheader),
    .serdes_rx_bitslip(sfp_0_gt_rxgearboxslip),
    .rx_block_lock(sfp_0_rx_block_lock),
    .rx_high_ber()
);
```

⇒ **`DATA_WIDTH` 未覆盖 ⇒ 用默认 64**（旧库 `eth_phy_10g.v` 的 `parameter DATA_WIDTH = 64`，
来源 `verilog-ethernet@master:rtl/eth_phy_10g.v` 第 36 行）。
⇒ **PR #96 的 10G 数据面是 64 位，与我们的 P7a 同级**（不像 taxi 的 KU5P 例子走 32 位）。

**它的 XDC 关键行**（`fpga.xdc`）：
```
# 156.25 MHz MGT reference clock
create_clock -period 6.4 -name sfp_mgt_refclk [get_ports sfp_mgt_refclk_p]
set_property -dict {LOC P7  } [get_ports sfp_mgt_refclk_p]; # Bank 226 - MGTREFCLK0P_226
set_property -dict {LOC P6  } [get_ports sfp_mgt_refclk_n]; # Bank 226 - MGTREFCLK0N_226
```
⇒ **refclk 156.25MHz 确认**；但**bank 226**（`P7/P6`），**不是**我们 quad 225 的 `V7/V6`。
（KCU116 的 SFP 在 quad 226；我们板在 225。）

### 3.3 该 PR 是否已进入 `taxi`？—— **没有**

三条证据：

1. **taxi 没有顶层 `example/` 目录**：`ls taxi/example/` → `No such file or directory`；
   taxi 的例子全在 `taxi/src/<模块>/example/`（如 `src/eth/example/`）。
   ⇒ 就算要收录，路径也**必然**不是 PR 里的 `example/KCU116/...`。
2. **taxi 全仓搜 `KCU116` 零命中**：
   `find taxi -ipath '*KCU116*' -not -path './.git/*'` → **空**。
3. taxi 的 `src/eth/example/` 里**有** KCU105 / KR260 / RK_XCKU5P_F 等，**没有 KCU116**。
   ⇒ 这个 PR 的内容**没有被吸收**；KU5P 的对应物是**另起炉灶的 `RK_XCKU5P_F`**（§2.5）。

### 3.4 ⭐ `BIT_REVERSE` 与同步头常量到底怎么设（问题 B5）

**（1）`BIT_REVERSE`：PR #96 一律设 `1`，4 个 SFP 实例全都设。**

`example/KCU116/fpga_10g/rtl/fpga.v` 中 `.BIT_REVERSE(1)` 出现在**行 494、529、564、599**
（分别对应 `sfp_{0,1,2,3}_phy_inst` 的 `eth_phy_10g #(...)` 参数表）：

```
494:    .BIT_REVERSE(1)
529:    .BIT_REVERSE(1)
564:    .BIT_REVERSE(1)
599:    .BIT_REVERSE(1)
```

**（2）同步头常量：板级 wrapper 里「没有设」，也不该在这里设。**

- 同步头常量在**编码器内部**定义（`taxi_xgmii_baser_enc.sv` ≡ 旧 `xgmii_baser_enc.v`，
  行 **112–113** 逐字）：
  ```systemverilog
      SYNC_DATA = 2'b10,
      SYNC_CTRL = 2'b01
  ```
  编码结果走 `output wire logic [HDR_W-1:0] encoded_tx_hdr,`（同文件第 43 行），`HDR_W=2`。
- `BIT_REVERSE` 的**作用就是把数据与头的位序整体倒过来** ——
  `taxi_eth_phy_10g_tx_if.sv` 行 **89–99** 逐字：
  ```systemverilog
  if (BIT_REVERSE) begin
      for (genvar n = 0; n < DATA_W; n = n + 1) begin
          assign serdes_tx_data_int[n] = serdes_tx_data_reg[DATA_W-n-1];
      end
      for (genvar n = 0; n < HDR_W; n = n + 1) begin
          assign serdes_tx_hdr_int[n] = serdes_tx_hdr_reg[HDR_W-n-1];
      end
  end else begin
      assign serdes_tx_data_int = serdes_tx_data_reg;
      assign serdes_tx_hdr_int = serdes_tx_hdr_reg;
  end
  ```
  ⇒ 头的 2 位被**逐位取反顺序**：`SYNC_DATA 2'b10 → 2'b01`，`SYNC_CTRL 2'b01 → 2'b10`（在**发往 GT 的那一侧**）。
- 板级 wrapper 只做**直连**：`eth_phy_10g.serdes_tx_hdr`（2 位）→ GT 的 `txheader_in`。
  PR #96 的 `rtl/fpga.v` 行 **410–415**：
  ```verilog
      .txheader_in({
          sfp_3_gt_txheader,
          sfp_2_gt_txheader,
          sfp_1_gt_txheader,
          sfp_0_gt_txheader
      }),
  ```
  对应声明（同文件）：
  ```
  330:wire [5:0] sfp_0_gt_txheader;
  333:wire [5:0] sfp_0_gt_rxheader;
  334:wire [1:0] sfp_0_gt_rxheadervalid;
  338:wire [5:0] sfp_1_gt_txheader;
  ...
  ```
  ⇒ **每通道 6 位**（RX 侧同理：行 **457–463** `.rxheader_out({...sfp_N_gt_rxheader})`）。
  2 位 PHY 输出接 6 位 GT 端口 ⇒ **零扩展**。

**（3）与我们的 GT IP 的位宽几何完全对得上**（我们从自己的 `gt_10gbr` stub 读到，
`_proj_10g/vivado_prj/p7a_prj.gen/sources_1/ip/gt_10gbr/gt_10gbr_stub.v`）：

```
 32: /* synthesis syn_black_box ... gtwiz_userdata_tx_in[127:0], gtwiz_userdata_rx_out[127:0], ... txheader_in[11:0], txsequence_in[13:0], ... rxheader_out[11:0], rxheadervalid_out[3:0], rxdatavalid_out[3:0] ... */
 52:  input [127:0]gtwiz_userdata_tx_in;
 53:  output [127:0]gtwiz_userdata_rx_out;
 60:  input [11:0]txheader_in;
 66:  output [11:0]rxheader_out;
 67:  output [3:0]rxheadervalid_out;
```

⇒ 2 通道 × 64 位数据、**2 通道 × 6 位 header**、2 通道 × 2 位 headervalid。
**PR #96 用的 4 通道版本就是这套几何 × 4**（4×64 数据、4×6 header、4×2 valid），
与它 `fpga.v` 里 `[5:0]` / `[1:0]` 的声明**逐项吻合**。

> ⚠️ **未核实部分**：2 位 `serdes_tx_hdr` 接到 6 位 `txheader_in` 时的**具体零扩展位置**、
> 以及 Xilinx GTY 64B66B gearbox 对这个 6 位 header 的**字段语义**，**我没有核实**
> （需要读 Xilinx GTY 文档或跑仿真）。我只核实了**两侧的位宽事实**和**PR 的做法**。

---

## 4. 配置逐项核对表（问题 B3）—— **「据称一致」不成立**

三列来源：
- **我们 P7a**：`_proj_10g/vivado_prj/p7a_prj.srcs/sources_1/ip/gt_10gbr/gt_10gbr.xci`
  （解析 `ip_inst.parameters.{component,model,project}_parameters`，共 822 项）
  + stub 里的 `CORE_GENERATION_INFO`
- **PR #96**：`example/KCU116/fpga_10g/ip/gtwizard_ultrascale_0.tcl`（23 行，逐字见 §4.3）
- **taxi 对照列**：`taxi/src/eth/rtl/us/taxi_eth_phy_25g_us_gty_10g_156.tcl`
  （**64 位 @10G**，与我们 P7a 同级；taxi 的另一个 10G 脚本 `taxi_eth_phy_10g_us_gty_156.tcl` 是 **32 位**）

### 4.1 核对表

| # | 配置项 | **我们 P7a** | **PR #96** | taxi `25g_gty_10g_156` | 判定 |
|---|---|---|---|---|---|
| 1 | 器件 | `xcku5p-ffvb676-**1**-e` | `xcku5p-ffvb676-**2**-e` | `xcku5p-ffvb676-**2**-e` | ❌ **速度等级不同（−1 vs −2）** |
| 2 | `preset` | （未用 preset，逐项显式设） | `GTY-10GBASE-R` | `GTY-10GBASE-R` | — （见 §5 未核实 #1） |
| 3 | `TX_LINE_RATE` / `RX_LINE_RATE` | **`10.3125`** / **`10.3125`** | `10.3125` / `10.3125` | `10.3125` / `10.3125` | ✅ 一致 |
| 4 | `TX_REFCLK_FREQUENCY` / `RX_...` | **`156.25`** / **`156.25`** | `156.25` / `156.25` | `156.25` / `156.25` | ✅ 一致 |
| 5 | `TX_USER_DATA_WIDTH` / `RX_...` | **`64`** / **`64`** | `64` / `64` | `64` / `64` | ✅ 一致 |
| 6 | `TX_INT_DATA_WIDTH` / `RX_...` | **`64`** / **`64`** | `64` / `64` | `64` / `64` | ✅ 一致 |
| 7 | `TX_DATA_ENCODING` | **`64B66B_ASYNC`** | （未设；交给 preset） | `64B66B_ASYNC` | ✅（PR 侧为**推定**） |
| 8 | `RX_DATA_DECODING` | **`64B66B_ASYNC`** | （未设；交给 preset） | `64B66B_ASYNC` | ✅（PR 侧为**推定**） |
| 9 | `TX_BUFFER_MODE` / `RX_BUFFER_MODE` | `1` / `1` | （未设；preset） | `1` / `1` | ✅（PR 侧推定） |
| 10 | `TX_OUTCLK_SOURCE` / `RX_OUTCLK_SOURCE` | `TXPROGDIVCLK` / `RXPROGDIVCLK` | （未设；preset） | `TXPROGDIVCLK` / `RXPROGDIVCLK` | ✅（PR 侧推定） |
| 11 | `TX_PLL_TYPE` / `RX_PLL_TYPE` | **`QPLL0`** / **`QPLL0`**（**显式**） | （未设；preset） | （未设；preset） | ⚠️ **未核实**（preset 加密） |
| 12 | `TX/RX_QPLL_FRACN_NUMERATOR` | `0` / `0` | （未设；preset） | `0` / `0`（脚本算出 `33.0→frac 0`） | ✅ 一致 |
| 13 | `SECONDARY_QPLL_ENABLE` | **`false`** | （未设；preset） | **`true`**（`sec_line_rate=10.3125`） | ❌ **不一致** |
| 14 | **`FREERUN_FREQUENCY`** | **`156.25`** | **`125`** | **`125`** | ❌ **不一致** |
| 15 | `RX_EQ_MODE` | **`AUTO`** | （未设；preset） | **`DFE`** | ❌ **不一致** |
| 16 | `ENABLE_OPTIONAL_PORTS` | **（空）** | **`rxpolarity_in txpolarity_in`** | 长列表（drp / qpll reset / polarity / txdiffctrl / cdr / lpm… 见 §2.7） | ❌ **不一致** |
| 17 | `DISABLE_LOC_XDC` | **`0`** | （未设；preset） | **`1`** | ❌ **不一致** |
| 18 | `LOCATE_RESET_CONTROLLER` | **`CORE`** | （未设；preset） | **`EXAMPLE_DESIGN`** | ❌ **不一致** |
| 19 | `LOCATE_COMMON` | `CORE` | （未设；preset） | `CORE`（`_full`）/ `EXAMPLE_DESIGN`（`_ch`） | — |
| 20 | `INS_LOSS_NYQ` | **`20`** | （未设；preset） | （未设；preset） | ⚠️ **未核实** |
| 21 | `CHANNEL_ENABLE` | `X0Y4 X0Y5` | `X0Y11 X0Y10 X0Y9 X0Y8` | （调用方定） | — 板相关 |
| 22 | `TX/RX_REFCLK_SOURCE` | `X0Y4 clk0 X0Y5 clk0` | `X0Y11 clk0 … X0Y8 clk0` | （调用方定） | — 板相关 |
| 23 | `GT_TYPE` / `GT_REV` | `GTY` / `0` | （preset GTY） | （preset GTY） | ✅ |

**我们 P7a 侧的两条旁证**（从 `gt_10gbr_stub.v` 的 `CORE_GENERATION_INFO` 读出）：
`C_TX_DATA_ENCODING=4`、`C_RX_DATA_DECODING=4`（4 = 64B66B_ASYNC 枚举值）、
`C_TX_PLL_TYPE=0`、`C_RX_PLL_TYPE=0`（0 = QPLL0）、`C_RX_BUFFER_MODE=1`、`C_TX_BUFFER_MODE=1`、
`C_TX_OUTCLK_SOURCE=4`、`C_TX_OUTCLK_FREQUENCY=156.2500000`、`C_SECONDARY_QPLL_ENABLE=0`、
`C_FREERUN_FREQUENCY=156.25`、`C_TOTAL_NUM_CHANNELS=2`、`C_RX_INT_DATA_WIDTH=64`、`C_TX_INT_DATA_WIDTH=64`。

### 4.2 小结

- **核心项一致**：线速率 `10.3125` ✓、refclk `156.25` ✓、用户/内部数据宽度 `64` ✓、
  `64B66B_ASYNC` ✓（taxi 显式；PR 交给 preset）、QPLL fracn `0` ✓、BUFFER_MODE `1` ✓、
  OUTCLK `PROGDIVCLK` ✓。
  ⇒ **「据称一致」的"方向"是对的** —— 这三个配置确实都指向同一个 10GBASE-R 工作点。
- **但逐项一致不成立**：**6 项明确不一致**（#1 速度等级、#13、#14、#15、#16、#17、#18 —— 计 7 条），
  **2 项未核实**（#11 QPLL 类型、#20 INS_LOSS_NYQ，都因 preset 加密）。
- **对我们最要紧的一条**：#14 `FREERUN_FREQUENCY`。我们=**156.25**（直接沿用 refclk），
  PR/taxi=**125**。这是 free-running 恢复时钟的频率声明，会影响 GT 复位/校准时序的计数基准
  （且它必须以**实际接入 GT 的时钟**为准）。**采别人的 TCL 时这个值不能照抄。**
- **#16 是最实际的集成障碍**：`ENABLE_OPTIONAL_PORTS` 为空 ⇒ 我们的 `gt_10gbr` IP
  既不匹配 PR #96 手连的端口表，也不匹配 taxi 包装器的端口表。

### 4.3 PR #96 的 gtwizard tcl 全文（23 行，逐字，`example/KCU116/fpga_10g/ip/gtwizard_ultrascale_0.tcl`）

```tcl

create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gtwizard_ultrascale_0

set_property -dict [list CONFIG.preset {GTY-10GBASE-R}] [get_ips gtwizard_ultrascale_0]

set_property -dict [list \
    CONFIG.CHANNEL_ENABLE {X0Y11 X0Y10 X0Y9 X0Y8} \
    CONFIG.TX_MASTER_CHANNEL {X0Y8} \
    CONFIG.RX_MASTER_CHANNEL {X0Y8} \
    CONFIG.TX_LINE_RATE {10.3125} \
    CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.TX_INT_DATA_WIDTH {64} \
    CONFIG.RX_LINE_RATE {10.3125} \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.RX_INT_DATA_WIDTH {64} \
    CONFIG.RX_REFCLK_SOURCE {X0Y11 clk0 X0Y10 clk0 X0Y9 clk0 X0Y8 clk0} \
    CONFIG.TX_REFCLK_SOURCE {X0Y11 clk0 X0Y10 clk0 X0Y9 clk0 X0Y8 clk0} \
    CONFIG.FREERUN_FREQUENCY {125} \
    CONFIG.ENABLE_OPTIONAL_PORTS {rxpolarity_in txpolarity_in} \
] [get_ips gtwizard_ultrascale_0]
```

⇒ **注意：`TX_PLL_TYPE` / `RX_PLL_TYPE` / `TX_DATA_ENCODING` / `RX_DATA_DECODING` /
`TX_BUFFER_MODE` / `TX_OUTCLK_SOURCE` 全部「未设」，一律由 `CONFIG.preset {GTY-10GBASE-R}` 决定。**
⇒ **这就是为什么 §4.1 的 #7–#11 只能标"推定"/"未核实"。**

---

## 5. 未核实清单（**必须先读，任何引用本报告的结论都要看这里**）

| # | 未核实项 | 原因 / 影响 |
|---|---|---|
| 1 | ⭐ **`GTY-10GBASE-R` preset 的逐项内容** | preset 文件**在本地 4 个位置全部是加密/二进制**（`cat` 输出为不可读字节流；`grep GTY-10GBASE-R` 零命中因为内容是二进制）。已穷举核实（见下），**不是"没找到"，是"找到了但读不出"**。⇒ **PR #96 与 taxi 的 `TX_PLL_TYPE`(QPLL0)、`TX_DATA_ENCODING`(64B66B_ASYNC)、`TX_BUFFER_MODE`、`TX_OUTCLK_SOURCE`、`INS_LOSS_NYQ` 全部只能「推定」，没有源码级证据。** 唯一干净的办法是自己 `create_ip` + `set_property CONFIG.preset` 然后回读 XCI ⇒ **属构建动作，本次按纪律未做**。<br>**已穷举的 4 个路径（都加密，别重复搜）**：<br>• `C:/AMDDesignTools/2025.2/Vivado/data/ip/xilinx/gtwizard_ultrascale_v1_7/presets/GTY-10GBASE-R.tcl`（1768 B）<br>• `C:/AMDDesignTools/2025.2/data/ip/xilinx/gtwizard_ultrascale_v1_7/presets/GTY-10GBASE-R.tcl`（1768 B，**平行的第二棵安装树**）<br>• `C:/AMDDesignTools/2025.2/data/ip/xilinx/gt_subcore_ip_v1_0/presets/GTY-10GBASE-R.tcl`（1688 B）<br>• `C:/AMDDesignTools/2025.2/data/ip/xilinx/gtwizard_ultrascale_v1_6/presets/GTY-10GBASE-R.tcl`（568 B）<br>（另有 v1_5 的 presets 目录也在，未逐个开。） |
| 2 | `INS_LOSS_NYQ` 的实际生效值 | 我们 = **20**（显式）；PR/taxi 交给 preset。preset 加密 ⇒ 读不到。 |
| 3 | PR #96 用的 `eth_phy_10g` **具体是哪一版** | PR 里 `lib/eth` 是 gitlink，sha = `11a54ed360106c9f6a2dbbdab67c7c5bd84ae617`，但**我没核实这个 sha 属于哪个仓库、对应什么内容**。 |
| 4 | 旧库是否有**别的** UltraScale GT 包装器 | `rtl/us/eth_phy_10g_us_gt.v` **HTTP 404**（0 字节）；旧库 `rtl/` 平铺、**无 `us/` 子目录**（来源：`/contents/rtl?ref=master` 前 60 项的列表）。我只列了前 60 项，**未全量核对**，所以"旧库没有任何 US GT 包装器"这句**我不下断言**。 |
| 5 | 2 位 `serdes_tx_hdr` → 6 位 `txheader_in` 的**零扩展位置** 与 Xilinx GTY 的 header **字段语义** | 只核实了两侧位宽事实与 PR 的连线方式（§3.4）。**未读 Xilinx GTY 64B66B 文档、未跑仿真。** |
| 6 | PR #96 的**功能/时序**是否真的成立 | **未克隆完整 fork、未跑它的 Makefile、未做任何验证。** 本次只做只读取证。 |
| 7 | taxi 文档站内容 | `https://docs.fpga.taxi/` **未抓取**。 |
| 8 | taxi 是否有 `xcku5p-*-1-*` 的例子 | 我扫了 `src/eth/example/*/fpga/*/Makefile` 的 `FPGA_PART`，36 个唯一值里 `-1` 只有 `xcku3p-ffvb676-1-e`。**未扫 `src/cndm/board/**` / `src/cndm_proto/board/**` 等其它 example 根**，所以"taxi 里没有 KU5P −1 例子"这个结论**限定在 eth example 范围内**。 |
| 9 | taxi 与旧库的**逐文件 diff 关系** | 未做 `diff`（两库命名/语言都变了），所以"taxi = 旧库 + 增量"这句话**未量化**。 |
| 10 | PR #96 的 `fpga_core.v` 里的 UDP 协议栈细节 | 只读了 grep 命中行（MAC/IP/UDP 分层、`local_mac = 48'h02_00_00_00_00_00`）。**未逐行审。** |

---

## 6. 风险清单（问题 C，基于事实）

### 6.1 采用 DEPRECATED + 零 tag 的库，风险是什么？

| 库 | 状态 | tag 数 | HEAD |
|---|---|---|---|
| `alexforencich/verilog-ethernet` | **DEPRECATED**（作者原话："this repo is deprecated and will not receive any future maintenance or support"） | **0**（`/tags` API → `tag count: 0`） | `77320a9…` (2025-02-27, `Add deprecation notice`) |
| `fpganinja/taxi` | 活跃 | **0**（`git tag` → 0） | `cc70b27…` (2026-08-28) |

**风险（按严重度）**：

1. ⭐ **许可风险（最高）**。taxi 的 **10G PHY/MAC 核心全是 `CERN-OHL-S-2.0`**，
   它要求「按请求提供**整个数字设计**的源码，含全部修改/扩展/定制」。
   我们的 10G 数据面一旦链接这些文件，**整个设计**（含我们自己的 UDP/TCP fast-path）
   可能落入互惠范围。**这不是技术问题，是需要法务/商业决策的问题。**
   - 若不可接受 ⇒ 两条出路：(a) 继续用 **MIT 的旧库**（见 §6.2）；(b) 向 `info@fpga.ninja` 买商业许可。
   - **注意**：taxi 里 MIT 的部分**不能代表**我们可以只要 MIT 那部分 —— 我们要的 10G PHY/MAC **恰好在 CERN 那一侧**。
2. **零 release tag** ⇒ 没有"稳定版"语义。taxi 的 10G eth 层**近期仍在变**
   （`2026-08-24/27` 三天内 `Add gearbox delay compensation for BASE-R TX/RX`、`Fix sync signal width`、
   `Update timestamp precision threshold`）。⇒ 钉 commit 后要接受"上游修复我们拿不到（除非手动 forward-port）"。
3. **无 CI 保证对应我们的器件/速度等级**：仓库有 CI，但 CI 是**仿真**（Cocotb + Verilator）；
   「Vivado Standard (enterprise license not required)」只是 KU5P 例子的自述，**没有 −1 速度等级的时序数据点**（见 6.3）。
4. **接口语言变更**：taxi 用 SV interface（`taxi_axis_if`）⇒ 我们的工程需要支持 SV 编译，
   且 MAC 边界从裸 XGMII 变成 AXI-stream（§2.2）—— 移植工作量比"换文件名"大。
5. **`gt_ch_inst` 占位**（§2.7）⇒ 需要自己写薄壳并重新生成 GT IP。

### 6.2 要冻结版本，应该钉哪个 commit？

**取决于路线，两条都列出（我不替你选，因为这是许可+架构决策）**：

| 路线 | 钉哪个 | 理由 | 代价 |
|---|---|---|---|
| **A. 旧库（推荐用于"最小改动接上 64 位 XGMII"）** | **`77320a9471d19c7dd383914bc049e02d9f4f1ffb`**（`verilog-ethernet` master HEAD，2025-02-27） | ⭐ **MIT 许可**（免费商用、无互惠义务）；**裸 XGMII 边界**（`eth_mac_10g.v:81-84`）；**Verilog-2001**；**PR #96 证明 64 位 + KU5P + 156.25MHz 的 GT 例化路子在 XCKU5P 上跑过**（虽然 −2）；`eth_phy_10g.v` 的 `serdes_tx_hdr` 直接对 GT `txheader_in` —— **与我们的 P7a 64 位拓扑同构** | 作者已弃坑、零 tag、零未来修复；PR #96 **未合并**（要用得自己摘，且它带 KCU116 的板级依赖） |
| **B. taxi（用于"长期维护/上游同族"）** | **`cc70b270b910d369ab1ad7b3855e76399fd461f1`**（当前 HEAD，2026-08-28） | 活跃维护；**有 `RK_XCKU5P_F` 例子（同封装/同 quad/同 refclk/同引脚）**；GT 脚本齐全（含 156.25MHz、含 10G/25G、含 async/sync gearbox 两档） | ⚠️ **CERN-OHL-S-2.0 互惠**；**64 位 @10G 必须走 25G 那套**（§2.3）；MAC 边界是 AXI-stream；要写 `gt_ch_inst` 并重生成 GT IP；`FREERUN_FREQUENCY`/`SECONDARY_QPLL`/`RX_EQ_MODE` 与我们不一致 |

> **一条中性的观察**：`RK_XCKU5P_F`（taxi，−2）与 PR #96（KCU116，−2）**都是 −2**。
> **我们这块板是 −1，是整个 −1/−2/−3 里最慢的一档。** 见 6.3。

### 6.3 ⭐ `-1` 速度等级：库/PR 有没有任何时序说明？—— **没有**

**逐字结论：`fpganinja/taxi` 与 PR #96 里，没有任何关于 `-1`（或任何）速度等级的时序说明 / 收口数据 / 警告。**
这一条**本身就是结论**：**需要我们自己跑时序**。

我做的检索与命中（可复现）：

1. `grep -rn -iE 'speed.?grade|xcku5p|ultrascale|KU5P|kintex' --include=*.md --include=*.sv --include=*.tcl README.md docs/ src/eth/`
   ⇒ **`speed.?grade` 零命中**（唯一形似命中是 `downsize`，是 `WNS` 子串的假阳性）。
2. `xcku5p` 的**全部**命中只有 `RK_XCKU5P_F` 的 **`xcku5p-ffvb676-2-e`**（`Makefile` + `README.md`）。
3. taxi README **唯一**给的两个时序收口数据点（第 58 行逐字），**两个都是 `-2`**，且**10G 那个还不是 UltraScale+**：
   ```
   The 10G configuration closes timing on the KC705 (single SFP+, 1 lane total) with an
   XC7K325T -2 at 322.265625 MHz, and the 25G configuration closes timing on the XUSP3S
   (quad QSFP28, 16 lanes total) with an XCVU095 -2 at 402.83203125 MHz.
   ```
   ⇒ 10G 的收口点是 **XC7K325T（7 系列 Kintex-7）**；25G 的收口点是 **XCVU095（Virtex UltraScale+）**。
   **没有任何 XCKU5P（尤其 −1）的时序数据。**
4. PR #96 **完全没有时序报告 / WNS / 资源占用**的记录（9 个文件里没有报告文件，PR body 也没提时序）。

**⚠️ 与我们已知事实的对照（本仓库 `CLAUDE.md`「闸 G」节）**：我们**已经有** KU5P 的真实时序基线 ——
`udp_hls_10g/p6a_ku5p_verify/`：KU5P 在 **8.000ns / 6.400ns** 下 WNS **+0.973 / +0.426**，**setup 失败端点 0**；
但 **hold 余量极薄（+0.013 / +0.012）**。
⇒ 引入 10G MAC/PHY 逻辑后，**hold 会最先出问题**，而**这件事没有任何外部库能替我们保证**。

---

## 7. 复现命令（全部只读，可直接重跑）

```bash
# 元数据（不 clone）
curl -k -s https://api.github.com/repos/fpganinja/taxi
curl -k -s https://api.github.com/repos/alexforencich/verilog-ethernet
curl -k -s https://api.github.com/repos/alexforencich/verilog-ethernet/pulls/96
curl -k -s "https://api.github.com/repos/alexforencich/verilog-ethernet/pulls/96/files?per_page=100"
curl -k -s "https://api.github.com/repos/alexforencich/verilog-ethernet/tags?per_page=100"
curl -k -s "https://api.github.com/repos/alexforencich/verilog-ethernet/commits?per_page=1"

# clone 到临时目录（我们的仓库之外）
cd "$TEMP" && mkdir -p taxi_recon && cd taxi_recon
git clone --quiet https://github.com/fpganinja/taxi.git taxi
cd taxi
git log -1 --format='%H%n%ad%n%an%n%s' --date=iso
git tag | wc -l                       # → 0
git log --all --oneline -- .gitmodules # → 空（无子模块）
git ls-tree -r HEAD | awk '$1=="160000"'  # → 空（无 gitlink）
git ls-files -s | awk '$1=="120000"' | wc -l  # → 165（符号链接）

# PR #96 的文件（按 head sha 取 raw）
SHA=7e570709f2844396ac6e3cc48538c1141175e4a9
for f in ip/gtwizard_ultrascale_0.tcl rtl/fpga.v rtl/fpga_core.v fpga.xdc README.md; do
  curl -k -s "https://raw.githubusercontent.com/lschuermann/verilog-ethernet/$SHA/example/KCU116/fpga_10g/$f"
done

# 我们自己的 P7a 配置（只读）
#   _proj_10g/vivado_prj/p7a_prj.srcs/sources_1/ip/gt_10gbr/gt_10gbr.xci          (822 项参数)
#   _proj_10g/vivado_prj/p7a_prj.gen/sources_1/ip/gt_10gbr/gt_10gbr_stub.v        (端口位宽 + CORE_GENERATION_INFO)

# Vivado preset（加密，只能确认"读不到"；4 个副本已穷举）
find "C:/AMDDesignTools/2025.2" -iname '*GTY-10GBASE-R*'
# → 4 处命中，逐个体检：
for f in \
  "C:/AMDDesignTools/2025.2/Vivado/data/ip/xilinx/gtwizard_ultrascale_v1_7/presets/GTY-10GBASE-R.tcl" \
  "C:/AMDDesignTools/2025.2/data/ip/xilinx/gtwizard_ultrascale_v1_7/presets/GTY-10GBASE-R.tcl" \
  "C:/AMDDesignTools/2025.2/data/ip/xilinx/gt_subcore_ip_v1_0/presets/GTY-10GBASE-R.tcl" \
  "C:/AMDDesignTools/2025.2/data/ip/xilinx/gtwizard_ultrascale_v1_6/presets/GTY-10GBASE-R.tcl" ; do
  printf "%s | %s B | " "$f" "$(wc -c < "$f")"
  head -c 200 "$f" | LC_ALL=C grep -q '[^[:print:][:space:]]' && echo ENCRYPTED || echo TEXT
done
# → 4/4 ENCRYPTED
```

---

## 8. 最终一句话

**taxi 存在、活跃、有等价的 10G PHY+MAC、甚至有几乎同款的 KU5P 板级例子 —— 但它是 `CERN-OHL-S-2.0`（强互惠），
不是 MIT；而「PR #96 的 gtwizard 配置与 P7a 逐项一致」这句话不准确：
核心工作点（10.3125 / 156.25 / 64 位 / 64B66B_ASYNC）一致，但有 7 项明确不一致、2 项因 preset 加密无法核实，
且 PR #96 用的是 −2 速度等级、板子也不同。**
