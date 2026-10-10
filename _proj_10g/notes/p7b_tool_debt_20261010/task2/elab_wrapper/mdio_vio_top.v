// mdio_vio_top.v -- KU5P board bring-up probe: VIO-driven MDIO master.
//
// Bring-up step 4 (Ethernet 1G): read the RTL8211E PHY identification
// registers. There is no UART on this board and instantiating XDMA just to get
// a register window is heavy, so the register window IS a VIO: the host sets
// phyad/regad/op/wr_data and pulses start over JTAG, then reads back the data.
// That makes this design a permanent board-poking tool, not just a one-off.
//
// Clock: Y1, a 100 MHz differential oscillator on SYS_CLK_P/N = ball T25/U25
// (IO_L14P_T2L_N2_GC_A04_D20_65, i.e. clock-capable in bank/group 65 -- not the
// similarly-named "GC_66" pair on H23/H24). It is the only general fabric clock
// on the board (Y2 156.25MHz goes to GT refclk only; the 25MHz crystal feeds
// the PHY only). Bank 65 is 1.2V DIFF_POD12_DCI; the RGMII/MDIO pins are in
// bank 86 at LVCMOS33, so the two standards never share a bank.
//
// VIO probe map -- keep in sync with build_mdio.tcl:
//   probe_out0 [0]     start
//   probe_out1 [0]     op        0=read 1=write
//   probe_out1 [1]     force_rst 1=hold PHY in reset
//   probe_out2 [4:0]   phyad
//   probe_out3 [4:0]   regad
//   probe_out4 [15:0]  wr_data
//   probe_in0  [15:0]  rd_data
//   probe_in0  [16]    done_sticky
//   probe_in0  [17]    busy
//   probe_in0  [18]    eth_rstn (readback)
//   probe_in0  [19]    mdio_i   (live line level)

module mdio_vio_top (
    input  wire sys_clk_p,
    input  wire sys_clk_n,
    output wire eth_mdc,
    inout  wire eth_mdio,
    output wire eth_rstn
);

    wire clk;
    wire clk_raw;

    IBUFDS u_sys_clk_ibufds (
        .I  (sys_clk_p),
        .IB (sys_clk_n),
        .O  (clk_raw)
    );

    BUFG u_sys_clk_bufg (
        .I (clk_raw),
        .O (clk)
    );

    // Power-on reset: all FFs come up at 0 out of configuration, so a plain
    // counter is enough to hold reset for ~650us at 100MHz.
    reg [15:0] por_cnt = 16'd0;
    reg        por_n   = 1'b0;

    always @(posedge clk) begin
        if (!por_n) begin
            if (&por_cnt)
                por_n <= 1'b1;
            else
                por_cnt <= por_cnt + 16'd1;
        end
    end

    // RTL8211E reset: hold low for ~330ms after configuration, then release.
    // The VIO can pull it low again for a controlled re-reset.
    reg [24:0] phy_rst_cnt  = 25'd0;
    reg        phy_rst_done = 1'b0;

    always @(posedge clk) begin
        if (!phy_rst_done) begin
            if (&phy_rst_cnt)
                phy_rst_done <= 1'b1;
            else
                phy_rst_cnt <= phy_rst_cnt + 25'd1;
        end
    end

    // ---- VIO ----
    wire        vio_start;
    wire        vio_op;
    wire        vio_force_rst;
    wire [4:0]  vio_phyad;
    wire [4:0]  vio_regad;
    wire [15:0] vio_wr_data;
    wire [19:0] vio_probe_in;

    // A VIO output holds its value until the host writes a new one, and a JTAG
    // commit takes tens of milliseconds while one MDIO frame takes ~32us. Feeding
    // probe_out0 straight into `start` would retrigger the master thousands of
    // times per host write, leaving done_sticky a 10ns blip buried inside a 32us
    // loop -- effectively unobservable. Edge-detecting it makes one host write
    // mean exactly one transaction.
    reg  vio_start_q;
    wire start_pulse;

    always @(posedge clk) begin
        if (!por_n) vio_start_q <= 1'b0;
        else        vio_start_q <= vio_start;
    end

    assign start_pulse = vio_start & ~vio_start_q;

    // ---- MDIO ----
    wire        mdio_i;
    wire        mdio_o;
    wire        mdio_t;
    wire        mdc;
    wire [15:0] rd_data;
    wire        done_sticky;
    wire        busy;

    assign eth_mdc  = mdc;
    assign eth_rstn = phy_rst_done & ~vio_force_rst;

    IOBUF u_mdio_iobuf (
        .IO (eth_mdio),
        .I  (mdio_o),
        .O  (mdio_i),
        .T  (mdio_t)
    );

    mdio_master #(
        .DIV (25)                       // 100MHz / 25 -> 2MHz MDC
    ) u_mdio_master (
        .clk         (clk),
        .rstn        (por_n),
        .start       (start_pulse),
        .op          (vio_op),
        .phyad       (vio_phyad),
        .regad       (vio_regad),
        .wr_data     (vio_wr_data),
        .rd_data     (rd_data),
        .done        (),
        .done_sticky (done_sticky),
        .busy        (busy),
        .mdc         (mdc),
        .mdio_o      (mdio_o),
        .mdio_t      (mdio_t),
        .mdio_i      (mdio_i)
    );

    assign vio_probe_in = {mdio_i, eth_rstn, busy, done_sticky, rd_data};

    vio_0 u_vio (
        .clk        (clk),
        .probe_in0  (vio_probe_in),
        .probe_out0 (vio_start),
        .probe_out1 ({vio_force_rst, vio_op}),
        .probe_out2 (vio_phyad),
        .probe_out3 (vio_regad),
        .probe_out4 (vio_wr_data)
    );

endmodule
