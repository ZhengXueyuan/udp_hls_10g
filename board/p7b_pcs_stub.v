// ============================================================================
// p7b_pcs_stub.v -- BEHAVIOURAL STAND-IN for the official `xxv_ethernet`
//   PCS/PMA 64-bit core (2 channels), used ONLY by the xsim full-chain gate
//   (sim/p7b_chain/run_tb_p7b_chain.bat, compile define P7B_SIM_NOPCS).
//
// WHY A STUB
//   The real core is an encrypted GT IP: bringing it up under xsim needs the
//   GTY/secureip models and was never attempted in this project (registered as
//   UNVERIFIED in P7B_XXV_OFFICIAL.md U15, and still unverified).  So the
//   wrapper's `ifdef P7B_10G` branch is exercised in simulation with THIS
//   module in the PCS socket instead.
//
// WHAT IT IS AND IS NOT
//   * It is a pure XGMII pump: it fabricates the two 156.25 MHz clocks, emits a
//     TB-controlled XGMII receive stream, and records the XGMII transmit stream.
//     That is exactly the interface the real PCS presents at the top level.
//   * It is NOT a PCS.  It does not do 64b/66b, scrambling, block lock or CDR.
//     Nothing here is evidence about the real core; the real-core evidence is
//     gate 1 / gate 2 (board measurements, see notes/P7B_GATE1.md, P7B_GATE2.md)
//     and P7A (PCS/PMA with gearbox, P7A_RESULT.md).
//   * The port list is deliberately IDENTICAL to the port list the wrapper
//     connects for the real `pcs64` instance (same names, same widths, same
//     directions) so the swap is one ifdef and the surrounding wiring is
//     literally the same text in sim and in synthesis.
//
// HOW THE TESTBENCH DRIVES IT
//   Hierarchical force on the injection registers, e.g.
//       force u_dut.u_pcs.inj_d1 = 64'h...;  force u_dut.u_pcs.inj_c1 = 8'h01;
//   and hierarchical read of the capture registers (txcap_d1/txcap_c1).  The
//   TB-facing signals are declared here (not in the TB) so that the naming is
//   owned by one file and cannot drift.
//
// CLOCK NOTE
//   tx_mii_clk_0/1 and rx_clk_out_0/1 are the PCS outputs that clock the MAC.
//   On the real core they are QPLL0-derived / CDR-recovered.  Here they are
//   free-running 156.25 MHz.  rx_core_clk_0/1 are INPUTS (the user loops
//   rx_clk_out back in, as the vendor example does).
// ============================================================================
`timescale 1ns/1ps

module p7b_pcs_stub (
    // ---- shared ----
    input  wire        gt_refclk_p,
    input  wire        gt_refclk_n,
    input  wire        dclk,
    input  wire        sys_reset,
    input  wire        qpllreset_in_0,
    output wire        gt_refclk_out,
    // ---- channel 0 (X0Y4 = SFP A = J7: no cable in the P7b setup) ----
    input  wire        gt_rxp_in_0,
    input  wire        gt_rxn_in_0,
    output wire        gt_txp_out_0,
    output wire        gt_txn_out_0,
    input  wire        rx_core_clk_0,
    input  wire [2:0]  txoutclksel_in_0,
    input  wire [2:0]  rxoutclksel_in_0,
    input  wire        gtwiz_reset_tx_datapath_0,
    input  wire        gtwiz_reset_rx_datapath_0,
    output wire        rxrecclkout_0,
    output wire        tx_mii_clk_0,
    output wire        rx_clk_out_0,
    output wire        gtpowergood_out_0,
    input  wire        rx_reset_0,
    output wire        user_rx_reset_0,
    output wire [63:0] rx_mii_d_0,
    output wire [7:0]  rx_mii_c_0,
    input  wire        ctl_rx_test_pattern_0,
    input  wire        ctl_rx_data_pattern_select_0,
    input  wire        ctl_rx_test_pattern_enable_0,
    input  wire        ctl_rx_prbs31_test_pattern_enable_0,
    output wire        stat_rx_framing_err_0,
    output wire        stat_rx_framing_err_valid_0,
    output wire        stat_rx_local_fault_0,
    output wire        stat_rx_block_lock_0,
    output wire        stat_rx_valid_ctrl_code_0,
    output wire        stat_rx_status_0,
    output wire        stat_rx_hi_ber_0,
    output wire        stat_rx_bad_code_0,
    output wire        stat_rx_bad_code_valid_0,
    output wire [7:0]  stat_rx_error_0,
    output wire        stat_rx_error_valid_0,
    output wire        stat_rx_fifo_error_0,
    input  wire        tx_reset_0,
    output wire        user_tx_reset_0,
    input  wire [63:0] tx_mii_d_0,
    input  wire [7:0]  tx_mii_c_0,
    output wire        stat_tx_local_fault_0,
    input  wire        ctl_tx_test_pattern_0,
    input  wire        ctl_tx_test_pattern_enable_0,
    input  wire        ctl_tx_test_pattern_select_0,
    input  wire        ctl_tx_data_pattern_select_0,
    input  wire [57:0] ctl_tx_test_pattern_seed_a_0,
    input  wire [57:0] ctl_tx_test_pattern_seed_b_0,
    input  wire        ctl_tx_prbs31_test_pattern_enable_0,
    input  wire [2:0]  gt_loopback_in_0,
    input  wire        ctl_rx_wdt_disable_0,
    // ---- channel 1 (X0Y5 = SFP B = J8: the ONE cabled channel) ----
    input  wire        gt_rxp_in_1,
    input  wire        gt_rxn_in_1,
    output wire        gt_txp_out_1,
    output wire        gt_txn_out_1,
    input  wire        rx_core_clk_1,
    input  wire [2:0]  txoutclksel_in_1,
    input  wire [2:0]  rxoutclksel_in_1,
    input  wire        gtwiz_reset_tx_datapath_1,
    input  wire        gtwiz_reset_rx_datapath_1,
    output wire        rxrecclkout_1,
    output wire        tx_mii_clk_1,
    output wire        rx_clk_out_1,
    output wire        gtpowergood_out_1,
    input  wire        rx_reset_1,
    output wire        user_rx_reset_1,
    output wire [63:0] rx_mii_d_1,
    output wire [7:0]  rx_mii_c_1,
    input  wire        ctl_rx_test_pattern_1,
    input  wire        ctl_rx_data_pattern_select_1,
    input  wire        ctl_rx_test_pattern_enable_1,
    input  wire        ctl_rx_prbs31_test_pattern_enable_1,
    output wire        stat_rx_framing_err_1,
    output wire        stat_rx_framing_err_valid_1,
    output wire        stat_rx_local_fault_1,
    output wire        stat_rx_block_lock_1,
    output wire        stat_rx_valid_ctrl_code_1,
    output wire        stat_rx_status_1,
    output wire        stat_rx_hi_ber_1,
    output wire        stat_rx_bad_code_1,
    output wire        stat_rx_bad_code_valid_1,
    output wire [7:0]  stat_rx_error_1,
    output wire        stat_rx_error_valid_1,
    output wire        stat_rx_fifo_error_1,
    input  wire        tx_reset_1,
    output wire        user_tx_reset_1,
    input  wire [63:0] tx_mii_d_1,
    input  wire [7:0]  tx_mii_c_1,
    output wire        stat_tx_local_fault_1,
    input  wire        ctl_tx_test_pattern_1,
    input  wire        ctl_tx_test_pattern_enable_1,
    input  wire        ctl_tx_test_pattern_select_1,
    input  wire        ctl_tx_data_pattern_select_1,
    input  wire [57:0] ctl_tx_test_pattern_seed_a_1,
    input  wire [57:0] ctl_tx_test_pattern_seed_b_1,
    input  wire        ctl_tx_prbs31_test_pattern_enable_1,
    input  wire [2:0]  gt_loopback_in_1,
    input  wire        ctl_rx_wdt_disable_1
);

    // ---------------------------------------------------------------- clocks
    // Free-running 156.25 MHz (6.400 ns).  rx_core_clk_* are user inputs.
    reg tx_clk = 1'b0;
    reg rx_clk = 1'b0;
    always #3.2 tx_clk = ~tx_clk;
    always #3.2 rx_clk = ~rx_clk;

    assign tx_mii_clk_0 = tx_clk;
    assign tx_mii_clk_1 = tx_clk;
    assign rx_clk_out_0 = rx_clk;
    assign rx_clk_out_1 = rx_clk;

    // ------------------------------------------------------- link-up releases
    // user_*_reset_* are ACTIVE HIGH on the real core (the MAC ports document
    // rst_n = ~user_*_reset_*).  Release them a few cycles after sys_reset drops.
    reg [7:0] rel_cnt = 8'd0;
    always @(posedge dclk) if (!sys_reset && rel_cnt != 8'hFF) rel_cnt <= rel_cnt + 8'd1;
    wire rel = (rel_cnt == 8'hFF);

    // ------------------------------------------------------------ RX injection
    // TB-forced.  Default = XGMII IDLE (all lanes /I/ = 0x07, c = 8'hFF), which
    // is what a 10GBASE-R link sends when it has nothing to say.
    reg [63:0] inj_d1 = 64'h0707070707070707;
    reg [7:0]  inj_c1 = 8'hFF;
    reg [63:0] inj_d0 = 64'h0707070707070707;
    reg [7:0]  inj_c0 = 8'hFF;

    // Registered once so the TB sees the same "one XGMII word per rx_clk" shape
    // the real core has (its rx_mii_d/c come out of the RX destriper registers).
    reg [63:0] rx_d1_r = 64'h0707070707070707;
    reg [7:0]  rx_c1_r = 8'hFF;
    reg [63:0] rx_d0_r = 64'h0707070707070707;
    reg [7:0]  rx_c0_r = 8'hFF;
    always @(posedge rx_clk) begin
        if (!rel) begin
            rx_d1_r <= 64'h0707070707070707; rx_c1_r <= 8'hFF;
            rx_d0_r <= 64'h0707070707070707; rx_c0_r <= 8'hFF;
        end else begin
            rx_d1_r <= inj_d1; rx_c1_r <= inj_c1;
            rx_d0_r <= inj_d0; rx_c0_r <= inj_c0;
        end
    end
    assign rx_mii_d_1 = rx_d1_r;
    assign rx_mii_c_1 = rx_c1_r;
    assign rx_mii_d_0 = rx_d0_r;
    assign rx_mii_c_0 = rx_c0_r;

    // ----------------------------------------------------------- TX capture
    // The TB reads these to judge what the MAC put on the wire.  Registered on
    // tx_clk exactly as the real core's TX XGMII capture registers are.
    reg [63:0] txcap_d1 = 64'h0707070707070707;
    reg [7:0]  txcap_c1 = 8'hFF;
    reg [63:0] txcap_d0 = 64'h0707070707070707;
    reg [7:0]  txcap_c0 = 8'hFF;
    always @(posedge tx_clk) begin
        txcap_d1 <= tx_mii_d_1; txcap_c1 <= tx_mii_c_1;
        txcap_d0 <= tx_mii_d_0; txcap_c0 <= tx_mii_c_0;
    end

    // -------------------------------------------------------- status (forced)
    // A healthy link by default, so that the datapath downstream of the MAC is
    // not gated by a status that this stub cannot actually produce.  The TB
    // forces these to exercise the snapshot plumbing.
    reg blk_lock = 1'b0, rx_stat = 1'b0, hi_ber = 1'b0;
    reg rloc_fault = 1'b0, tloc_fault = 1'b0;
    reg ferr = 1'b0, ferr_v = 1'b0, bcode = 1'b0, bcode_v = 1'b0;
    reg ferr_fifo = 1'b0, vcc = 1'b0;
    reg [7:0] rerr = 8'd0; reg rerr_v = 1'b0;
    always @(posedge dclk) if (rel) begin
        blk_lock <= 1'b1; rx_stat <= 1'b1; vcc <= 1'b1;
    end

    assign stat_rx_block_lock_0    = blk_lock;
    assign stat_rx_block_lock_1    = blk_lock;
    assign stat_rx_status_0        = rx_stat;
    assign stat_rx_status_1        = rx_stat;
    assign stat_rx_hi_ber_0        = hi_ber;
    assign stat_rx_hi_ber_1        = hi_ber;
    assign stat_rx_local_fault_0   = rloc_fault;
    assign stat_rx_local_fault_1   = rloc_fault;
    assign stat_tx_local_fault_0   = tloc_fault;
    assign stat_tx_local_fault_1   = tloc_fault;
    assign stat_rx_framing_err_0       = ferr;
    assign stat_rx_framing_err_1       = ferr;
    assign stat_rx_framing_err_valid_0 = ferr_v;
    assign stat_rx_framing_err_valid_1 = ferr_v;
    assign stat_rx_bad_code_0          = bcode;
    assign stat_rx_bad_code_1          = bcode;
    assign stat_rx_bad_code_valid_0    = bcode_v;
    assign stat_rx_bad_code_valid_1    = bcode_v;
    assign stat_rx_error_0             = rerr;
    assign stat_rx_error_1             = rerr;
    assign stat_rx_error_valid_0       = rerr_v;
    assign stat_rx_error_valid_1       = rerr_v;
    assign stat_rx_fifo_error_0        = ferr_fifo;
    assign stat_rx_fifo_error_1        = ferr_fifo;
    assign stat_rx_valid_ctrl_code_0   = vcc;
    assign stat_rx_valid_ctrl_code_1   = vcc;

    assign user_rx_reset_0 = ~rel;
    assign user_rx_reset_1 = ~rel;
    assign user_tx_reset_0 = ~rel;
    assign user_tx_reset_1 = ~rel;
    assign gtpowergood_out_0 = rel;
    assign gtpowergood_out_1 = rel;

    // deliberately unused outputs (the real core documents these as "do not
    // consume": they can only drive clock resources)
    assign gt_refclk_out  = 1'b0;
    assign rxrecclkout_0  = 1'b0;
    assign rxrecclkout_1  = 1'b0;
    assign gt_txp_out_0   = 1'b0;
    assign gt_txn_out_0   = 1'b0;
    assign gt_txp_out_1   = 1'b0;
    assign gt_txn_out_1   = 1'b0;

endmodule
