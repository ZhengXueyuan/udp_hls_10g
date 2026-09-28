`timescale 1ns/1ps
//=============================================================================
// util_gmii_to_rgmii_us.v — RGMII 前端 (UltraScale+ / KU5P), **零 IDELAY** 版
//=============================================================================
// 与 board/util_gmii_to_rgmii.v (K7 版) **端口名/方向/位宽一致, 但声明顺序不同**
// (本文件把 rgmii_rxc 放在第 1 位) ⇒ **实例化必须用命名连接**, 位置连接会静默错线。
// 内部
// 实现是**按 RTL8211E 手册语义重写的**, 不是 K7 版的逐原语翻译。三条理由:
//
// ① **HDIO bank 不支持 IDELAY** (P6a-T2 实证, 2026-09-28):
//    KU5P 的 RGMII/MDIO 全部落在 **bank 86 = High Density I/O**; Vivado placer DRC:
//      "ERROR: [DRC PLHDIO-6] ... cannot be LOCed in HDIO because the shape contains
//       IDelay and ISerDes (details: presence of I/ODELAY or I/OSERDES is not
//       supported in HDIO)"
//    ⇒ K7 的 `IDELAYE2 → IDELAYE3` 路线在这块板上**物理不成立** (不是"要重标定 tap"),
//      且 **IDELAYCTRL 与 300MHz 参考钟一并消失**。HDIO 同时没有 BUFIO/BUFR
//      (厂商 KU5P 设计里 BUFIO 被综合降级为 BUFGCE, 见其 runme.log 的
//      Unisim Transformation Summary) ⇒ 采样只走 BUFG。
//
// ② **本板 PHY 搭接已把 2ns 延迟做在 PHY 内部** (底板原理图实测):
//      LED2/RXDLY (pin 32) → R52 10k → VDD3.3  ⇒ **RXDLY=1**: PHY 给 RXC 加 ~2ns
//      RXD1/TXDLY (pin 16) → R51 10k → VDD3.3  ⇒ **TXDLY=1**: PHY 内部延迟 TXC 去锁 TXD
//    这正是 RTL8211E 手册 10.6.5 节 Figure 32/33 描述的"internal delay added"模式:
//    **源端(FPGA)与时钟边沿对齐地驱动数据, 接收端(PHY)用延迟后的时钟在中点采样**
//    ⇒ FPGA 侧**不需要**任何延迟元件。K7 板那颗 PHY 未必是这个搭接, 故 K7 版
//    才是靠 IDELAY + 反相 BUFG 去凑相位的 (配方不可移植)。
//
// ③ **TX 侧改为更直白的形式 (语义等价, 但不再依赖巧合)**:
//    K7 版 TXD 的 ODDR 是 `.D1(gmii_txd_r_d1[i]), .D2(gmii_txd_low[i])`, 其中
//    `gmii_txd_low` 是**同一时钟块内的阻塞赋值**读沿前 `gmii_txd_r` (天然多滞后一拍),
//    正好补偿 `gmii_txd_r_d1` 的两级流水 ⇒ **两代前端在"上升沿=低 nibble / 下降沿=
//    高 nibble"这个约定上其实是等价的** —— `tb/tb_rgmii_phy_model.v` 实测: K7 前端
//    在同一 TXDLY=1 模型下 TX 也逐字节全对 (mis=0)。
//    ⚠️ **更正 (审查 2026-09-28)**: 本文件初稿写"K7 的 TX 结构在 TXDLY=1 下不自洽"
//    —— **不成立**, 那是手算时漏了上面那条阻塞赋值的滞后。改写的真实理由是 ①②
//    (HDIO 放不了 IDELAY + 本板 PHY 搭接已自带 2ns **且 K7 的 RX 相位配方不适用**)。
//    本版仍改用直白形式: D1/D2 取**同一个已寄存字节**的低/高 nibble (与厂商 KU5P 设计
//    的 `w_send_d1/w_send_d2 = i_send_data[i] / i_send_data[i+4]` 同构)。
//
// 判据 (不是"与 K7 前端逐位同构" —— 两者面对的 PHY 搭接不同, 本来就不该同构):
//   `tb/tb_rgmii_phy_model.v` = **行为级 RTL8211E 模型** (实现 RXDLY=1/TXDLY=1)
//   + 本模块, 做**往返一致** (GMII 字节流 → RGMII → 模型 → GMII 字节流) 与
//   **逐边沿协议检查** (每个 TXC 沿上数据必须稳定且 nibble 配对正确)。
//   见 sim/p6a_ku5p/run_tb_rgmii_phy_model.bat。板级最终仲裁 = 真 PHY 上跑通 ping。
//
// 时钟: gmii_rx_clk = BUFG(rgmii_rxc) **不反相** (K7 版用 BUFG(~rxc) 是为 7 系列
//   IDDR SAME_EDGE_PIPELINED 对齐凑的; US+ 用 IDDRE1 的 IS_CB_INVERTED 表达即可,
//   且 I/O 单元与 fabric 必须用**同一个** BUFG 输出, 否则半个周期错位)。
//   XDC 的 generated clock 名沿用 `u_rgmii/bufmr_rgmii_rxc/O` (实例名与 BUFG 名保持),
//   但 **-invert 必须去掉**。
//=============================================================================
module util_gmii_to_rgmii_us (
  input           rgmii_rxc,       // 来自 PHY 的 RXC (本板已含 PHY 内部 ~2ns 延迟)
  input           reset,
  output  [ 3:0]  rgmii_td,
  output          rgmii_tx_ctl,
  output          rgmii_txc,
  input   [ 3:0]  rgmii_rd_i,
  input           rgmii_rx_ctl_i,
  output          gmii_rx_clk,
  input   [ 7:0]  gmii_txd,
  input           gmii_tx_en,
  input           gmii_tx_er,
  output          gmii_tx_clk,
  output          gmii_crs,
  output          gmii_col,
  output  [ 7:0]  gmii_rxd,
  output          gmii_rx_dv,
  output          gmii_rx_er,
  input  [ 1:0]   speed_selection, // 1x = gigabit
  input           duplex_mode      // 1 full, 0 half
);

    // ---------------- RX: IBUF → BUFG → IDDRE1 (无 IDELAY, 无 BUFIO) ----------
    wire [3:0] rd_ibuf;
    wire       rx_ctl_ibuf;
    genvar j;
    generate for (j = 0; j < 4; j = j + 1) begin : gen_rx_ibuf
        IBUF u_ibuf_rd (.I(rgmii_rd_i[j]), .O(rd_ibuf[j]));
    end
    endgenerate
    IBUF u_ibuf_rx_ctl (.I(rgmii_rx_ctl_i), .O(rx_ctl_ibuf));

    // 实例名与 BUFG 名保持与 K7 版一致 (XDC 的 generated clock 引用这两个名字)
    BUFG bufmr_rgmii_rxc (.I(rgmii_rxc), .O(gmii_rx_clk));

    // SAME_EDGE_PIPELINED: Q1/Q2 同沿对齐, fabric 用同一个时钟直接采 (等价 7 系列
    // SAME_EDGE_PIPELINED)。C 与 CB 接同一张网 + IS_CB_INVERTED=1 = UltraScale 模板写法。
    wire [7:0] gmii_rxd_s;
    wire       gmii_rx_dv_s, rgmii_rx_ctl_s;

    generate for (j = 0; j < 4; j = j + 1) begin : gen_rx_iddr
        IDDRE1 #(
            .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
            .IS_CB_INVERTED(1'b1), .IS_C_INVERTED(1'b0)
        ) u_iddr (
            .Q1(gmii_rxd_s[j]),      // RXC 上升沿 = TXD/RXD[3:0] (RGMII 标准)
            .Q2(gmii_rxd_s[j+4]),    // RXC 下降沿 = RXD[7:4]
            .C(gmii_rx_clk), .CB(gmii_rx_clk),
            .D(rd_ibuf[j]), .R(1'b0)
        );
    end
    endgenerate

    IDDRE1 #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .IS_CB_INVERTED(1'b1), .IS_C_INVERTED(1'b0)
    ) u_iddr_rx_ctl (
        .Q1(gmii_rx_dv_s),           // 上升沿 = RX_DV
        .Q2(rgmii_rx_ctl_s),         // 下降沿 = RX_DV ^ RX_ER
        .C(gmii_rx_clk), .CB(gmii_rx_clk),
        .D(rx_ctl_ibuf), .R(1'b0)
    );

    reg [7:0] gmii_rxd_r;
    reg       gmii_rx_dv_r, gmii_rx_er_r;
    always @(posedge gmii_rx_clk) begin
        gmii_rxd_r   <= gmii_rxd_s;
        gmii_rx_dv_r <= gmii_rx_dv_s;
        gmii_rx_er_r <= gmii_rx_dv_s ^ rgmii_rx_ctl_s;   // GMII: RX_ER = DV ^ CTL
    end
    assign gmii_rxd   = gmii_rxd_r;
    assign gmii_rx_dv = gmii_rx_dv_r;
    assign gmii_rx_er = gmii_rx_er_r;

    // ---------------- TX: 数据/时钟同沿边沿对齐驱动 (TXDLY=1 ⇒ PHY 内部延迟去锁) --
    // gmii_tx_clk 与 gmii_rx_clk 同源 (同 K7 版: 无 MMCM, 整条通路跑在 PHY 回送时钟上)
    assign gmii_tx_clk = gmii_rx_clk;

    reg [7:0] txd_r;
    reg       tx_en_r, tx_er_r;
    reg       tx_reset_d1, tx_reset_sync;
    always @(posedge gmii_rx_clk) begin
        tx_reset_d1   <= reset;
        tx_reset_sync <= tx_reset_d1;
    end
    always @(posedge gmii_rx_clk) begin
        txd_r   <= gmii_txd;
        tx_en_r <= gmii_tx_en;
        tx_er_r <= gmii_tx_er;
    end

    // TXC: 与数据同相的 125MHz 方波 (D1=1/D2=0), 故 TXC 上升沿 = D1 送出的那一刻。
    // 本板 TXDLY=1 ⇒ PHY 用内部延迟后的 TXC 去锁 TXD, 中点采样, 不需要 FPGA 侧移相。
    ODDRE1 #(
        .IS_C_INVERTED(1'b0), .IS_D1_INVERTED(1'b0), .IS_D2_INVERTED(1'b0),
        .SIM_DEVICE("ULTRASCALE_PLUS"), .SRVAL(1'b0)
    ) u_oddr_txc (
        .Q(rgmii_txc), .C(gmii_rx_clk), .D1(1'b1), .D2(1'b0), .SR(tx_reset_sync)
    );

    // TXD: D1/D2 = **同一个**已寄存字节的低/高 nibble (自洽配对; 见头注释 ③)
    generate for (j = 0; j < 4; j = j + 1) begin : gen_tx_oddr
        ODDRE1 #(
            .IS_C_INVERTED(1'b0), .IS_D1_INVERTED(1'b0), .IS_D2_INVERTED(1'b0),
            .SIM_DEVICE("ULTRASCALE_PLUS"), .SRVAL(1'b0)
        ) u_oddr_td (
            .Q(rgmii_td[j]), .C(gmii_rx_clk), .D1(txd_r[j+4]), .D2(txd_r[j]), .SR(tx_reset_sync)
        );
    end
    endgenerate

    // TX_CTL: 上升沿 = TX_EN, 下降沿 = TX_EN ^ TX_ER (RGMII 标准), 同一个已寄存拍
    ODDRE1 #(
        .IS_C_INVERTED(1'b0), .IS_D1_INVERTED(1'b0), .IS_D2_INVERTED(1'b0),
        .SIM_DEVICE("ULTRASCALE_PLUS"), .SRVAL(1'b0)
    ) u_oddr_tx_ctl (
        .Q(rgmii_tx_ctl), .C(gmii_rx_clk),
        .D1(tx_en_r), .D2(tx_en_r ^ tx_er_r), .SR(tx_reset_sync)
    );

    // 半双工载波/冲突: 本设计**全双工专线** (wrapper 恒传 duplex_mode=1, 两端口悬空),
    // 故这里给 0 即可。⚠️ 与 K7 版**不同式**: K7 用寄存后的 `tx_en_r|tx_er_r` 且含
    // `rx_er` 项; 本版用原始 gmii_tx_en —— 全双工下两者都恒 0, 无功能差异, 但不写"同义"。
    assign gmii_crs = 1'b0;
    assign gmii_col = 1'b0;
    // ⚠️ 本版**只支持千兆** (RGMII 1 nibble/边沿): `speed_selection` 保留在端口表里仅为
    // 与 K7 版接口一致, 内部不使用 (K7 版用它选 10/100M 的 nibble 排布)。

endmodule
