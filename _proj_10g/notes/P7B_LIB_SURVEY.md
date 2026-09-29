# P7b 前置调研：`alexforencich/verilog-ethernet` 能否补上 GT ↔ XGMII 那一层

- 调查日期：2026-09-29 ｜ **只读侦察**（本笔记是本轮唯一写入的文件）
- 调查对象：`https://github.com/alexforencich/verilog-ethernet`
- **被调查的快照**：commit **`77320a9471d19c7dd383914bc049e02d9f4f1ffb`**（master HEAD，2025-02-27，commit message = `Add deprecation notice`）
- 检索用的 clone（**在仓库外**）：`C:\Users\zhxue\AppData\Local\Temp\ve_recon\ve`（shallow，depth 50）
  - 下文所有 `rtl/...`、`example/...` 路径都相对**该 clone 的仓库根**；行号锚定在上面那个 commit。
  - 另 fetch 了 PR #96 的 head 到本地 ref `pr96`（`git show pr96:<path>` 可读）。
- 网络说明：`WebFetch` 对 `github.com` / `raw.githubusercontent.com` **被挡**（"Unable to verify if domain ... is safe to fetch"）；
  `curl -k https://api.github.com/...` 与 `git clone`（需 `-c http.schannelCheckRevoke=false`）**可用**。
  本笔记所有非仓库结论都来自 **GitHub API 原始 JSON** 或 **UG578 / issue 原文**，无推测成分；推测处已单独标注。

---

## 0. 结论速览（先读这 7 条）

1. **许可 = MIT，商用免费**，无专利条款、无额外署名条款；唯一义务是保留版权与许可声明（§1）。
2. ⭐ **"GTY gearbox ↔ 干净 XGMII"这一层它已经有了**，而且是**两层都有**：
   - `rtl/eth_phy_10g.v` = **GTY gearbox ↔ XGMII**（我们要的那一层，XGMII 侧 = `xgmii_txd[63:0]` + `xgmii_txc[7:0]`）
   - `rtl/eth_mac_10g.v` = XGMII MAC（IFG / preamble / SFD / FCS / padding 全都有）
   - 作者本人对 PCS 归属的定性（issue #33）：**"Xilinx 7 series and newer do not have hard 64b/66b PCS
     logic, so there is nothing to bypass. … So yes, it is a fully custom PCS in soft logic."**
3. ⚠️ **但它吃的 header 是 2 位，不是 6 位**：`HDR_WIDTH` 硬校验 == 2；block type 由**库自己编码进 64 位数据**，
   GTY 的 `txheader[5:0]` 只用了低 2 位。`rxdatavalid` / `rxheadervalid` / `rxstartofseq` / `txsequence`
   **在库里"只连不读"**（§3.4 有全仓 grep 证据）。
4. ⚠️ **最容易踩的坑 = header 位序**：库内部 `SYNC_DATA=2'b10 / SYNC_CTRL=2'b01`，
   而 IEEE 64b/66b 与 Xilinx 例子是 `2'b01`=data ⇒ 必须靠 **`BIT_REVERSE=1`** 翻转对齐。
   VCU108 与 **KU5P（KCU116）** 两份板级 wrapper 都写死 `BIT_REVERSE(1)`（§3.3）。
   这一条如果不照抄，现象是"block lock 永远锁不上 / 收到全是 error"，且与 P7a 的 PRBS 通路表现完全不同。
5. 🎁 **有 KU5P 的现成参考（未合并 PR）**：**PR #96** 为 **XCKU5P-2FFVB676E**（KCU116，与我们是同一封装/同一器件族）
   加了 10G 例子，gtwizard 配置与我们的 P7a **逐项一致**（preset `GTY-10GBASE-R` / 10.3125 GBd / 156.25 MHz /
   USER+INT DATA_WIDTH=64 / QPLL0）。**但 state=open、merged=False ⇒ 不在 master 里**（§3.6）。
6. ⚠️ **仓库已被作者标记 DEPRECATED**（HEAD 那次 commit 就是加弃用声明），由 `fpganinja/taxi` 接续；
   **仓库里一个 release tag 都没有**（§2）。
7. **依赖极干净**：PHY 那 11 个文件 + MAC 那 3 个文件**全部自包含**，只需 `rtl/lfsr.v`；
   **不需要 `lib/axis`**（FCS 也是用 `lfsr` 配 Galois/CRC-32 做的，不是外部 CRC 模块）。移植体量 **4305 行 / 14 文件**（§7）。

---

## 1. 许可（问题 1）

### 1.1 原文（`COPYING`，仓库根）

```
Copyright (c) 2014-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

- **这就是逐字的 MIT 许可**（只换了版权人/年份）。**无专利条款、无第三方署名要求、无商用限制、无 copyleft。**
- 作者文件 `AUTHORS` 仅一行：`Alex Forencich <alex@alexforencich.com>`。
- 与标准 MIT 模板的**唯一差别是版权人/年份**；**没有任何附加段落**（无专利授权、无署名、无出口条款）。

### 1.2 交叉印证与逐文件情况

| 项 | 值 | 证据 |
|---|---|---|
| GitHub API 许可判定 | `name: "MIT License"`, `spdx_id: "MIT"` | `curl -k https://api.github.com/repos/alexforencich/verilog-ethernet` |
| 每文件头 | 同 MIT 全文，仅年份区间不同 | 例：`rtl/eth_phy_10g.v:1-23` = `Copyright (c) 2018 Alex Forencich` + MIT 全文；`example/VCU108/fpga_10g/rtl/eth_xcvr_phy_wrapper.v:3` = `Copyright (c) 2021-2023` |
| README 有无额外条款 | **无**。README 里**没有** License 节（`grep -i "^## License" README.md` 无命中）⇒ 全部以 `COPYING` 为准 | 本地 clone |
| 依赖 `lib/axis` | 同为 MIT（`lib/axis/COPYING` 逐字相同） | 本地 clone |

### 1.3 商用结论

**可以免费商用**。合规动作只有一条：**把我们复制进项目的那些 `.v` 文件保留其头部 MIT 声明，
并在我们的分发物（若对外分发）中附 `COPYING` 全文**。对内部自用（不分发）零义务。
不要求开源我们的衍生代码。

> 与我们的现实相关性：我们**不分发**这块板的设计，所以实际义务 = **保留文件头注释不改**。
> 建议：把 librtl 放在独立目录（如 `_proj_10g/third_party/verilog_ethernet/`）并在该目录放一份 `COPYING`，
> 便于将来审计"哪几行不是我们写的"。

---

## 2. 版本、体积、tag（问题 2）

| 项 | 值 | 证据 |
|---|---|---|
| 默认分支 | `master` | API `default_branch`；`git rev-parse --abbrev-ref HEAD` |
| **HEAD commit** | **`77320a9471d19c7dd383914bc049e02d9f4f1ffb`** | `git log -1` |
| HEAD 日期 | **2025-02-27 15:50:25 -0800** | 同上 |
| HEAD message | **`Add deprecation notice`** | 同上 |
| `pushed_at`（末次推送） | `2025-02-27T23:50:33Z` | API |
| `created_at` | `2014-11-19T22:04:53Z` | API |
| ⚠️ **release tag** | **一个都没有** —— `git ls-remote --tags` 输出为空，API `/tags` 与 `/releases` 也都返回空数组 | 三路一致 |
| 仓库体积 | API `size` = **5444**（KB，≈5.3 MB，GitHub 的打包口径）；本地 shallow clone（depth 50）= 工作树 **15 MB** + `.git` **1.6 MB** | API + `du -sh` |
| 规模 | `rtl/` 下 **98 个 `.v`**（扁平，无子目录）；`example/` 下 ~25 个板卡例子 | `ls rtl/*.v \| wc -l` |
| 热度 | 3109 stars / 857 forks；`archived: false` | API |

### 2.1 ⚠️ 弃用声明原文（README 第 11-13 行）

> `## Deprecation Notice`
>
> `This repository is superseded by https://github.com/fpganinja/taxi.  All new features and bug
> fixes will be applied there, and commercial support is also available.  As a result, this repo is
> deprecated and will not receive any future maintenance or support.`

**对我们的含义（诚实评估）**：
- 好消息：**我们只需要它的既有代码，不需要它继续维护**。P7b 是一次性取用。
- 坏消息：**如果我们踩到 bug，上游不会修**；`archived: false` 但已声明不再维护。
- 后手：接续项目 `fpganinja/taxi` 存在（**本轮未核实其许可、是否含同一层 PHY、是否仍是 MIT —— 见 §9 未核实清单**）。
  若采用本库且后续需要长期维护，值得再花一轮调研 `taxi`。

---

## 3. 模块对照表 + gearbox↔XGMII 代码摘录（问题 3 —— 本轮重点）

### 3.1 模块对照表（我们的需求 → 该库的哪个文件）

| # | 我们需要的东西 | 库的文件 / 模块 | 证据（文件:行） |
|---|---|---|---|
| 1 | **GTY gearbox ↔ 干净 XGMII**（P7b 的核心） | `rtl/eth_phy_10g.v`（模块 `eth_phy_10g`） | `rtl/eth_phy_10g.v:34-88`（参数与端口）；XGMII 侧 `xgmii_txd[DATA_WIDTH-1:0]` + `xgmii_txc[CTRL_WIDTH-1:0]`（:57-60），`HDR_WIDTH` 默认 **2**（:38） |
| 2 | XGMII(64+8) ↔ 64b/66b 编解码（block type 压缩/还原） | `rtl/xgmii_baser_enc_64.v` / `rtl/xgmii_baser_dec_64.v` | enc:81-130 / dec:81-130 的 `BLOCK_TYPE_*` 表；enc:264 `{encoded_ctrl, BLOCK_TYPE_CTRL}` |
| 3 | 64b/66b **加扰 / 解扰**（58 位 LFSR） | `rtl/eth_phy_10g_tx_if.v` / `rtl/eth_phy_10g_rx_if.v`（内部例化 `rtl/lfsr.v`） | tx_if:135-149（`LFSR_WIDTH(58)`, `LFSR_POLY(58'h8000000001)`, `REVERSE(1)`）；rx_if:158-172（同参数，`FEED_FORWARD(1)`=解扰） |
| 4 | **block lock / 对齐 / `rxgearboxslip` 的产生** | `rtl/eth_phy_10g_rx_frame_sync.v` | :67-69 `SYNC_DATA/SYNC_CTRL`；:96-125 bitslip 状态机；:118 拉高 bitslip |
| 5 | 高 BER 监视（125 µs 窗口） | `rtl/eth_phy_10g_rx_ber_mon.v` | 参数 `COUNT_125US`（`eth_phy_10g.v:46` = 125000/6.4 = 19531） |
| 6 | 坏块 / 序列错 / watchdog 复位请求 | `rtl/eth_phy_10g_rx_watchdog.v` | rx_if:260-274 例化；输出 `serdes_rx_reset_req` |
| 7 | XGMII MAC（IFG / preamble / SFD / FCS / padding） | `rtl/eth_mac_10g.v`（内部 = `rtl/axis_xgmii_rx_64.v` + `rtl/axis_xgmii_tx_64.v` + ctrl） | eth_mac_10g.v:219（rx64）、:245（tx64）；tx64:108-109 `ETH_PRE/ETH_SFD`、:124 `STATE_IFG`、:439 IFG 下界 12、:346 `{ETH_SFD,{6{ETH_PRE}},XGMII_START}` |
| 8 | 一站式的 "MAC+PHY + SERDES 口" | `rtl/eth_mac_phy_10g.v`（及 `_fifo` 版） | :60-140 端口：AXIS 上/下行 + `serdes_tx_data/tx_hdr/rx_data/rx_hdr/rx_bitslip/rx_reset_req` |
| 9 | 10G/25G 通用 | 同一套文件靠参数切 32/64 位与 10G/25G | `eth_mac_10g.v:217 if (DATA_WIDTH == 64)` |
| 10 | 板级/器件适配（**不在 `rtl/` 里**） | `example/*/rtl/eth_xcvr_phy_wrapper.v`（每板一份）；KU5P 见 PR #96 的 `example/KCU116/fpga_10g/rtl/fpga.v` | 见 §3.2 |

> **第 10 行是本轮最重要的结构性发现**：库把**厂商 GT 例化**排斥在 `rtl/` 之外，
> 每个板卡在 `example/<BOARD>/rtl/` 里自己接。**没有** `*_xilinx.v` / `*_gtwizard*.v` 这种"通用 Xilinx 适配文件"。
> 全仓 `grep -li gtwiz` 只命中 `example/*/rtl/eth_xcvr_phy_wrapper.v` 与 `example/*/ip/eth_xcvr_gt.tcl`。
> 对我们的含义：**那 40 行左右的 GT 接线要我们照抄+改引脚**，库不会替我们做（好在有 KU5P 版可抄，§3.6）。

### 3.2 `eth_phy_10g` 的 SERDES 侧接口（= 我们要对接 GTY 的那一面）

`rtl/eth_phy_10g.v:34-88`（摘录）：

```verilog
module eth_phy_10g #
(
    parameter DATA_WIDTH = 64,
    parameter CTRL_WIDTH = (DATA_WIDTH/8),
    parameter HDR_WIDTH = 2,                 // ← 注意：2，不是 6
    parameter BIT_REVERSE = 0,
    parameter SCRAMBLER_DISABLE = 0,
    parameter PRBS31_ENABLE = 0,
    parameter TX_SERDES_PIPELINE = 0,
    parameter RX_SERDES_PIPELINE = 0,
    parameter BITSLIP_HIGH_CYCLES = 1,
    parameter BITSLIP_LOW_CYCLES = 8,
    parameter COUNT_125US = 125000/6.4
)
(
    input  wire                  rx_clk, rx_rst, tx_clk, tx_rst,
    /* XGMII interface */
    input  wire [DATA_WIDTH-1:0] xgmii_txd,    // 64 位数据
    input  wire [CTRL_WIDTH-1:0] xgmii_txc,    //  8 位控制
    output wire [DATA_WIDTH-1:0] xgmii_rxd,
    output wire [CTRL_WIDTH-1:0] xgmii_rxc,
    /* SERDES interface */
    output wire [DATA_WIDTH-1:0] serdes_tx_data,
    output wire [HDR_WIDTH-1:0]  serdes_tx_hdr,      // ← 2 位！
    input  wire [DATA_WIDTH-1:0] serdes_rx_data,
    input  wire [HDR_WIDTH-1:0]  serdes_rx_hdr,      // ← 2 位！
    output wire                  serdes_rx_bitslip,     // → GT 的 rxgearboxslip
    output wire                  serdes_rx_reset_req,   // → GT 的 reset_rx_datapath
    /* Status */
    output wire tx_bad_block, output wire [6:0] rx_error_count,
    output wire rx_bad_block, output wire rx_sequence_error,
    output wire rx_block_lock, output wire rx_high_ber, output wire rx_status,
    /* Configuration */
    input  wire cfg_tx_prbs31_enable, cfg_rx_prbs31_enable
);
```

**⇒ 回答"它是不是就是把 Xilinx GT + 64b/66b gearbox 包成干净 XGMII 的那一层"：是。**
XGMII 侧正是 **64 位 data + 8 位 ctrl**，SERDES 侧是 `(64 位 data + 2 位 hdr)` + `bitslip` + `reset_req`。

### 3.3 Xilinx 适配层怎么接（VCU108 版，`example/VCU108/fpga_10g/rtl/eth_xcvr_phy_wrapper.v`）

声明（:110-116）：

```verilog
wire [5:0]  gt_txheader;      // ← 6 位
wire [63:0] gt_txdata;
wire        gt_rxgearboxslip;
wire [5:0]  gt_rxheader;      // ← 6 位
wire [1:0]  gt_rxheadervalid; // ← 声明了，后面只连不读
wire [63:0] gt_rxdata;
wire [1:0]  gt_rxdatavalid;   // ← 声明了，后面只连不读
```

gtwizard 例化（:153-155、:170-174）：

```verilog
        .gtwiz_userdata_tx_in(gt_txdata),
        .txheader_in(gt_txheader),        // 上 4 位无人驱动
        .txsequence_in(7'b0),             // ← 恒 0
        ...
        .rxgearboxslip_in(gt_rxgearboxslip),
        .gtwiz_userdata_rx_out(gt_rxdata),
        .rxdatavalid_out(gt_rxdatavalid),   // ← 连了，不读
        .rxheader_out(gt_rxheader),
        .rxheadervalid_out(gt_rxheadervalid), // ← 连了，不读
        .rxstartofseq_out()                 // ← 悬空
```

PHY 例化（:266-303，**关键三行**）：

```verilog
eth_phy_10g #(
    .DATA_WIDTH(DATA_WIDTH), .CTRL_WIDTH(CTRL_WIDTH), .HDR_WIDTH(HDR_WIDTH),
    .BIT_REVERSE(1),              // ★★★ 必须 = 1（Xilinx GTY 的 header/data 位序是反的）
    .SCRAMBLER_DISABLE(0), .PRBS31_ENABLE(PRBS31_ENABLE),
    ...
) phy_inst (
    ...
    .serdes_tx_data(gt_txdata),
    .serdes_tx_hdr(gt_txheader),     // ★ 2 位输出口 → 6 位网线，Verilog 端口位宽截断：
                                     //   gt_txheader[1:0] 被驱动，[5:2] 无驱动（综合成常 0）
    .serdes_rx_data(gt_rxdata),
    .serdes_rx_hdr(gt_rxheader),     // ★ 反向：只驱动 [1:0]
    .serdes_rx_bitslip(gt_rxgearboxslip),   // ★ bitslip → rxgearboxslip
    .serdes_rx_reset_req(phy_rx_reset_req), //   → gt_reset_rx_datapath (:105)
    ...
);
```

复位（:104-105、:248-264）：`gt_reset_rx_datapath = phy_rx_reset_req`（把 PHY 的 reset_req 接到 GT 的 RX datapath reset）；
`tx_reset_sync_inst` / `rx_reset_sync_inst` 用 `sync_reset #(.N(4))`（`lib/axis`），`rst = !gt_reset_tx_done` / `!gt_reset_rx_done`。

### 3.4 ⭐ 它怎么处理那 6 个器件专用信号（逐条，附全仓证据）

先把**全仓级**的负面证据摆出来（这是本轮最"值钱"的一条）：

```bash
# 在仓库根执行（含 example/ 全部板卡）
$ grep -rn "rxdatavalid\|rxheadervalid\|rxstartofseq\|txsequence" --include=*.v .
./example/ADM_PCIE_9V3/fpga_25g/rtl/eth_xcvr_phy_wrapper.v:114:wire [1:0] gt_rxheadervalid;
./example/ADM_PCIE_9V3/fpga_25g/rtl/eth_xcvr_phy_wrapper.v:116:wire [1:0] gt_rxdatavalid;
./example/ADM_PCIE_9V3/fpga_25g/rtl/eth_xcvr_phy_wrapper.v:155:        .txsequence_in(7'b0),
./example/ADM_PCIE_9V3/fpga_25g/rtl/eth_xcvr_phy_wrapper.v:172:        .rxdatavalid_out(gt_rxdatavalid),
./example/ADM_PCIE_9V3/fpga_25g/rtl/eth_xcvr_phy_wrapper.v:174:        .rxheadervalid_out(gt_rxheadervalid),
...
```

⇒ **这四个信号在整个库里只出现在"声明"和"接到 GT 端口"两种位置，从无被读取。**
`rtl/` 目录**一次都没出现过**这四个名字。

KU5P 版（PR #96，`example/KCU116/fpga_10g/rtl/fpga.v`）同样：
`sfp_0_gt_rxdatavalid` 只在 :336（声明）与 :455（接 GT 输出）出现；`sfp_0_gt_rxheadervalid` 只在 :334 与 :467。

| 信号 | 库怎么处理 | 证据 |
|---|---|---|
| `txheader[5:0]` | **只用低 2 位**（sync header）。上 4 位无驱动 ⇒ 综合常数 0 | 见 §3.3；`eth_phy_10g.v:66` 端口就是 `[HDR_WIDTH-1:0]` = 2 位 |
| `txheader` 的取值 | **由库自己算**：数据块 = `SYNC_DATA`，控制块 = `SYNC_CTRL` | `xgmii_baser_enc_64.v:201-204`（`encoded_tx_hdr_next = SYNC_DATA`）、:271（`= SYNC_CTRL`） |
| `rxheader[5:0]` | **只取低 2 位**（端口位宽截断），先位反转再当 sync header 用 | `eth_phy_10g_rx_if.v:104-106`（反转）、`xgmii_baser_dec_64.v:203`（`if (encoded_rx_hdr[0] == 0)` 判 data） |
| `rxheadervalid` | **完全不读** | §3.4 全仓 grep |
| `rxdatavalid` | **完全不读** | 同上 |
| `rxgearboxslip` | 由 `eth_phy_10g_rx_frame_sync` 产生（有节流，不是裸脉冲） | `eth_phy_10g_rx_frame_sync.v:91-125`；默认 `BITSLIP_HIGH_CYCLES=1` / `BITSLIP_LOW_CYCLES=8` |
| block lock / 对齐 | **纯 FPGA 逻辑**：数连续合法 sync header（6 位计数器 `sh_count` 满 = 锁），连续非法则失锁 + slip | `eth_phy_10g_rx_frame_sync.v:96-125` |
| 位反转 | 参数 `BIT_REVERSE`，**同时**作用于 64 位 data 与 2 位 hdr（整字逐位反转） | `eth_phy_10g_rx_if.v:99-110`、`eth_phy_10g_tx_if.v:95-106` |
| `txsequence[6:0]` | **恒 0** | VCU108 wrapper:155 / KCU116 fpga.v:416（`.txsequence_in({4{7'b0}})`） |

> **与本板 P7a 的交叉印证（我方证据）**：我们自己生成的 Xilinx 例子
> `_proj_10g/rtl/gt_10gbr_example_stimulus_64b66b_async.v:105-106` 写着
> ```
> // This module does not drive protocol-specific behavior when the gearbox is used, so tie txheader to the "data" type
> assign txheader_out = 6'b000001;
> ```
> 以及 `:111-112`：`// txsequence is not used for 64B/66B async gearbox data transmission when a wide user data width is used`
> / `assign txsequence_out = 7'd0;`
> ⇒ **Xilinx 官方在 64B66B_ASYNC + 宽用户位宽下，也把 txheader 恒接 "data"（低 2 位 = `2'b01`）、txsequence 恒 0。**
> 这与库的做法在**位序上完全一致**（见 §3.5 的换算），并且说明 **block type 确实要由 fabric 自己放进 64 位数据里**
> （因为 GT 在 "data" header 下不会替我们生成 block type）——这正是 `xgmii_baser_enc_64.v` 干的事。

### 3.5 ⭐⭐ header 位序：库内约定 vs IEEE/Xilinx（**最关键的换算**）

**库内部约定**（`xgmii_baser_dec_64.v:111-113` 与 `xgmii_baser_enc_64.v:110-112` 都有）：

```verilog
localparam [1:0]
    SYNC_DATA = 2'b10,
    SYNC_CTRL = 2'b01;
```

**IEEE 64b/66b 的 sync header 恰好相反**：data = `2'b01`，control = `2'b10`。
**Xilinx 例子 `6'b000001` 的低 2 位 = `2'b01` = data** ⇒ 与 IEEE 一致，与**库内约定相反**。

⇒ 因此必须有 `BIT_REVERSE=1` 把 2 位 header 翻转：

| 环节 | 值（数据块） | 值（控制块） |
|---|---|---|
| 库内部 `encoded_tx_hdr` | `SYNC_DATA` = `2'b10` | `SYNC_CTRL` = `2'b01` |
| 经 `BIT_REVERSE=1` 反转后 `serdes_tx_hdr` | `2'b01` | `2'b10` |
| GTY `txheader[1:0]` 收到的 | **`2'b01` = data** ✔ 与 IEEE/Xilinx 一致 | **`2'b10` = ctrl** ✔ |
| Xilinx 官方例子 `6'b000001` 的低 2 位 | **`2'b01` = data** ✔ 对得上 | （例子不产生控制块） |

RX 方向同理反向：GTY 的 `rxheader[1:0]`（IEEE 序）→ `BIT_REVERSE=1` 翻成库内部序
→ `frame_sync` 用 `SYNC_DATA=2'b10` 判 data、`dec_64` 用 `encoded_rx_hdr[0]==0` 判数据块。

> **这条是本轮"自己写最容易错"的第一名。** 如果我们照抄库但把 `BIT_REVERSE` 留默认 0，
> 现象会是：`rx_block_lock` 永远为 0 / `rx_error_count` 暴涨 / XGMII 全是 `XGMII_ERROR`。
> 而且**与 P7a 的表现完全不同**（P7a 走 PRBS，不需要 sync header 语义），
> 所以**不能拿 P7a 的 0 错来推断这一层也对**。

### 3.6 ⭐ RX 侧怎么从 gearbox 接口恢复出 XGMII 控制字符（/S/ /T/ /I/ /E/ /Q/）

**两级流水，各管一半**：

**第 1 级 —— `eth_phy_10g_rx_if.v`：把 GT 的"数据+2 位 header"变成"已解扰的 64b/66b 码块"**
（:93-110 位反转 → :139-172 用 58 位 LFSR 解扰 → :204-227 打拍输出 `encoded_rx_data` / `encoded_rx_hdr`）。
注意解扰是**无条件**做的（除非 `SCRAMBLER_DISABLE=1`），Xilinx 的 async gearbox **不解扰**。

**第 2 级 —— `xgmii_baser_dec_64.v`：把 64b/66b 码块还原成 XGMII 的 8 字节 + 8 位控制**
（`xgmii_baser_dec_64.v:80-130` 定义了两套常量；`:150-400` 是译码体）

XGMII 侧的字符（:81-94）：
```verilog
XGMII_IDLE = 8'h07,  XGMII_LPI = 8'h06,  XGMII_START = 8'hfb,
XGMII_TERM = 8'hfd,  XGMII_ERROR = 8'hfe, XGMII_SEQ_OS = 8'h9c, ...
```
64b/66b 侧的 block type（:114-130，注释直接画出每个 block 的字节布局）：
```verilog
BLOCK_TYPE_CTRL     = 8'h1e, // C7 C6 C5 C4 C3 C2 C1 C0 BT
BLOCK_TYPE_OS_4     = 8'h2d, // D7 D6 D5 O4 C3 C2 C1 C0 BT
BLOCK_TYPE_START_4  = 8'h33, // D7 D6 D5    C3 C2 C1 C0 BT
BLOCK_TYPE_OS_START = 8'h66, // D7 D6 D5    O0 D3 D2 D1 BT
BLOCK_TYPE_OS_04    = 8'h55, // D7 D6 D5 O4 O0 D3 D2 D1 BT
BLOCK_TYPE_START_0  = 8'h78, // D7 D6 D5 D4 D3 D2 D1    BT
BLOCK_TYPE_OS_0     = 8'h4b, // C7 C6 C5 C4 O0 D3 D2 D1 BT
BLOCK_TYPE_TERM_0   = 8'h87, // C7 C6 C5 C4 C3 C2 C1    BT
BLOCK_TYPE_TERM_1   = 8'h99, // C7 C6 C5 C4 C3 C2    D0 BT
BLOCK_TYPE_TERM_2   = 8'haa, // C7 C6 C5 C4 C3    D1 D0 BT
BLOCK_TYPE_TERM_3   = 8'hb4, // C7 C6 C5 C4    D2 D1 D0 BT
BLOCK_TYPE_TERM_4   = 8'hcc, // C7 C6 C5    D3 D2 D1 D0 BT
BLOCK_TYPE_TERM_5   = 8'hd2, // C7 C6    D4 D3 D2 D1 D0 BT
BLOCK_TYPE_TERM_6   = 8'he1, // C7    D5 D4 D3 D2 D1 D0 BT
BLOCK_TYPE_TERM_7   = 8'hff, //    D6 D5 D4 D3 D2 D1 D0 BT
```

**判据在 `:203`（先用 1 位做粗判，为了省 fanin）**：
```verilog
    // use only four bits of block type for reduced fanin
    if (encoded_rx_hdr[0] == 0) begin            // data 块：直通
        xgmii_rxd_next = encoded_rx_data;
        xgmii_rxc_next = 8'h00;
        rx_bad_block_next = 1'b0;
    end else begin
        case (encoded_rx_data[7:4])              // 控制块：按 block type 高 4 位分发
            BLOCK_TYPE_CTRL[7:4]:     begin ... xgmii_rxc_next = 8'hff; ... end
            BLOCK_TYPE_START_0[7:4]:  begin      // D7 D6 D5 D4 D3 D2 D1    BT
                xgmii_rxd_next = {encoded_rx_data[63:8], XGMII_START};   // ← 生成 /S/
                xgmii_rxc_next = 8'h01;
                rx_sequence_error_next = frame_reg;   // ← 帧中又来 START = 序列错
                frame_next = 1'b1;
            end
            BLOCK_TYPE_TERM_7[7:4]:   begin      //    D6 D5 D4 D3 D2 D1 D0 BT
                xgmii_rxd_next = {XGMII_TERM, encoded_rx_data[63:8]};    // ← 生成 /T/
                xgmii_rxc_next = 8'h80;
                rx_sequence_error_next = !frame_reg;  // ← 帧外见 TERM = 序列错
                frame_next = 1'b0;
            end
            ...
```

**恢复机理一句话总结**（这是它最漂亮的地方）：
> 每个 64b/66b 控制块只有 **7 个载荷字节 + 1 个 block type 字节**，而 XGMII 一轮要 **8 个字节 + 8 位控制**。
> 差额正好由 **block type 自己补上**：block type 的**低 5 位**编码"控制字符在第几车道"（`_0`..`_7` 后缀），
> 于是控制块用 8 个字节中的 1 个装 block type，剩下的 7 个字节按 block type 指出的位置**插入**控制字符
> （START→`0xfb`、TERM→`0xfd`、IDLE→`0x07`、ERROR→`0xfe`、有序集→`0x9c`），
> 其余字节位置照抄数据。**所以 /S/ /T/ /I/ /E/ /Q/ 不是从 block type 查表"翻译"出来的，而是 block type
> 决定"哪个车道是控制字符、其余车道原样放数据"**，两套 7 位编码（`CTRL_IDLE=7'h00` 等，:96-105）负责
> 控制字符的紧凑表示。
> `frame_reg`（:140、:234、:279、:300-357）**同时**充当"帧内/帧外"状态，用来产生
> `rx_sequence_error`（帧中见 START、帧外见 TERM）。

**编码方向**在 `xgmii_baser_enc_64.v:201-272`：`xgmii_txc == 8'h00` ⇒ 数据块；
否则按 `xgmii_txc`/`xgmii_txd` 的具体组合（`:206` OS 在 lane4、`:222` START 在 lane0、
`:230-261` TERM 在 lane0..7、`:262` 全控制）选 block type，最后 **`:271 encoded_tx_hdr_next = SYNC_CTRL;`**。
`tx_bad_block` 在"没有对应 block 格式"时拉高（`:266-269`）。

**位反转对 XGMII 数据的影响**：`BIT_REVERSE=1` 把 64 位整字逐位反转 ⇒ XGMII 的 **byte lane 0（bits[7:0]）
跑到 GT 的 bits[63:56]**。这是 Xilinx gearbox "MSB first / lane 0 先上线路"的必然要求，
也解释了为什么 Xilinx 自己的 checker 也要 `assign rxdata_int[i] = rxdata_in[63-i];`
（我方证据：`_proj_10g/rtl/gt_10gbr_example_checking_64b66b_async.v:89-99`，注释写着
"Bit-reverse the rxdata_int assignment to accomodate any differences between transmitter and receiver user
interface data widths, since gearbox modes transmit data MSb first."）。

### 3.7 KU5P（KCU116）参考设计的接线与时钟（PR #96，`example/KCU116/fpga_10g/rtl/fpga.v`）

**与我们 P7a 的配置对照**（`example/KCU116/fpga_10g/ip/gtwizard_ultrascale_0.tcl` 全文）：

```tcl
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gtwizard_ultrascale_0
set_property -dict [list CONFIG.preset {GTY-10GBASE-R}] [get_ips gtwizard_ultrascale_0]
set_property -dict [list \
    CONFIG.CHANNEL_ENABLE {X0Y11 X0Y10 X0Y9 X0Y8} \
    CONFIG.TX_MASTER_CHANNEL {X0Y8}  CONFIG.RX_MASTER_CHANNEL {X0Y8} \
    CONFIG.TX_LINE_RATE {10.3125}   CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.TX_USER_DATA_WIDTH {64}  CONFIG.TX_INT_DATA_WIDTH {64} \
    CONFIG.RX_LINE_RATE {10.3125}   CONFIG.RX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_USER_DATA_WIDTH {64}  CONFIG.RX_INT_DATA_WIDTH {64} \
    CONFIG.RX_REFCLK_SOURCE {X0Y11 clk0 X0Y10 clk0 X0Y9 clk0 X0Y8 clk0} \
    CONFIG.TX_REFCLK_SOURCE {X0Y11 clk0 X0Y10 clk0 X0Y9 clk0 X0Y8 clk0} \
    CONFIG.FREERUN_FREQUENCY {125} \
    CONFIG.ENABLE_OPTIONAL_PORTS {rxpolarity_in txpolarity_in} \
] [get_ips gtwizard_ultrascale_0]
```

**时钟与复位（fpga.v）**：
- `IBUFDS_GTE4`（:255-261）→ `BUFG_GT`（:263-271）得到参考钟；
- **`BUFG_GT bufg_gt_tx_usrclk_inst`（:273-281）把 `gt_txclkout[0]` 引出来，`:283 assign clk_156mhz_int = gt_txusrclk;`**
  —— **PHY 的 `tx_clk` 就是 GT 自己的 TX usrclk**，**没有独立 MMCM**（与 KCU116 板上的 300 MHz 系统钟无关）；
- RX 每通道：`BUFG_GT`（:299-307）把 `gt_rxclkout[n]` 引成 `gt_rxusrclk[n]`，`:482 assign sfp_0_rx_clk_int = gt_rxusrclk[0];`
  —— **PHY 的 `rx_clk` = 该通道恢复时钟**；
- 复位：`:249 wire gt_tx_reset = ~((&gt_txprgdivresetdone) & (&gt_txpmaresetdone));`、`:250 wire gt_rx_reset = ~&gt_rxpmaresetdone;`
  然后 `sync_reset #(.N(4))` 同步进各域（:321-328、:484-491），`rst = !gt_reset_tx_done` / `!gt_reset_rx_done`；
- **`eth_phy_10g` 例化（:493-512）与 VCU108 逐项相同：`BIT_REVERSE(1)`、`serdes_tx_hdr(sfp_0_gt_txheader)`（6 位网线）、
  `serdes_rx_bitslip(sfp_0_gt_rxgearboxslip)`**。KCU116 版**没有**接 `serdes_rx_reset_req`（悬空）。

**KCU116 README 里的两条与我方直接相关的话**（`git show pr96:.../README.md`）：
- `*  FPGA: XCKU5P-2FFVB676E` / `*  PHY: 10G BASE-R PHY IP core and internal GTY transceiver`
- "The reference clock for the GTY transceiver connected to the SFPs is generated by an external, on-board
  **Si5328** clock chip which must be configured to output **156.25MHz** before the transceiver can be used."
  ⇒ 该板的 156.25 MHz 需要软件配置；**我们板上是硬件晶振 Y2，已经在 P7a 证明可用**，这一条对我们是白送的。

---

## 4. MAC 的能力与帧流接口（问题 4）

### 4.1 能力清单（`rtl/eth_mac_10g.v` + `rtl/axis_xgmii_tx_64.v` / `_rx_64.v`）

| 能力 | 有/无 | 证据 |
|---|---|---|
| XGMII 接口 | ✅ 64 位 data + 8 位 ctrl | `eth_mac_10g.v:82-86`（`xgmii_rxd/rxc/txd/txc`, `CTRL_WIDTH=DATA_WIDTH/8`）|
| Preamble + SFD 生成 | ✅ | `axis_xgmii_tx_64.v:108-109`（`ETH_PRE=8'h55`、`ETH_SFD=8'hD5`）、`:346`（`{ETH_SFD,{6{ETH_PRE}},XGMII_START}`）|
| IFG | ✅ **端口可配**，**下界强制 12 字节** | `eth_mac_10g.v:150 input wire [7:0] cfg_ifg`；`axis_xgmii_tx_64.v:439`（`cfg_ifg > 8'd12 ? cfg_ifg : 8'd12`）；`:124 STATE_IFG` |
| Deficit Idle Count (DIC) | ✅ | 参数 `ENABLE_DIC=1`（`eth_mac_10g.v:40`）；`ifg_count_next` 里含 `deficit_idle_count_reg`（tx64:439）|
| FCS 计算 + 插入 (TX) | ✅ | `axis_xgmii_tx_64.v:189-208`：用 `lfsr` 配 `LFSR_WIDTH(32)/LFSR_POLY(32'h4c11db7)/LFSR_CONFIG("GALOIS")/REVERSE(1)`（实例名 `eth_crc`），初值 `crc_state = 32'hFFFFFFFF`；`:236-289` 按末尾空字节数选 FCS 输出拍 |
| FCS 校验 (RX) | ✅ 并输出坏帧标志 | `axis_xgmii_rx_64.v:148`（`crc_state = 32'hFFFFFFFF`）、`:262-266`/`:290-294`（CRC 不合法 ⇒ `tuser_next[0]=1'b1` + `error_bad_fcs_next=1'b1`）|
| Padding 到 64 字节 | ✅ | 参数 `ENABLE_PADDING=1`（`eth_mac_10g.v:39`）、`MIN_FRAME_LENGTH=64`（:41）|
| tkeep / tlast 处理 | ✅ | `KEEP_WIDTH=DATA_WIDTH/8`；`keep2empty` 函数（tx64:212-225）；`m_axis_tlast` 在 `rx_axis_tlast_int` |
| 暂停帧 / PFC | ✅ 但**默认关**（参数 `PFC_ENABLE=0` / `PAUSE_ENABLE=0`）| `eth_mac_10g.v:50-51`、`:186 MAC_CTRL_ENABLE = PAUSE_ENABLE \|\| PFC_ENABLE`、`:349 if (MAC_CTRL_ENABLE) begin : mac_ctrl` ⇒ **默认不例化** `mac_ctrl_*` / `mac_pause_ctrl_*` |
| PTP 时间戳 | ✅ 但默认关（`PTP_TS_ENABLE=0`）| `eth_mac_10g.v:43-49` |
| 帧间 `tvalid` 保证 | ❌ **不保证拉低** —— 唯一保证是 `tlast=1` | issue #87 维护者原话（§7）|

### 4.2 帧流接口（`rtl/eth_mac_10g.v:60-79`）

```verilog
    /* AXI input  (TX) */
    input  wire [DATA_WIDTH-1:0]    tx_axis_tdata,   // 64
    input  wire [KEEP_WIDTH-1:0]    tx_axis_tkeep,   //  8
    input  wire                     tx_axis_tvalid,
    output wire                     tx_axis_tready,
    input  wire                     tx_axis_tlast,
    input  wire [TX_USER_WIDTH-1:0] tx_axis_tuser,   // 默认 1 位
    /* AXI output (RX) */
    output wire [DATA_WIDTH-1:0]    rx_axis_tdata,   // 64
    output wire [KEEP_WIDTH-1:0]    rx_axis_tkeep,   //  8
    output wire                     rx_axis_tvalid,
    output wire                     rx_axis_tlast,
    output wire [RX_USER_WIDTH-1:0] rx_axis_tuser,   // 默认 1 位
```
`TX_USER_WIDTH` / `RX_USER_WIDTH` 默认展开式（:48-49）= `... + 1` ⇒ **默认各 1 位**。
`rx_axis_tuser[0]` 的语义 = **1 表示"坏帧"**（FCS 错或帧结构错）：
`axis_xgmii_rx_64.v:247 / :264 / :283 / :292`。
另有两个独立状态输出：`rx_error_bad_frame`、`rx_error_bad_fcs`（`eth_mac_10g.v:126-127`）。

### 4.3 与我们 `tdata[63:0]/tkeep/tlast/tcrs/terr` 的差异（差多少 = 胶水量）

| 维度 | 我们的合同（CLAUDE.md「MAC 字流接口规范」+ `rtl/mac_rx_64.v:66-73`） | 库（AXIS） | 差异 |
|---|---|---|---|
| 数据位宽 | `tdata[63:0]` | `tx/rx_axis_tdata[63:0]` | **相同** ✅ |
| **字节序** | **`tdata[63:56]` = 帧首字节**（字内从高到低） | **`tdata[7:0]` = 帧首字节**（标准 AXIS；证据：`axis_xgmii_tx_64.v:369 :409 xgmii_txd_next = s_tdata_reg;` 与 `axis_xgmii_rx_64.v:208 m_axis_tdata_next = xgmii_rxd_d1;` —— **AXIS 字节道与 XGMII 车道 1:1**，而 XGMII lane0 = `txd[7:0]` = 线上首字节) | ⚠️ **8 字节车道反转**（64 位逐位/逐字节镜像）—— 需要一层 shim |
| keep | `tkeep[7:0]`，SOP 字恒满 | `tkeep[7:0]` 标准 AXIS | 语义**近似**；我们"TLAST 字高位有效"= 标准 AXIS 一致 ⚠️（需实测边界） |
| last | `tlast` | `tlast` | 相同 ✅ |
| FCS 正确性 | `tcrs`（**1 = FCS 正确**） | `rx_axis_tuser[0]`（**1 = 坏帧**） | ⚠️ **极性相反**；AND 我们的 `tcrs` 只在 TLAST 有效 |
| 帧内错误 | `terr`（rx_er / 帧被中止） | 合并进 `tuser[0]`；细分看 `rx_error_bad_frame` / `rx_error_bad_fcs` 状态输出 | ⚠️ 语义粒度不同 |
| SOP 标记 | `tuser` = SOP | **没有**（AXIS 靠"上帧的 tlast"隐式界定） | 我们多一路边带；适配时 `tuser = (上一拍 tlast \|\| 复位)` |
| 坏帧是否转发 | 我们**转发**（带 `tcrs=0`） | `eth_mac_10g`（无 FIFO 版）**转发**（`tuser=1`）；`eth_mac_10g_fifo` **默认丢弃** | ⚠️ 选型注意 |
| 帧间 tvalid | 我们的合同未规定；数据面按 TLAST 完整性处理 | **不保证拉低**（issue #87） | ⚠️ 我们的下游若假定"帧间至少一拍 tvalid=0"会中招 |

**结论：差异是"1 层 shim"，不是"重写"**。shim 需要做 4 件事：
① 64 位字节车道镜像（3 行 generate）；② `tcrs = ~tuser[0]`（+ 只在 TLAST 采样）；
③ `terr` 从 `rx_error_bad_frame`/`rx_error_bad_fcs` 合成；④ `tuser(SOP)` 由上一拍 TLAST 生成。
约 **60-100 行**。反向（TX 侧）同样 4 件事，其中 TX 没有 SOP 概念（库靠 tvalid 起帧）⇒ 更简单。

---

## 5. 它支持的 GT 配置 vs 我们的 P7a（问题 5）

### 5.1 三方逐项对照（**这是采用可行性的硬判据**）

| 配置项 | **我们 `_proj_10g/tcl/build_p7a.tcl`** | 库 `example/VCU108/fpga_10g/ip/eth_xcvr_gt.tcl` | 库 PR#96 `example/KCU116/.../gtwizard_ultrascale_0.tcl` | 对得上？ |
|---|---|---|---|---|
| 器件 | `xcku5p-ffvb676-1-e` | VCU108 = VU9P（UltraScale+ GTY） | **XCKU5P-2FFVB676E（同封装同族）** | ✅（KU5P 那列） |
| preset | （逐项显式设） | `GTY-10GBASE-R` | `GTY-10GBASE-R` | ✅ |
| 编码 | `TX_DATA_ENCODING {64B66B_ASYNC}` | 由 preset 隐含（async gearbox） | 同 | ✅ |
| 线速率 | 10.3125 | `set line_rate {10.3125}` | `10.3125` | ✅ |
| Refclk | 156.25 MHz，`REFCLK_SOURCE {X0Y4 clk0 X0Y5 clk0}` | `set refclk_freq {156.25}` | `156.25`，4 通道都 `clk0` | ✅ |
| PLL | `TX/RX_PLL_TYPE {QPLL0}` | `extra_pll_ports = {qpll0lock_out}` | QPLL0（preset） | ✅ |
| USER_DATA_WIDTH | 64 | `set user_data_width {64}` | `64` | ✅ |
| INT_DATA_WIDTH | 64 | `set int_data_width $user_data_width` = 64 | `64` | ✅ |
| FREERUN | （未逐项核） | `set freerun_freq {125}` | `125` | ✅ |

⇒ **配置层零冲突：只需把库的那段 gtwizard tcl 换成我们已有的 `gt_10gbr`，或把我们的 tcl 参数抄进库的流程。**
（更省事的做法：**保留我们自己的 `gt_10gbr` IP 不动，只从库里取 `eth_phy_10g` 那一层** —— 见 §7 推荐。）

### 5.2 参数含义与我们该怎么设

| 参数 | 含义（读源码得） | 证据 | **我们该设** |
|---|---|---|---|
| `DATA_WIDTH` | XGMII 数据位宽，**硬校验必须 == 64** | `eth_phy_10g_rx_if.v:81-85 $error("Interface width must be 64")` | **64** |
| `CTRL_WIDTH` | XGMII 控制位宽 = `DATA_WIDTH/8` | `eth_phy_10g.v:37` | **8**（别传，默认式即可） |
| `HDR_WIDTH` | sync header 位宽，**硬校验必须 == 2** | `eth_phy_10g_rx_if.v:87-90`、`xgmii_baser_dec_64.v:75-78` | **2**（默认） |
| `BIT_REVERSE` | 64 位 data 与 2 位 hdr **整字逐位反转** | `eth_phy_10g_tx_if.v:95-106`、`rx_if.v:99-110` | ⭐ **1**（KU5P 实测配方，§3.3/§3.7） |
| `SCRAMBLER_DISABLE` | 1 = 旁路 58 位加扰/解扰（GT 内部代替时用；Xilinx async gearbox **不加扰**，所以要 0） | tx_if:176 / rx_if:207 | **0** |
| `PRBS31_ENABLE` | 1 = 数据通路换成 PRBS31（取代 64b/66b 数据），用于 BERT | tx_if:170-174 / rx_if:210-223 | **0**（P7b 要做业务，不是 BERT） |
| `TX_SERDES_PIPELINE` / `RX_SERDES_PIPELINE` | SERDES 侧额外打拍级数（时序吃紧时加） | tx_if:108-131 / rx_if:112-135 | 先 **0**；若 156.25 MHz 布线下不过再试 1 |
| `BITSLIP_HIGH_CYCLES` / `_LOW_CYCLES` | `rxgearboxslip` 拉高拍数 / 拉高后**静默拍数**（节流） | `eth_phy_10g_rx_frame_sync.v:91-125` | **1 / 8**（默认）。⭐ 与 UG578 的要求一致：slip 只能 1 拍、再断言前至少空 1 拍、且要留处理时间（§6） |
| `COUNT_125US` | BER 监视窗口计数（125 µs / UI） | `eth_phy_10g.v:46` = 125000/6.4 = **19531** | 默认（=19531，正好对应 156.25 MHz 下 6.4 ns/UI） |
| `GT_TYPE` | —— | **本库不存在此参数**：全仓 `grep -rn "GT_TYPE\|GT_REFCLK" --include=*.v --include=*.tcl .` **无命中** | 不适用（若你印象里有，可能是别的库，如 `taxi`/`corundum`） |
| `GT_REFCLK` | —— | 同上，**不存在** | 不适用 |

> ⚠️ **注意 `GT_TYPE` / `GT_REFCLK` 在本库中不存在**。我按你问题里的名字全仓检索（`.v` + `.tcl`），
> **零命中**，所以没有编造"它的含义"。库的做法是：**GT 完全交给板级 `example/*/ip/*.tcl` 生成**，
> `rtl/` 层只认 `serdes_*` 抽象口。

---

## 6. 已知坑：GitHub issues 检索结果（问题 6）

### 6.1 检索方法（可复现）

```bash
# 关键：WebFetch 对 github.com 被挡；用 API + curl -k
curl -sS -k "https://api.github.com/search/issues?q=repo:alexforencich/verilog-ethernet+gearbox&per_page=30"
curl -sS -k "https://api.github.com/search/issues?q=repo:alexforencich/verilog-ethernet+rxdatavalid&per_page=15"
# 关键词逐个人工过：gearbox / rxdatavalid / rxgearboxslip / UltraScale / KU5P / 156.25 /
#                    10GBASE-R / block+lock / PCS / timing+closure
```
命中与结论：

| issue | 标题 / 状态 | 关键词命中 | **结论（对我们有用的一句）** |
|---|---|---|---|
| **#261** | `From ZCU102 Porting to KC705` / **open**（2025-08-08）| `rxdatavalid` + `rxgearboxslip` **唯一双命中** | 用户把 GTY 换成 7 系列 GTX 后链路不通。**维护者答复：`The PHY in this repo does not support the 7-series transceivers. I recommend using the Xilinx 10G PCS/PMA core instead.`** ⇒ **反证：本库 PHY 支持的是 UltraScale/UltraScale+ 那一档的 async gearbox，正是我们的 KU5P GTY。** 另外该 issue 里贴出的 gtwizard 端口**只有 `[1:0] rxheader`**（7 系列），与我们的 `[5:0]` 不同，进一步说明我们抄 KU5P/VCU108 版才对。 |
| **#96** | `Add Xilinx Kintex UltraScale+ KCU116 board` / **PR, open, merged=False** | `UltraScale` | **本轮最大的意外收获**：为 **XCKU5P-2FFVB676E** 加 10G 例子的 PR，作者自述已用 DAC/单模/多模全部跑通（原话：`Turns out my SFP+ was broken. It now works on all ports with DACs, Singlemode and Multimode.`）。**未合并** ⇒ 需从 fork `lschuermann/verilog-ethernet` 分支 `dev/kcu116-support`（sha `7e570709f2844396ac6e3cc48538c1141175e4a9`）取。**维护者未给拒绝理由**，PR 自述是因"没有该硬件"的惯例。 |
| **#217** | `About 10g ethernet` / closed | `UltraScale`/`8'b156.25 族` | 维护者定性：**`The current 10G PHY implementation requires the transceiver to support the asynchronous gearbox mode.`** ⇒ 支持面 = async gearbox（我们有）。该 issue 的最终结论是"**板子坏了**"（用户原话 `Solved. The board is flawed.`）—— 提醒我们：这类问题的第一嫌疑人常常是硬件/模块。 |
| **#33** | `Bypass Xilinx PCS?` / open | `PCS` | ⭐ 维护者：**`Xilinx 7 series and newer do not have hard 64b/66b PCS logic, so there is nothing to bypass. The most they do that is 64b/66b specific is the 64:66 gearboxes. So yes, it is a fully custom PCS in soft logic.`** ⇒ **明确了"GT 只给 gearbox，其余 PCS 全在软逻辑"的架构分工**，也是 `eth_phy_10g` 存在的理由。 |
| **#87** | `Receiving broken packets in U50` / open | `block+lock` | ⭐⭐ **两条直接可用的坑**：① 维护者：**`The only thing guaranteed between packets is tlast = 1.`**（**帧间 tvalid 不保证拉低** —— 我们的下游若假定"帧间有空拍"会中招）；② 维护者：**`the only signal that indicates link status is the block lock signal from the PHY, but even that is not 100% reliable as it is only looking at the sync headers and it can sometimes be fooled by the transceiver DFE when there is no input signal present.`** ⇒ **别用 `rx_block_lock` 当"链路在"判据；用 `rx_status`**（issue #229 里维护者也这么说）。 |
| **#229** | `export to ku060`（UltraScale KU060）/ open | `10GBASE-R`/`block+lock`/`156.25` | 用户报"`phy_rx_block_lock=1` 且 QPLL0 lock=1 但以太网不 link"。维护者：**`The rx_status signal is more reliable than rx_block_lock, so look at that one.`** ⇒ 排查口径同 #87。 |
| **#181** | `PHY MAC latency` / open | `gearbox` | 256 位参考：纯 `eth_mac_10g_fifo` 对接 ≈ **270-300 ns**，整设计 ≈ 550 ns。维护者说延迟**不容易降**，计划改用 **synchronous gearbox**（"should also significantly improve latency"），但"not going to happen for a few more months"（2024-01 说的，**到弃用为止未见落地**）。⇒ 若我们对延迟敏感（行情通路！），**要有"每跳 tens of ns"的心理预期**，并自行实测。 |
| #224 / #252 / #67 / #2 | 各种板卡问题 | — | 与 gearbox/对齐/复位序列**无关**或信息量低，未逐条展开（#224 是 ADM-PCIE-9V3 例子不通；#2 是未声明信号）。 |

### 6.2 我们应当额外注意的（来自 UG578，非 issue）

`RXGEARBOXSLIP` 的器件级约束（来源：AMD UG578 *UltraScale Architecture GTY Transceivers*，经 WebSearch 命中 docs.amd.com 正文）：
- RX gearbox 输出**不保证对齐**，对齐必须在 **interconnect 逻辑**里用 `RXGEARBOXSLIP` 做；
- **`RXGEARBOXSLIP` 必须只断言 1 个 `RXUSRCLK2` 周期，且再次断言前至少空 1 拍**；
  "If multiple realignments occur in rapid succession, it is possible to **pass the proper alignment point without recognizing it**"；
- 且 **slip 被处理需要若干周期**才能看到稳定的 `RXDATA/RXHEADER`；
- **解扰与 block sync 都在 FPGA 逻辑里做**（所以库自己带 58 位解扰器 + frame_sync 是对的）。

> ⇒ 库的默认 `BITSLIP_HIGH_CYCLES=1` / `BITSLIP_LOW_CYCLES=8` **正好满足** UG578 的"1 拍 + 至少空 1 拍 + 留处理时间"。
> **这是库在器件手册层面站得住的一条**（也是我们自己写时最容易写成"连续 slip"的地方）。

---

## 7. 采用 / 部分采用 / 不采用：推荐与移植代价（问题 7）

### 7.1 推荐：**部分采用 —— 只取 PHY 那一层（`eth_phy_10g` 子树），MAC 是否取用另定**

理由（按重要性排序）：

1. ⭐ **它正好填的是我们唯一的空缺**：P7a 已经证明 **GT + gearbox 硬件通路 OK**（BER 上界 4.997e-13），
   缺的只是"gearbox 风格接口 ↔ 干净 XGMII"这段软逻辑。`eth_phy_10g` + `xgmii_baser_*` + `lfsr`
   就是这段，且**作者本人把它定义为 "fully custom PCS in soft logic"（#33）**。
2. ⭐ **KU5P 上已被别人跑通**：PR #96（同器件 XCKU5P-FFVB676E、同 preset、同 156.25 MHz、`BIT_REVERSE(1)`）
   —— 省掉我们从头踩 header 位序/slip 节流/block lock 参数这一整类坑。
3. ✅ **依赖极干净、许可干净**：PHY 子树 **11 个文件、2469 行（含 447 行的 `lfsr.v`）**，
   **全部在 `rtl/`、零外部依赖**（连 `lib/axis` 都不需要；`sync_reset` 只在板级 wrapper 里用，我们自己已有复位方案）。
   MIT，保留文件头即可。
4. ✅ **接口干净、不侵入我们的架构**：`eth_phy_10g` 只要求 `tx_clk/rx_clk/tx_rst/rx_rst` + 一个 64+8 的 XGMII 口。
   **它不要求我们的数据面换时钟、不要求 AXIS、不碰我们的 FIFO/快照窗口。**
   这正好契合 P6b 已验收的架构（数据面在独立 156.25 MHz 域）。

**明确不推荐的两件事**：
- ❌ **不推荐整库照搬（连 `udp_complete_64` 等一起）** —— 那是另一套协议栈，与我们已验收的 64 位数据面重复，
  且会带来一大堆 `lib/axis` 依赖与命名冲突。我们要的是 **PCS/PMA 那一层**，不是它的 UDP/IP。
- ❌ **不推荐为了它去改用 `xxv_ethernet`/其它 IP** —— P7a 已实测 `IS_LOCKED=1` 被 license 挡，本库恰好绕开这点。

### 7.2 移植代价估计

**必须纳入的文件（PHY-only 最小集，全部来自 `rtl/`）**：

| # | 文件 | 行数 | 作用 |
|---|---|---|---|
| 1 | `rtl/eth_phy_10g.v` | 142 | 顶层（XGMII ↔ serdes） |
| 2 | `rtl/eth_phy_10g_rx.v` | 149 | RX：rx_if + dec_64 |
| 3 | `rtl/eth_phy_10g_tx.v` | 127 | TX：enc_64 + tx_if |
| 4 | `rtl/eth_phy_10g_rx_if.v` | 278 | 位反转 + 解扰 + frame_sync/ber_mon/watchdog |
| 5 | `rtl/eth_phy_10g_tx_if.v` | 183 | 位反转 + 加扰 |
| 6 | `rtl/eth_phy_10g_rx_frame_sync.v` | 146 | block lock + bitslip（`rxgearboxslip`） |
| 7 | `rtl/eth_phy_10g_rx_ber_mon.v` | 124 | 高 BER 监视 |
| 8 | `rtl/eth_phy_10g_rx_watchdog.v` | 172 | 坏块/序列错 → reset_req |
| 9 | `rtl/xgmii_baser_enc_64.v` | 284 | XGMII → 64b/66b |
| 10 | `rtl/xgmii_baser_dec_64.v` | 417 | 64b/66b → XGMII |
| 11 | `rtl/lfsr.v` | 447 | 加扰/解扰 + CRC（共享） |
| | **小计** | **2469** | **11 个文件，零外部依赖** |

**可选加上（如果我们连 MAC 也用它的）**：

| # | 文件 | 行数 |
|---|---|---|
| 12 | `rtl/eth_mac_10g.v` | 731 |
| 13 | `rtl/axis_xgmii_rx_64.v` | 449 |
| 14 | `rtl/axis_xgmii_tx_64.v` | 656 |
| | **小计** | **1836** |
| | **合计** | **4305 行 / 14 文件** |

> ⚠️ `eth_mac_10g.v` 里还有 **32 位分支**（`:283/:310` 例化 `axis_xgmii_rx_32/tx_32`）。
> 我们固定 64 位时该 generate 分支不展开，**理论上不必带那两个文件**，但**未实测 xelab 是否要求模块存在**（见 §9）。
> `mac_ctrl_*` / `mac_pause_ctrl_*`（4 文件 1403 行）由 `:349 if (MAC_CTRL_ENABLE)` 门控，
> 默认 `PFC_ENABLE=0/PAUSE_ENABLE=0` ⇒ **不例化，可以不取**。

**我们要自己写的胶水（这是采用与否的真正成本）**：

| # | 胶水 | 估计 | 说明 |
|---|---|---|---|
| G1 | GT 接线（~40 行） | **直接抄** `example/KCU116/fpga_10g/rtl/fpga.v:236-512` 的模式，把 `gt_10gbr` 换进去 | ⚠️ 抄的时候 **`BIT_REVERSE(1)`、`serdes_tx_hdr` 接 6 位网线、`bitslip→rxgearboxslip`** 三处一处都不能改 |
| G2 | 时钟方案决策 | **需要拍板**（0 行代码，但是架构决策） | 库的做法（KCU116）= **PHY 的 `tx_clk` 用 GT 的 TX usrclk、`rx_clk` 用恢复时钟**，**数据面直接跑在这两个域上，无 MMCM**。我们的 P6b 是**数据面独立 156.25 MHz（Y1 经 MMCM）+ `rtl/fifo_async.v` 跨域**。两条路都可行：(a) 沿用库的做法（最省事，但要改我们 P6b 的时钟树）；(b) **保留 P6b 时钟树**，在 XGMII 口与数据面之间再放一级我们已有的 `fifo_async`（推荐 —— 零回归，代价是一个 FIFO）。⚠️ 选 (b) 时注意 GT 的 TX usrclk 与 MMCM 的 156.25 MHz 是**异源**的，必须靠 FIFO 吸收 ppm 差。 |
| G3 | 复位方案 | ~20 行 | 抄 `sync_reset #(.N(4))` + `rst = !gt_reset_tx_done/rx_done`（KCU116 fpga.v:321-328、:484-491）。我们也可以换成自己的复位风格（`fifo_async` 已带本域同步释放）。 |
| G4 | **帧流 shim**（XGMII↔我们的 `tdata/tkeep/tlast/tcrs/terr`） | **~60-100 行** | 4 件事：① 64 位字节车道镜像；② `tcrs = ~tuser[0]`（TLAST 采样）；③ `terr` 合成；④ TX 侧反向（含 SOP 处理）。**若只取 PHY 就完全不需要这一层**。 |
| G5 | 链路状态判据 | ~5 行 | 用 `rx_status`（**不是** `rx_block_lock`，见 §6.1 #87/#229） |
| G6 | 验证 | **这是最大的一块** | 建议门：① xsim 里用 2 位 header 的"假 GT"做环回（把我们 P7a 的 PRBS 通路换成真帧流）；② 板级先跑"SFP A↔B 自环 + 我们自己的图案"，判据用**逐字节比对 + 帧计数对账**（照 P6b/P7a 的验收风格）；③ **务必加一条"故意把 BIT_REVERSE 设错"的负对照**，证明这条判据有判别力（否则可能重演"测了个恒真的量"）。 |

**总工作量粗估**：
- 取 PHY-only：**胶水 ~80-150 行 + 时钟/复位决策 + 验证**。**没有需要重新发明的算法**。
- 取 PHY+MAC：**胶水 ~150-250 行**（多 G4 的两向 shim）+ 读 1836 行 MAC 代码。
  好处是 IFG/preamble/FCS/padding 直接白得（我们自己在 1G 侧写过 `mac_rx_64/mac_tx_64`，
  但 10G 的 XGMII 版本我们**没有**，那部分自写大约 400-600 行且有 CRC/IFG 时序坑）。
  ⇒ **如果 P7b 的目标是"尽快让 10G 线上跑起真帧"，取 PHY+MAC 更划算**；如果只想先打通物理/对齐层，取 PHY-only。

### 7.3 一句话建议

> **采用（部分采用）**：把 `rtl/` 的 **PHY 子树（11 文件）** 纳入 `_proj_10g/third_party/`，
> 照 PR #96 的 KU5P 接线抄 GT 胶水（**`BIT_REVERSE(1)` / `serdes_tx_hdr` 接 6 位 / `bitslip→rxgearboxslip`**），
> 时钟上**保留我们 P6b 的 156.25 MHz 数据面**、用我们已有的 `rtl/fifo_async.v` 跨到 GT 域；
> MAC 层**视 P7b 的目标**决定是否同时纳入 `eth_mac_10g.v`（+3 文件 1836 行）。
> 全程**不需要** `lib/axis`、**不需要**换 IP、**不需要**动我们已验收的数据面。

---

## 8. 未核实清单（**这些我确实没查到 / 没查，不要当成结论**）

1. **`fpganinja/taxi`** —— 接续项目。**未访问、未核实**其许可、是否含同一层 PHY、API 是否兼容本库。
   若长期维护是考量，需单独一轮调研。（`pushed_at` 之后本库无新提交，弃用声明是最后一次改动。）
2. **32 位分支是否必须带** —— `eth_mac_10g.v` 固定 `DATA_WIDTH=64` 时，
   `axis_xgmii_rx_32/tx_32` 所在 generate 分支不展开；**但我没有实际跑 xelab 验证"模块缺失是否报错"**。
   取 MAC 时要实测（或用 `verilog_define`/裁剪把 32 位分支删掉）。
3. **`rxdatavalid` 在 64B66B_ASYNC + 64 位下是否恒为 1** —— 我**没有从器件手册正文找到明文**。
   现有**间接证据**（注意是推理，不是原文）：
   - 库在 VCU108/KCU116 两处都"只连不读"，且 KCU116 是有人在 KU5P 上跑通的；
   - 我们自己的 P7a 生成物 `gt_10gbr_example_checking_64b66b_async.v:106-107` 写着
     `// For 64B/66B async gearbox mode data reception, the PRBS checker is always enabled` /
     `wire prbs_any_chk_en_int = 1'b1;` —— **Xilinx 官方 checker 也是无条件每拍校验、不用 `rxdatavalid`**，
     而该设计在 P7a 实测 600 s / 6.003e12 bit **零错**。
   ⇒ 推理是"该配置下 fabric 侧每拍都有效、无空洞"。**但这是推理**；采用时应加一条**板级守卫**
   （例如计数器统计 `|rxdatavalid` 与总拍数，两者不等即报警），成本很低。
4. **库的 10G MAC 的吞吐/时序能否在 `-1` 速度等级 156.25 MHz 收敛** —— 未综合、未跑时序。
   已知参考：本仓闸 G 里 KU5P `-1` 在 6.4 ns 下 WNS **+0.426 / 0 失败端点**（我们自己的数据面），
   但那不含 XGMII MAC。**库的 MAC（`axis_xgmii_tx_64` 有 8 路并行 CRC + 大 case，组合较深）是新增的时序风险点。**
   ⇒ 建议：先做"加入 MAC 后的 6.4 ns 时序探针"，再决定 MAC 是否整合进同一时钟域。
5. **PR #96 的代码是否与我们 `-1` 速度等级兼容** —— PR 的 XDC 写的是 `xcku5p-ffvb676-**2**-e`，
   我们是 `-1`。功能应无差，但**时序/是否需重跑未核实**。
6. **`eth_mac_10g` 的 `tkeep`/边角语义是否与我们的"TLAST 字高位有效 + SOP 恒满"逐位等价** ——
   我只核到"库用标准 AXIS keep、byte lane 与 XGMII 1:1"（§4.3），**没有**逐拍对照过边界（例：0 载荷帧、
   单字节帧、`tkeep` 非连续的情况）。取 MAC 时必须单独立一条边界门。
7. **本库的 `rx_error_bad_frame` 具体覆盖哪些情形**（是否包含"帧内非法控制字符"等）—— 未逐行核实。
8. **UG578 的两条引用**（`RXGEARBOXSLIP` 1 拍 + 至少空 1 拍；slip 需处理时间）来自**WebSearch 命中的
   docs.amd.com 正文摘要**，**我未下载/未逐页核对 UG578 原文的章节号与表格号**（WebFetch 对 amd.com 未测试）。
   若要把这条写进我们的设计依据，建议补一次原文核对。
9. **`eth_phy_10g_rx_watchdog.v` / `ber_mon` 的门限值的物理含义**（`COUNT_125US` 之外是否还有别的常数）
   —— 只读了端口例化，未读判定逻辑内部。

---

## 9. 附：本轮可复现的取证命令

```bash
# 0) clone（必须在仓库外；本机 schannel 需要关吊销检查）
cd /c/Users/zhxue/AppData/Local/Temp/ve_recon
git -c http.schannelCheckRevoke=false clone --depth 50 https://github.com/alexforencich/verilog-ethernet.git ve
cd ve
git log -1 --format='%H%n%ad%n%s'          # → 77320a9... / 2025-02-27 / Add deprecation notice
cat COPYING                                 # → MIT
grep -rn "rxdatavalid\|rxheadervalid\|txsequence\|rxstartofseq" --include=*.v .   # → 只连不读

# 1) PR #96（KU5P 参考）：fetch 到本地 ref 后直接 git show
git -c http.schannelCheckRevoke=false fetch origin refs/pull/96/head:pr96 --depth 1
git show pr96:example/KCU116/fpga_10g/ip/gtwizard_ultrascale_0.tcl
git show pr96:example/KCU116/fpga_10g/rtl/fpga.v > /c/Users/zhxue/AppData/Local/Temp/ve_recon/kcu116_fpga.v
git show pr96:example/KCU116/fpga_10g/fpga.xdc
git show pr96:example/KCU116/fpga_10g/README.md

# 2) issue 检索（WebFetch 对 github.com 被挡 ⇒ 走 API）
curl -sS -k "https://api.github.com/repos/alexforencich/verilog-ethernet"                # license/size/stars
curl -sS -k "https://api.github.com/repos/alexforencich/verilog-ethernet/tags"           # → 空
curl -sS -k "https://api.github.com/repos/alexforencich/verilog-ethernet/releases"       # → 空
curl -sS -k "https://api.github.com/search/issues?q=repo:alexforencich/verilog-ethernet+gearbox&per_page=30"
curl -sS -k "https://api.github.com/repos/alexforencich/verilog-ethernet/issues/261"     # #33/#87/#96/#217/#229 同理
```

---

---

# TL 追加：加扰器 / 同步头 / 块锁（2026-09-29 追加）

> 就 `%TEMP%\ve_recon` 现成 clone 查，锚定同一 commit `77320a9471d19c7dd383914bc049e02d9f4f1ffb`。
> 本节回答 TL 的四个决定性问题；另起 §TL-6 汇总本轮**新增**的未核实项。
> 上下文（由 TL 提供、我未独立复核）：官方 `w2_pcs64_baser` 内嵌 GT 与 `gt_10gbr` 配置逐项相同而其 fabric 面是 XGMII；
> P7a 板级实测 `rxdatavalid[1:0]` 恒 `2'b11`、`rxheader` 恒 `0x01`、`rxheadervalid` 恒 1。

## TL-1 ⭐⭐ 加扰器：**有，在 soft logic 里，就是 10GBASE-R 的 x⁵⁸+x³⁹+1** ⇒ **GT 不做加扰，我们必须自己写**

### (a) 多项式与种子逐字命中 —— 库自己的文档把这条多项式**命名为 "64b66b scrambler"**

`rtl/lfsr.v:111`（`lfsr` 模块的 `LFSR_POLY` 文档正文里，原文）：
```
Fibonacci style (example for 64b66b scrambler, 0x8000000001)
```
`rtl/lfsr.v:137`：
```
Fibonacci feed-forward style (example for 64b66b descrambler, 0x8000000001)
```
`rtl/lfsr.v:101`（多项式的书写约定）：
```
Note that the largest term (x^32) is suppressed.  This term is generated automatically based
on LFSR_WIDTH.
```
⇒ `LFSR_WIDTH(58)` + `LFSR_POLY(58'h8000000001)` 读作 **x⁵⁸ + x³⁹ + x⁰ = x⁵⁸ + x³⁹ + 1**（首项 x⁵⁸ 由 `LFSR_WIDTH` 自动生成）。
我另用 Python 验算 `0x8000000001` 的置位 = **bit 39 与 bit 0**，非首项正好是 x³⁹ 与 x⁰ ✔。

**TX 侧（加扰器）** —— `rtl/eth_phy_10g_tx_if.v:135-149`：
```verilog
lfsr #(
    .LFSR_WIDTH(58),
    .LFSR_POLY(58'h8000000001),
    .LFSR_CONFIG("FIBONACCI"),
    .LFSR_FEED_FORWARD(0),          // ← 反馈式 = 加扰器
    .REVERSE(1),
    .DATA_WIDTH(DATA_WIDTH),
    .STYLE("AUTO")
)
scrambler_inst (
    .data_in(encoded_tx_data),
    .state_in(scrambler_state_reg),
    .data_out(scrambled_data),
    .state_out(scrambler_state)
);
```
种子 —— `rtl/eth_phy_10g_tx_if.v:78`：
```verilog
reg [57:0] scrambler_state_reg = {58{1'b1}};
```
= **58 位全 1**（Python 验算 `(1<<58)-1 = 0x3FFFFFFFFFFFFFF`），即 802.3 的加扰器初始值 ✔。

**RX 侧（解扰器）** —— `rtl/eth_phy_10g_rx_if.v:158-172`：同 `LFSR_WIDTH/POLY/REVERSE`，但 **`LFSR_FEED_FORWARD(1)`**。
按 `rtl/lfsr.v:132-137` 的文档，feed-forward 即 **"self-synchronous descrambler"**，
与 10GBASE-R 规定的**自同步**解扰器一致 ✔。种子 `rtl/eth_phy_10g_rx_if.v:144` 同为 `{58{1'b1}}`。

### (b) 位置：**在编码器之后**（回答"加在编码器之前还是之后"）

TX 顺序链（自 `rtl/eth_phy_10g_tx.v` 往下读）：
```
xgmii_txd / xgmii_txc
  → eth_phy_10g_tx.v:92   xgmii_baser_enc_64   （XGMII → 64b/66b 块，产 encoded_tx_data / encoded_tx_hdr）
  → eth_phy_10g_tx.v:107  eth_phy_10g_tx_if    （加扰 + 位反转）
        tx_if:135-149  58 位加扰器（data_in = encoded_tx_data）
        tx_if:176      serdes_tx_data_reg <= SCRAMBLER_DISABLE ? encoded_tx_data : scrambled_data;
        tx_if:177      serdes_tx_hdr_reg  <= encoded_tx_hdr;      // ★ 同步头【不加扰】
  → tx_if:108-131       SERDES_PIPELINE（可选打拍）→ tx_if:95-106 BIT_REVERSE
  → serdes_tx_data / serdes_tx_hdr
```
⇒ **`serdes_tx_data` 上 = "已编码(64b/66b 块) **且已加扰**"**，`serdes_tx_hdr` = **未加扰的同步头**（合乎 802.3：同步头不参与加扰）。

RX 是镜像：`eth_phy_10g_rx_if.v:93-137`（先位反转）→ `:158-172` + `:204-227`（解扰 + 打拍）
→ `eth_phy_10g_rx.v:131` `xgmii_baser_dec_64`（64b/66b → XGMII）。

### (c) `SCRAMBLER_DISABLE`：**有，默认 0；13 个板级 wrapper 全部显式传 0**

- 声明（**均默认 `= 0`**）：`rtl/eth_phy_10g.v:40`、`rtl/eth_phy_10g_tx.v:40`、`rtl/eth_phy_10g_rx.v:40`、
  `rtl/eth_phy_10g_tx_if.v:39`、`rtl/eth_phy_10g_rx_if.v:39`。
- 生效点：`tx_if:176` / `rx_if:207`（`SCRAMBLER_DISABLE ? encoded_* : scrambled/descrambled_*`）。
- **全仓 13 个板卡 wrapper 一律 `.SCRAMBLER_DISABLE(0)`**（`grep -rn "SCRAMBLER_DISABLE" --include=*.v .`）：
  ADM_PCIE_9V3:271、Alveo:271、DCS7132LB:271、ExaNIC_X10:279、ExaNIC_X25:279、fb2CG:271、HTG9200:271、
  HTG9200_fmc:271、**VCU108:271**、VCU118:271、VCU118_fmc:271、ZCU102:271、ZCU106:271。
  ⇒ **所有已知可工作的例子都是"加扰使能"跑的。**
- **PRBS 测试时怎么处理？不是靠 `SCRAMBLER_DISABLE`，而是靠 `PRBS31_ENABLE` 整条替换数据通路** ——
  `rtl/eth_phy_10g_tx_if.v:167-179`：
  ```verilog
  if (PRBS31_ENABLE && cfg_tx_prbs31_enable) begin
      prbs31_state_reg <= prbs31_state;
      serdes_tx_data_reg <= ~prbs31_data[DATA_WIDTH+HDR_WIDTH-1:HDR_WIDTH];  // ← 64 位被 PRBS 取代
      serdes_tx_hdr_reg  <= ~prbs31_data[HDR_WIDTH-1:0];                     // ← 连 2 位头也被取代
  end else begin
      serdes_tx_data_reg <= SCRAMBLER_DISABLE ? encoded_tx_data : scrambled_data;
      serdes_tx_hdr_reg  <= encoded_tx_hdr;
  end
  ```
  ⇒ PRBS 模式下**加扰器根本不在通路上**（64 位数据与 2 位头都被 PRBS 序列取代、且取反 = `INV_PATTERN`），
  所以**不需要**去动 `SCRAMBLER_DISABLE`。这与 P7a 的现象吻合：Xilinx 例子的 checker 用 `INV_PATTERN(1)`。

### (d) GT 侧没有加扰器开关（我方证据）

- `_proj_10g/tcl/build_p7a.tcl`：`grep -i scrambl` → **无命中**。
- 我方生成的 IP 目录 `_proj_10g/vivado_prj/p7a_prj.gen/sources_1/ip/gt_10gbr/`：`grep -ri scrambl` → **无命中**。
- 库的 `.tcl`（`grep -rni scrambl --include=*.tcl`）→ **无命中**（全仓 `scrambl` 命中只有 3 个 `rtl/` 文件 + 13 个 wrapper 的实参）。

⇒ **gtwizard 的 64B66B 模式下没有可配置的加扰器**。

### (e) 结论（旁证链，**排除法**而非手册引文）

> ① 库在 soft logic 里加扰（poly / 种子 / 自同步解扰器三项都与 802.3 对得上）；
> ② 所有已知可工作例子都**使能**加扰（`SCRAMBLER_DISABLE=0`）；
> ③ 这些例子**确实在 UltraScale+ GTY 上通了**（PR#96 在 XCKU5P 上跑通；VCU108 等共 13 例）。
> ⇒ **GT（64B66B_ASYNC gearbox）不做加扰。这一层必须我们自己实现。**

**我认为结论是硬的**：若 GT 也加扰，库就是双重加扰，链路不可能通。
但请注意它是**排除法证明**，不是从器件手册抄来的判据 —— 手册侧的明文我**没找到**（见 §TL-6 第 2 条）。

## TL-2 `serdes_tx_data` / `serdes_tx_hdr` 的逐位语义

### `serdes_tx_data[63:0]` = **"已把块类型字段编码进去的 64b/66b 块净荷"，不是 XGMII 的 64 位原始数据**

| 情形 | 内容 | 证据 |
|---|---|---|
| **数据块** | **就是 XGMII 的 8 个数据字节，原样** | `rtl/xgmii_baser_enc_64.v:201-204`：`if (xgmii_txc == 8'h00) begin encoded_tx_data_next = xgmii_txd; encoded_tx_hdr_next = SYNC_DATA; end` |
| **控制块** | **最低字节（位反转前 = `[7:0]`）承载 block type**，其余 7 字节放压缩后的控制/数据 | `rtl/xgmii_baser_enc_64.v:262-265`：`encoded_tx_data_next = {encoded_ctrl, BLOCK_TYPE_CTRL};`（`encoded_ctrl` 是 `[55:0]` = 7 个 7 位控制码）；`:208 / :212 / :216 / :220 / :224 / :228 / :232 / :236 / :240 / :244 / :248 / :252 / :256 / :260` 是全部 15 种 block 格式 |

### `serdes_tx_hdr[1:0]` = **64b/66b 同步头（是）**。逐位确定值：

| 块类型 | 库内部 `encoded_tx_hdr` | **经 `BIT_REVERSE=1` 后到 GT 的 `txheader[1:0]`** | IEEE 64b/66b | 与板上实测对齐 |
|---|---|---|---|---|
| **数据块** | `SYNC_DATA = 2'b10` | **`2'b01`** | data = `2'b01` ✔ | 板上 `rxheader` 恒 **`0x01`** ⇒ `[1:0]=2'b01` **对上** ✔ |
| **控制块** | `SYNC_CTRL = 2'b01` | **`2'b10`** | ctrl = `2'b10` ✔ | （P7a 未产生控制块，故未观察到 `0x02`） |

行号：`rtl/xgmii_baser_enc_64.v:110-112`（`localparam SYNC_DATA/SYNC_CTRL`）、`:203`（数据块取 `SYNC_DATA`）、`:271`（控制块取 `SYNC_CTRL`）；
位反转在 `rtl/eth_phy_10g_tx_if.v:100-102`。Xilinx 侧独立印证：我方
`_proj_10g/rtl/gt_10gbr_example_stimulus_64b66b_async.v:106` = `assign txheader_out = 6'b000001;`（低 2 位 = `2'b01` = data）。

> ⭐ **对你们板上实测 `rxheader ≡ 0x01` 的解读（双重含义）**：
> ① `[1:0] = 2'b01` ⇒ 收到的**全是数据块**（对端发的是无控制块的流，我们发出去的也是 data header）；
> ② **上 4 位恒 0**（是 `0x01` 而不是 `0x41`）⇒ 印证了"库只驱低 2 位、上 4 位为常 0"的做法在**器件上成立**。
> ⇒ **换到真以太网流量后，`rxheader` 应在 `0x01` / `0x02` 之间跳**（有 IFG 就有控制块）。
> **这可以直接拿来做 P7b 的一条廉价在线判据**（不需 ILA）：`hdrs_cnt` 之外再数"出现过 `0x02` 的次数"，
> 恒 0 就说明对端没发 / 我们的编码层没产生控制块。

### RX 逆变换在哪（`serdes_rx_data` + `serdes_rx_hdr` → XGMII 的 /S/ /T/ /I/ /E/ /Q/）

| 步骤 | 文件:行 | 做什么 |
|---|---|---|
| ① 位反转 | `rtl/eth_phy_10g_rx_if.v:99-110` | `serdes_rx_data_rev[n] = serdes_rx_data[63-n]`；`serdes_rx_hdr_rev[n] = serdes_rx_hdr[1-n]` |
| ② 解扰 | `rtl/eth_phy_10g_rx_if.v:158-172` + `:207` | 58 位自同步解扰 → `descrambled_rx_data` |
| ③ 打拍输出 | `rtl/eth_phy_10g_rx_if.v:204-227` | 产 `encoded_rx_data` / `encoded_rx_hdr`（**同步头不解扰**，`:208`） |
| ④ **块类型 → XGMII**（核心） | **`rtl/xgmii_baser_dec_64.v:203-365`** | `encoded_rx_hdr[0]==0` ⇒ 数据块直通（`:203-206`）；否则按 `encoded_rx_data[7:4]` 分发到 15 种 block 格式，**把 block type 还原成控制字符** |
| ⑤ 控制字符常量 | `rtl/xgmii_baser_dec_64.v:81-94` | `/I/=8'h07`、`/LI/=8'h06`、`/S/=8'hfb`、`/T/=8'hfd`、`/E/=8'hfe`、`/Q/(SEQ_OS)=8'h9c` |
| ⑥ 7 位控制码 → 8 位 XGMII 字符 | `rtl/xgmii_baser_dec_64.v:157-200` | `CTRL_IDLE=7'h00` … `CTRL_RES_5=7'h78`（`:96-105`）|
| ⑦ 帧边界 / 序列错 | `rtl/xgmii_baser_dec_64.v:140`（`frame_reg`）、`:234`、`:279`、`:300-357` | START 时若已在帧内 ⇒ `rx_sequence_error`；TERM 时若不在帧内 ⇒ 同样报错 |

**具体到"哪个字符在哪一行还原"**：
- `/S/`（START）：`:275`（`BLOCK_TYPE_START_0` 分支：`xgmii_rxd_next = {encoded_rx_data[63:8], XGMII_START};`）、`:231`（`BLOCK_TYPE_START_4`）。
- `/T/`（TERM）：`:297`（TERM_0）、`:305`、`:313`、`:321`、`:329`、`:337`、`:345`、`:353`（TERM_1..TERM_7）。
- `/I/` `/E/` 及保留码：由 `decoded_ctrl` 的 `case` 查表（`:157-200`）；非法控制码 ⇒ `XGMII_ERROR` + `decode_err[i]=1`（`:195-198`）。
- 非法 block type ⇒ 全 `XGMII_ERROR` + `rx_bad_block`（`:359-364`、`:387-392`）；非法同步头 ⇒ 同样（`:394-398`）。

## TL-3 块锁状态机（`rtl/eth_phy_10g_rx_frame_sync.v`）

**有 `rx_block_lock` 输出**：`rtl/eth_phy_10g_rx_frame_sync.v:53`；
经 `rtl/eth_phy_10g_rx.v:71`（端口）/ `:125`（连到 frame_sync）上引、`rtl/eth_phy_10g.v:79` 导出到顶层。

**计数结构**（`:71-72`）：
```verilog
reg [5:0] sh_count_reg = 6'd0, sh_count_next;                  // 6 位: 0..63，计满 = 一个"64 头窗口"
reg [3:0] sh_invalid_count_reg = 4'd0, sh_invalid_count_next;  // 4 位: 0..15
```

**判据**（`:96-125`）：
- **合法头** = `serdes_rx_hdr == SYNC_CTRL || serdes_rx_hdr == SYNC_DATA`（`:96`；即内部值 `2'b10`/`2'b01`，**位反转之后**的）。
- **锁定**（`:99-105`）：64 窗口计满 **且** `sh_invalid_count_reg == 0` ⇒ 置 `rx_block_lock`：
  ```verilog
  if (&sh_count_reg) begin
      sh_count_next = 0;
      sh_invalid_count_next = 0;
      if (!sh_invalid_count_reg) begin
          rx_block_lock_next = 1'b1;          // :104
      end
  end
  ```
- **失锁**（`:107-119`）：非法头使 `sh_invalid_count_reg` 递增；当 `!rx_block_lock_reg || &sh_invalid_count_reg`（**= 第 16 个非法**）⇒
  ```verilog
  rx_block_lock_next = 1'b0;                  // :115
  serdes_rx_bitslip_next = 1'b1;              // :118  ← 失锁同拍就拉 slip
  ```

**与 802.3 的诚实对照**：

| | IEEE 802.3 (Clause 49) | 本库 |
|---|---|---|
| 锁定 | 连续 **64** 个有效同步头 | **64 计数窗口内零非法头**（窗口里只要有过非法头就不给锁） |
| 解锁 | **64 个里 16 个无效** | **累计 16 个非法头**（不限于 64 窗口内） |
| 小结 | —— | **迟滞语义近似但不等价**：本库的解锁少了"64 里"的窗口约束 |

⚠️ 这条我**只读了 RTL**，**没有**对照 802.3 §49 原文逐字核措辞（见 §TL-6 第 1 条）。

**`serdes_rx_bitslip` 的对齐搜索写法**（`:91-125`）：
- **只在两类时刻拉高**：① 失锁（`:118`）；② `!rx_block_lock_reg` 且非法计满（同一分支）。
  ⇒ **锁定之后不再扰动对齐**（正确做法）。
- **节流**（`:91-95`，参数在 `eth_phy_10g.v:44-45`）：
  ```verilog
  if (bitslip_count_reg) begin
      bitslip_count_next = bitslip_count_reg-1;
  end else if (serdes_rx_bitslip_reg) begin
      serdes_rx_bitslip_next = 1'b0;
      bitslip_count_next = BITSLIP_LOW_CYCLES > 0 ? BITSLIP_LOW_CYCLES-1 : 0;
  end
  ```
  即 `BITSLIP_HIGH_CYCLES=1`（拉高 1 拍）→ `BITSLIP_LOW_CYCLES=8`（其后 8 拍禁止再拉）。
- **判据** = "该对齐下同步头是否合法"（`:96`，只需 `2'b10/2'b01` 两值之一）。
- **搜多少拍 / 超时怎么办**：
  - **没有"搜 64 个位置"的显式计数器，也没有超时。** 搜索是**纯闭环重试**：
    失锁 → 拉 1 拍 slip → 等 8 拍 → 重新数 64 个；累计 16 个非法就再 slip。
  - ⇒ 最坏情况可以**永远在 slip 循环里**（GT 无数据 / 一直高 BER）。**本文件不含超时逻辑。**
- **超时/兜底在另一个模块**：`rtl/eth_phy_10g_rx_watchdog.v`
  - 时间基：125 µs 一格（`COUNT_125US`，`eth_phy_10g.v:46` = 125000/6.4 = 19531 @156.25 MHz）；
  - 每格判"健康"（`:104-128`）：本格内**见到过控制同步头**（`saw_ctrl_sh`，`:104-106` 仅在 `serdes_rx_hdr == SYNC_CTRL` 置位）
    **且**本格块错 < 16（`&block_error_count_reg`，`:107-109`）⇒ 好格，`status_count++`（上限 15）；
    否则坏格，`error_count++` 并清 `status_count`；
  - **连续 16 个坏格 ⇒ `serdes_rx_reset_req` 拉 1 拍**（`:130-133`）；
  - **连续 16 个好格 ⇒ `rx_status = 1`**（`:135-137`）。
  ⇒ **`rx_status` ≈ "已连续健康 2 ms"**（= 16 × 125 µs；此为算术结论，见 §TL-6 第 5 条）。
  这就是 issue #87 / #229 里维护者说"**`rx_status` 比 `rx_block_lock` 可靠**"的由来。

⭐ **由 TL-3 得到的直接陷阱**：watchdog **要求每个 125 µs 窗口至少出现一个 CONTROL 同步头**。
**纯数据块流（PRBS 时 txheader 恒 "data"，我们 P7a 正是如此）永远看不到控制头** ⇒ 判"永远不健康"
⇒ **每 2 ms 拉一次 `serdes_rx_reset_req`**。库的对策是 PRBS 模式下把它屏蔽 ——
`rtl/eth_phy_10g_rx_if.v:233-234`：
```verilog
assign serdes_rx_bitslip   = serdes_rx_bitslip_int   && !(PRBS31_ENABLE && cfg_rx_prbs31_enable);
assign serdes_rx_reset_req = serdes_rx_reset_req_int && !(PRBS31_ENABLE && cfg_rx_prbs31_enable);
```
（注意 `frame_sync` 自己产的 `rx_block_lock` **不受**这个屏蔽影响 —— 它只看同步头合法性，所以 PRBS 流也能锁上。）

## TL-4 `BIT_REVERSE` 的确切作用范围：**数据与同步头，两者都反转（逐位）**

- **TX** —— `rtl/eth_phy_10g_tx_if.v:95-106`：
  ```verilog
  if (BIT_REVERSE) begin
      for (n = 0; n < DATA_WIDTH; n = n + 1) begin
          assign serdes_tx_data_int[n] = serdes_tx_data_reg[DATA_WIDTH-n-1];  // :97  64 位【逐位】反转
      end
      for (n = 0; n < HDR_WIDTH; n = n + 1) begin
          assign serdes_tx_hdr_int[n] = serdes_tx_hdr_reg[HDR_WIDTH-n-1];     // :101  2 位【逐位】反转
      end
  end
  ```
- **RX** —— `rtl/eth_phy_10g_rx_if.v:99-110`：对称的 `serdes_rx_data_rev`（`:101`）/ `serdes_rx_hdr_rev`（`:105`）。
- **相对加扰的位置**：
  - TX：`:176-177` 先**加扰**写进 `serdes_tx_data_reg`，`:95-106` 再**位反转** ⇒ 反转的是**已加扰**的数据。
  - RX：`:99-110` 先**位反转**，`:158-172` 再**解扰** ⇒ 与 TX 互为镜像。
- ⚠️ **别与 `lfsr` 自己的 `REVERSE(1)` 混**：`rtl/lfsr.v:44` 注释 `// bit-reverse input and output`，
  它管 **LFSR/CRC 内部数据的位序（多项式方向）**；`BIT_REVERSE` 管 **fabric ↔ GT 的整字位序**。两者独立。

**⇒ 对你们"MSb-first 猜测"的裁决：成立，且有两条同向独立证据。**
① 两级板级例子都写死 `BIT_REVERSE(1)`：`example/VCU108/fpga_10g/rtl/eth_xcvr_phy_wrapper.v:270`、
   `example/KCU116/fpga_10g/rtl/fpga.v:494`（经 `git show pr96:` 读）。
② Xilinx 自己的 checker 也要整字位反转，注释明写原因 —— 我方
   `_proj_10g/rtl/gt_10gbr_example_checking_64b66b_async.v:89-99`：
   `// Bit-reverse the rxdata_int assignment to accomodate any differences between transmitter and receiver user`
   `// interface data widths, since gearbox modes transmit data MSb first.` + `assign rxdata_int[i] = rxdata_in[63-i];`

## TL-5 由本节追加引出的、对 P7b 的三条直接结论

1. **加扰器：必须我们自己写**（TL-1e）。所需件：① 58 位 **Fibonacci** 加扰器（poly `0x8000000001`、种子全 1、
   **每拍并行吞 64 位**）；② **feed-forward 自同步**解扰器；③ **同步头不参与加扰**（`tx_if:177` / `rx_if:208`）。
   🎁 **好消息：库那份 `rtl/lfsr.v`（447 行，MIT）正是参数化通用件，可直接复用**，
   不必自己推 64 位并行的多项式 —— 这也是 §7 的最小集里必须有 `lfsr.v` 的原因。
2. **同步头取值**（TL-2）：送到 GT 的 `txheader[1:0]` = **数据块 `2'b01`、控制块 `2'b10`**（= IEEE 值；
   库内部先算成 `2'b10/2'b01` 再靠 `BIT_REVERSE` 翻过来）。
   你们实测 `rxheader ≡ 0x01` 与"数据块 = `2'b01`、上 4 位恒 0"**完全一致** ⇒
   **P7b 可用"`rxheader` 是否在 `0x01`/`0x02` 之间跳"作为"控制块已出现 / IFG 存在"的廉价在线判据**（不需 ILA）。
3. **`serdes_rx_reset_req` 在 PRBS 阶段的接法必须二选一**（TL-3 末）：
   要么 `PRBS31_ENABLE=1`（库自动屏蔽），要么**像 PR#96 那样把它悬空**
   （KCU116 `fpga.v:493-512` 的 `eth_phy_10g` 例化里确实没接它，只接了 `rx_block_lock` 与 `rx_high_ber`）。
   **否则纯数据块流会让 watchdog 每 2 ms 复位一次 GT 的 RX datapath。**
   ⚠️ 这一条对我们尤其重要：**P7a 那个"txheader 恒 data"的配置不能直接搬进带 watchdog 的 PHY 里**。
   （VCU108 wrapper 反而是把它接到 `gt_reset_rx_datapath` 的 —— `eth_xcvr_phy_wrapper.v:105`。）

## TL-6 未核实（**本轮追加**，接在 §8 之后）

1. **802.3 Clause 49 的块锁迟滞原文未核** —— TL-3 的对照表里"IEEE 802.3"那一列是我据通行描述写的，
   **我没有下载/逐字核对 IEEE 802.3-2018 §49 的措辞**（"64 个连续有效锁定 / 64 个里 16 个无效解锁"）。
   若要把"本库与标准不等价"写进设计依据，需先补这一步。
2. **"GT 不做加扰"没有手册明文引证** —— TL-1e 是**排除法**（库加扰 + 库能通 ⇒ GT 不加扰）。
   我**未从 UG578 正文找到**"64B66B gearbox 不含加扰器 / 加扰在 fabric 侧"的明文。
   （TL 提供的"`w2_pcs64_baser` 内嵌 GT 与 `gt_10gbr` 配置逐项相同而 fabric 面是 XGMII"是**同向**证据，
   但**我本人未独立复核**那个核的文档与配置。）
3. **`COUNT_125US` 的 6.4 ns 口径** —— `125000/6.4 = 19531` 是按"156.25 MHz 下 UI = 6.4 ns"算的算术结果，
   **RTL 里没有注释说明这个时间常数**；"125 µs" 这个刻度名来自参数名本身。
4. **`eth_phy_10g_rx_ber_mon.v` 的内部判据未读** —— 我只读过它的端口与 `COUNT_125US` 参数，
   **`rx_high_ber` 的门限（多少个错头算高 BER）未核实**。
5. **`rx_status` 的 "2 ms"** 是我按 `16 × 125 µs` 推的算术结论（依据 `watchdog:125-137` 的 `status_count` 上限 15 ⇒ 16 格），
   **RTL 注释未标时间**；写进设计依据前需自证。
6. **PR#96 未接 `serdes_rx_reset_req` 是有意还是遗漏** —— 我只能陈述事实（该例化里没有这个端口连接），
   **无法判断作者意图**；若我们要采用 PHY，建议按 TL-5 第 3 条自己明确选一种。

---

**（本笔记完。全文每条结论均带出处；未能核实的一律列入 §8 与 §TL-6，未作推测性陈述。）**
