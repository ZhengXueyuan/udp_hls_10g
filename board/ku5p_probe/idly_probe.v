//=============================================================================
// idly_probe.v - KU5P T2 前置实证: bank86(HDIO) 到底能不能放 IDELAYE3?
// 同时验证 T2 需要的全部原语可在 xcku5p-ffvb676-1-e 上 综合/布局/布线:
//   IBUF / BUFG / MMCME4_BASE / IDELAYCTRL / IDELAYE3 / IDDRE1 / ODDRE1
// 引脚 = KU5P 真实 RGMII 引脚 (bank 86, LVCMOS33)
//=============================================================================
`timescale 1ns/1ps
module idly_probe (
    input  wire eth_rxc,     // D11
    input  wire eth_rxd0,    // B10
    input  wire eth_rxctl,   // A10
    output wire eth_txc,     // J10
    output wire eth_txd0,    // F9
    output wire eth_txctl    // G9
);
    wire rxc_b, rxd_b, rxctl_b;
    wire rxc_i;
    IBUF u_ibuf_rxc  (.I(eth_rxc),   .O(rxc_b));
    IBUF u_ibuf_rxd  (.I(eth_rxd0),  .O(rxd_b));
    IBUF u_ibuf_rxctl(.I(eth_rxctl), .O(rxctl_b));
    BUFG u_bufg_rxc  (.I(rxc_b), .O(rxc_i));

    // 300MHz IDELAYCTRL 参考钟 (US+ 要求 >=300MHz): VCO 125*12=1500, /5 = 300
    wire clkfb, clk300_raw, clk300, locked;
    MMCME4_BASE #(
        .CLKIN1_PERIOD(8.000), .CLKFBOUT_MULT_F(12.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0), .REF_JITTER1(0.010), .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(rxc_i), .CLKOUT0(clk300_raw), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(clkfb), .CLKFBOUTB(), .CLKFBIN(clkfb), .LOCKED(locked),
        .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG u_bufg300 (.I(clk300_raw), .O(clk300));
    (* IODELAY_GROUP = "rgmii" *) IDELAYCTRL u_idelayctrl (
        .RDY(), .REFCLK(clk300), .RST(1'b0)
    );

    wire rxd_d, rxctl_d;
    (* IODELAY_GROUP = "rgmii" *) IDELAYE3 #(
        .CASCADE("NONE"), .DELAY_FORMAT("TIME"), .DELAY_SRC("IDATAIN"),
        .DELAY_TYPE("FIXED"), .DELAY_VALUE(2000), .REFCLK_FREQUENCY(300.0),
        .SIM_DEVICE("ULTRASCALE_PLUS"), .UPDATE_MODE("ASYNC")
    ) u_dly_rxd (
        .IDATAIN(rxd_b), .DATAOUT(rxd_d), .DATAIN(1'b0), .CLK(1'b0), .CE(1'b0),
        .INC(1'b0), .LOAD(1'b0), .CNTVALUEIN(9'd0), .CNTVALUEOUT(), .EN_VTC(1'b1),
        .RST(1'b0), .CASC_IN(1'b0), .CASC_RETURN(1'b0), .CASC_OUT()
    );
    (* IODELAY_GROUP = "rgmii" *) IDELAYE3 #(
        .CASCADE("NONE"), .DELAY_FORMAT("TIME"), .DELAY_SRC("IDATAIN"),
        .DELAY_TYPE("FIXED"), .DELAY_VALUE(2000), .REFCLK_FREQUENCY(300.0),
        .SIM_DEVICE("ULTRASCALE_PLUS"), .UPDATE_MODE("ASYNC")
    ) u_dly_rxctl (
        .IDATAIN(rxctl_b), .DATAOUT(rxctl_d), .DATAIN(1'b0), .CLK(1'b0), .CE(1'b0),
        .INC(1'b0), .LOAD(1'b0), .CNTVALUEIN(9'd0), .CNTVALUEOUT(), .EN_VTC(1'b1),
        .RST(1'b0), .CASC_IN(1'b0), .CASC_RETURN(1'b0), .CASC_OUT()
    );

    wire q1_d, q2_d, q1_c, q2_c;
    IDDRE1 #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .IS_CB_INVERTED(1'b1))
      u_iddr_d (.Q1(q1_d), .Q2(q2_d), .C(rxc_i), .CB(rxc_i), .D(rxd_d), .R(1'b0));
    IDDRE1 #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .IS_CB_INVERTED(1'b1))
      u_iddr_c (.Q1(q1_c), .Q2(q2_c), .C(rxc_i), .CB(rxc_i), .D(rxctl_d), .R(1'b0));

    ODDRE1 u_oddr_txc  (.Q(eth_txc),   .C(rxc_i), .D1(1'b1), .D2(1'b0), .SR(1'b0));
    ODDRE1 u_oddr_txd0 (.Q(eth_txd0),  .C(rxc_i), .D1(q1_d),  .D2(q2_d), .SR(1'b0));
    ODDRE1 u_oddr_txctl(.Q(eth_txctl), .C(rxc_i), .D1(q1_c),  .D2(q2_c), .SR(1'b0));
endmodule
