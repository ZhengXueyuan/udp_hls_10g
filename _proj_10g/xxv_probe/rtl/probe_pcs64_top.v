// ============================================================================
// probe_pcs64_top.v -- P7b probe: thin board wrapper around the OFFICIAL
//   xxv_ethernet 5.0 core, CORE = "Ethernet PCS/PMA 64-bit", 10G BASE-R, GTY,
//   156.25 MHz reference, GTY X0Y4 (= SFP A on the XCKU5P Mini).
//
// Wiring follows the vendor's own example design (pcs64_exdes.v) verbatim
// where the core is concerned:
//     rx_core_clk_0 = rx_clk_out_0
//     txoutclksel_in_0 = rxoutclksel_in_0 = 3'b101
//     gtwiz_reset_{tx,rx}_datapath_0 = 0 ; qpllreset_in_0 = 0
//     ctl_rx_wdt_disable_0 = 0 ; gt_loopback_in_0 = 0
//
// XGMII byte order (measured from the vendor packet generator, not assumed):
//   pcs64_pkt_gen_mon.v:1240  swapn[i+:8] = d[(63-i)-:8]
//   pcs64_pkt_gen_mon.v:1199  if(full_bits != 0) tx_mii_d[full_bits+:8] <= 8'hFD
//   => tx_mii_d[7:0] = lane 0 = the FIRST byte on the wire.
//   i.e. XGMII is LSB-first per byte; the OPPOSITE of this project's frozen
//   tdata[63:56] = first byte convention.  A 64-bit reversal, zero logic.
//
// This design exists to answer "does the licence let it build" -- it is NOT
// for programming the board.
// ============================================================================
`timescale 1ns/1ps

module probe_pcs64_top (
    input  wire        gt_refclk_p,
    input  wire        gt_refclk_n,
    output wire        sfp1_txp,
    output wire        sfp1_txn,
    input  wire        sfp1_rxp,
    input  wire        sfp1_rxn,
    input  wire        sys_clk_p,      // core board Y1 = 100 MHz
    input  wire        sys_clk_n,
    input  wire        sys_reset,      // active high
    output wire        sfp1_tx_dis,    // active high disable -> drive LOW
    output wire [3:0]  led
);

    // ---------------------------------------------------------- 100 MHz dclk
    wire dclk_ibuf, dclk;
    IBUFDS u_ibufds_sysclk (.I(sys_clk_p), .IB(sys_clk_n), .O(dclk_ibuf));
    BUFG   u_bufg_sysclk   (.I(dclk_ibuf), .O(dclk));

    assign sfp1_tx_dis = 1'b0;         // 10k pull-up would otherwise kill TX

    // ------------------------------------------------------------- core nets
    wire        rx_core_clk, rx_clk_out, tx_mii_clk, rxrecclkout;
    wire        rx_reset, user_rx_reset, tx_reset, user_tx_reset;
    wire        gtpowergood, gt_refclk_out;
    wire [63:0] rx_mii_d, tx_mii_d;
    wire [7:0]  rx_mii_c, tx_mii_c;
    wire        stat_rx_block_lock, stat_rx_status, stat_rx_hi_ber;
    wire        stat_rx_local_fault, stat_rx_framing_err, stat_rx_framing_err_valid;
    wire        stat_rx_valid_ctrl_code, stat_rx_bad_code, stat_rx_bad_code_valid;
    wire        stat_rx_error_valid, stat_rx_fifo_error, stat_tx_local_fault;
    wire [7:0]  stat_rx_error;

    // vendor example wiring: the recovered clock loops back in
    assign rx_core_clk = rx_clk_out;

    pcs64 DUT (
        .gt_rxp_in_0                      (sfp1_rxp),
        .gt_rxn_in_0                      (sfp1_rxn),
        .gt_txp_out_0                     (sfp1_txp),
        .gt_txn_out_0                     (sfp1_txn),
        .rx_core_clk_0                    (rx_core_clk),
        .txoutclksel_in_0                 (3'b101),
        .rxoutclksel_in_0                 (3'b101),
        .gtwiz_reset_tx_datapath_0        (1'b0),
        .gtwiz_reset_rx_datapath_0        (1'b0),
        .rxrecclkout_0                    (rxrecclkout),
        .sys_reset                        (sys_reset),
        .dclk                             (dclk),
        .tx_mii_clk_0                     (tx_mii_clk),
        .rx_clk_out_0                     (rx_clk_out),
        .gt_refclk_p                      (gt_refclk_p),
        .gt_refclk_n                      (gt_refclk_n),
        .gt_refclk_out                    (gt_refclk_out),
        .gtpowergood_out_0                (gtpowergood),
        .rx_reset_0                       (rx_reset),
        .user_rx_reset_0                  (user_rx_reset),
        .rx_mii_d_0                       (rx_mii_d),
        .rx_mii_c_0                       (rx_mii_c),
        .ctl_rx_test_pattern_0            (1'b0),
        .ctl_rx_data_pattern_select_0     (1'b0),
        .ctl_rx_test_pattern_enable_0     (1'b0),
        .ctl_rx_prbs31_test_pattern_enable_0 (1'b0),
        .stat_rx_framing_err_0            (stat_rx_framing_err),
        .stat_rx_framing_err_valid_0      (stat_rx_framing_err_valid),
        .stat_rx_local_fault_0            (stat_rx_local_fault),
        .stat_rx_block_lock_0             (stat_rx_block_lock),
        .stat_rx_valid_ctrl_code_0        (stat_rx_valid_ctrl_code),
        .stat_rx_status_0                 (stat_rx_status),
        .stat_rx_hi_ber_0                 (stat_rx_hi_ber),
        .stat_rx_bad_code_0               (stat_rx_bad_code),
        .stat_rx_bad_code_valid_0         (stat_rx_bad_code_valid),
        .stat_rx_error_0                  (stat_rx_error),
        .stat_rx_error_valid_0            (stat_rx_error_valid),
        .stat_rx_fifo_error_0             (stat_rx_fifo_error),
        .tx_reset_0                       (tx_reset),
        .user_tx_reset_0                  (user_tx_reset),
        .tx_mii_d_0                       (tx_mii_d),
        .tx_mii_c_0                       (tx_mii_c),
        .stat_tx_local_fault_0            (stat_tx_local_fault),
        .ctl_tx_test_pattern_0            (1'b0),
        .ctl_tx_test_pattern_enable_0     (1'b0),
        .ctl_tx_test_pattern_select_0     (1'b0),
        .ctl_tx_data_pattern_select_0     (1'b0),
        .ctl_tx_test_pattern_seed_a_0     (58'd0),
        .ctl_tx_test_pattern_seed_b_0     (58'd0),
        .ctl_tx_prbs31_test_pattern_enable_0 (1'b0),
        .gt_loopback_in_0                 (3'b000),
        .qpllreset_in_0                   (1'b0),
        .ctl_rx_wdt_disable_0             (1'b0)
    );

    // ======================================================================
    // Minimal XGMII traffic generator, lane 0 = first byte.
    //   word0 : lane0 = 0xFB (start), lanes 1..7 = 0x55 (preamble)
    //   word1 : lane0 = 0xD5 (SFD)  , lanes 1..7 = data[0..6]
    //   then  : 8 data words (64 B payload), all-control = 0
    //   word9 : lane0 = 0xFD (terminate), rest idle 0x07
    // ======================================================================
    localparam IDLE_GAP = 16'd1024;

    reg [15:0] gap;
    reg [3:0]  wcnt;
    reg [63:0] pay;
    reg        active;
    reg [63:0] tx_d;
    reg [7:0]  tx_c;

    always @(posedge tx_mii_clk) begin
        if (gap == 16'd0) begin
            gap    <= IDLE_GAP;
            active <= 1'b1;
            wcnt   <= 4'd0;
            pay    <= pay + 64'h0101010101010101;
        end else begin
            gap <= gap - 16'd1;
        end

        if (!active) begin
            tx_d <= 64'h0707070707070707;
            tx_c <= 8'hFF;
        end else begin
            case (wcnt)
                4'd0: begin
                    tx_d <= {56'h55555555555555, 8'hFB};  // lanes 7..1 preamble, lane0 = S
                    tx_c <= 8'h01;
                end
                4'd1: begin
                    tx_d <= {pay[31:24], pay[23:16], pay[15:8], 8'hD5};
                    tx_c <= 8'h01;               // lane0 = 0xD5 = SFD
                end
                4'd9: begin
                    tx_d <= {56'h07070707070707, 8'hFD};
                    tx_c <= 8'hFF;               // terminate right after 64 B
                end
                default: begin
                    tx_d <= pay;
                    tx_c <= 8'h00;
                end
            endcase
            if (wcnt == 4'd10) active <= 1'b0;
            else               wcnt   <= wcnt + 4'd1;
        end
    end

    assign tx_mii_d = tx_d;
    assign tx_mii_c = tx_c;

    // ======================================================================
    // RX observation
    // ======================================================================
    reg [63:0] rx_d_q;
    reg [7:0]  rx_c_q;
    reg [31:0] rx_bytes;
    reg [15:0] rx_words;
    reg        rx_saw_term;

    always @(posedge rx_core_clk) begin
        rx_d_q    <= rx_mii_d;
        rx_c_q    <= rx_mii_c;
        rx_words  <= rx_words + 16'd1;
        if (rx_mii_c == 8'h00)                           rx_bytes   <= rx_bytes + 32'd8;
        else if (rx_mii_c[0] && rx_mii_d[7:0] == 8'hFD)  rx_saw_term <= 1'b1;
    end

    assign led[0] = stat_rx_block_lock;
    assign led[1] = stat_rx_status | rx_saw_term;
    assign led[2] = stat_rx_hi_ber;

    // MEASURED GOTCHA (same as probe_macpcs64_top.v): leaving the core's
    // rx_reset_0 / tx_reset_0 outputs unconsumed makes opt_design fail with
    // [Opt 31-155] driverless net -> [Opt 31-67] dangling LUT input, because
    // the core's reset-done CDC logic reads those nets back.  Consume them.
    wire obs = rx_reset | tx_reset | user_rx_reset | user_tx_reset
             | gtpowergood | rx_bytes[24]
             | (^rx_d_q) | (^rx_c_q) | rx_words[0];
    reg [3:0] obs_sr;
    always @(posedge dclk) obs_sr <= {obs_sr[2:0], obs};

    assign led[3] = obs_sr[3];

endmodule
