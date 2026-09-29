// ============================================================================
// xxv_loop_top.v -- P7b gate 1: OFFICIAL xxv_ethernet PCS/PMA 64-bit (TWO
//   channels) driven by the OFFICIAL example-design packet generator/monitor,
//   over the board's in-cabinet fibre loop J7 <-> J8.
//
// WHY TWO CHANNELS
//   XCKU5P Mini: SFP A = J7 = GTY X0Y4, SFP B = J8 = GTY X0Y5, quad 225,
//   reference clock 156.25 MHz on V7/V6 (= MGTREFCLK0_225, silkscreen Y2).
//   One AOC joins J7 and J8, so the optical path is "X0Y4 TX -> fibre -> X0Y5
//   RX" (and the reverse).  A one-channel core -- which is what the first P7b
//   reconnaissance probe built -- can transmit but has no receiver on X0Y5 at
//   all, so this loop is impossible with it.
//
// THE TRAFFIC SOURCE IS THE VENDOR'S MODULE, UNMODIFIED
//   ../xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v  (AMD plaintext)
//   It carries its own pattern generator, its own XGMII monitor and its own
//   judging FSM.  completion_status:
//     0 TEST_START 1 SUCCESSFUL_COMPLETION 2 NO_BLOCK_LOCK 3 PARTIAL_BLOCK_LOCK
//     4 INCONSISTENT_BLOCK_LOCK 5 NO_LANE_SYNC 6 PARTIAL_LANE_SYNC
//     7 INCONSISTENT_LANE_SYNC 8 NO_ALIGN_OR_STATUS 9 LOSS_OF_STATUS
//     10 TX_TIMED_OUT 11 NO_DATA_SENT 12 SENT_COUNT_MISMATCH
//     13 BYTE_COUNT_MISMATCH 14 LBUS_PROTOCOL 15 BIT_ERRORS_IN_DATA
//     31 NO_START
//   ==1 requires: tx_done set, tx_sent_count == rx_packet_count,
//   tx_total_bytes == rx_total_bytes, rx error count zero.  NO_DATA_SENT
//   exists so that an all-zero (vacuous) result cannot be reported as a pass.
//
// THE ONE CHANGE TO THE VENDOR WIRING (and why it is still the vendor's test)
//   pcs64_exdes.v binds the generator and the monitor to the SAME channel and
//   closes the loop in the testbench (gt_rxp_in_0 = gt_txp_out_0).  That proves
//   self-consistency only.  Here the module is instantiated ONCE with its two
//   ends bound to DIFFERENT channels:
//        generator : gen_clk = tx_mii_clk_0 (X0Y4 TX) -> SFP A -> AOC -> SFP B
//        monitor   : mon_clk = rx_clk_out_1 (X0Y5 RX) <- SFP B
//        stat_rx_* -> channel 1        stat_tx_local_fault -> channel 0
//        user_tx_reset -> channel 0    user_rx_reset       -> channel 1
//   The generator's "sent" counter is still clocked by the X0Y4 TX clock and
//   still counts what X0Y4 transmits; the monitor still counts what X0Y5
//   receives; so the FSM's equality tests are literally the statement
//   "everything X0Y4 transmitted arrived at X0Y5".
//
// X0Y5 ALSO TRANSMITS, so the measurement is bidirectional
//   A constant 64b/66b IDLE stream (all lanes /I/ = 0x07, c=1) is driven onto
//   the X0Y5 transmitter.  10GBASE-R needs a continuous block stream, and this
//   gives the X0Y4 receiver a real signal to lock onto -- a second, fully
//   independent link direction with its own block lock, hi_ber, framing-error
//   and control-block counters.
//
// OBSERVATION: VIO over JTAG (no UART on this board).  Every probe_in net is
//   registered in dclk, and every multi-bit counter crosses clock domains via
//   the toggle handshake in obs_util.v -- never through two flops.
//
// VIO MAP (must match tcl/s2_build.tcl exactly):
//   probe_out0[0] send_cont        1 = generator streams continuously (level)
//   probe_out1[0] cmd_restart      rising edge -> 10 us restart_tx_rx pulse
//   probe_out2[0] cmd_sysreset     rising edge -> 10 ms sys_reset pulse
//   probe_out3[0] cmd_sfp1_tx_dis  1 = force C11 (SFP1 TX_DIS) high NEG CONTROL
//   probe_out4[0] cmd_sfp2_tx_dis  1 = force D9  (SFP2 TX_DIS) high NEG CONTROL
//   probe_out5[0] cmd_snap         rising edge -> one snapshot of all counters
//   probe_in0  st0   ch0 levels: {..,led_blk,led_gt,completion_status[4:0],
//                    user_tx_reset_0,user_rx_reset_0, sfp1_rx_los,
//                    tx_local_fault_0, fifo_err_0, err_valid_0, bad_code_0,
//                    framing_err_0, rx_local_fault_0, hi_ber_0, rx_status_0,
//                    block_lock_0, gtpowergood_0}
//   probe_in1  st1   same for channel 1 + {c1_inframe, c0_inframe}
//   probe_in2  cnt0  {vcc,framing,badcode,fifo} 8b each (ch0)
//   probe_in3  cnt1  same (ch1)
//   probe_in4  dclk_free        probe_in5  tx0_free  (snap)
//   probe_in6  rx0_free (snap)  probe_in7  rx1_free  (snap)
//   probe_in8..12  chk0: words, ctrl, idle, e, frames
//   probe_in13..26 chk1: words, frames, ctrl, e, pay, badpay, badstart,
//                        badhdr, badterm, badlen, abort, lastw, idle, misc
//   probe_in27 snap_gen  {snap_gen[15:0], 13'b0, ack_tx0, ack_rx0, ack_rx1}
//   probe_in28/29 chk1_sword[31:0]/[63:32]   probe_in30 chk0_sword[31:0]
//   probe_in31 flags     {c1_inframe, c0_inframe, 30'b0}
//   probe_in32 err_w     {n_errv1, acc_err1, n_errv0, acc_err0}   (8 bits each)
//   probe_in33 dclk_snap snapshotted dclk_free -- the time base for every
//                        frequency ratio, latched by the SAME request
// ============================================================================
`timescale 1ns/1ps

module xxv_loop_top (
    input  wire        gt_refclk_p,
    input  wire        gt_refclk_n,
    input  wire        sys_clk_p,        // core board Y1 = 100 MHz -> dclk
    input  wire        sys_clk_n,
    input  wire        sfp1_rxp,         // GT serial, balls follow channel LOC X0Y4
    input  wire        sfp1_rxn,
    output wire        sfp1_txp,
    output wire        sfp1_txn,
    input  wire        sfp2_rxp,         // GT serial, balls follow channel LOC X0Y5
    input  wire        sfp2_rxn,
    output wire        sfp2_txp,
    output wire        sfp2_txn,
    input  wire        sfp1_rx_los,      // B11  (MEASURED pin map, see the XDC)
    input  wire        sfp2_rx_los,      // C9
    output wire        sfp1_tx_dis,      // C11, active-high disable: drive LOW
    output wire        sfp2_tx_dis,      // D9,  active-high disable: drive LOW
    output wire [3:0]  led
);

    // ------------------------------------------------------------------ dclk
    wire dclk_ibuf, dclk;
    IBUFDS u_sysclk_ibuf (.I(sys_clk_p), .IB(sys_clk_n), .O(dclk_ibuf));
    BUFG   u_sysclk_bufg (.I(dclk_ibuf), .O(dclk));

    // -------------------------------------------------------------- reset
    // Every FF leaves configuration at 0, so a saturating counter is a complete
    // power-on reset: 2^20 cycles at 100 MHz = 10.5 ms.
    reg [19:0] por_cnt = 20'd0;
    wire       por_n   = &por_cnt;
    always @(posedge dclk) if (!por_n) por_cnt <= por_cnt + 20'd1;

    // VIO-issued reset / restart pulses: the JTAG host holds a LEVEL, the RTL
    // turns its rising edge into a bounded pulse (project rule -- a JTAG commit
    // takes milliseconds, a single-cycle control would be invisible).
    wire       vio_send_cont, vio_cmd_restart, vio_cmd_sysreset;
    wire       vio_cmd_sfp1_tx_dis, vio_cmd_sfp2_tx_dis, vio_cmd_snap;
    wire [2:0] vio_gt_loopback;   // ch0 GT loopback mode (gate 1a witness)
    wire       vio_pay_sel;       // 0 = vendor all-zero payload, 1 = all-ones

    reg  cmd_restart_d = 1'b0;
    reg  cmd_sysrst_d  = 1'b0;
    reg [15:0] restart_cnt = 16'd0;      // ~10 us at 100 MHz
    reg [19:0] sysrst_cnt  = 20'd0;      // ~10 ms at 100 MHz

    always @(posedge dclk) begin
        cmd_restart_d <= vio_cmd_restart;
        if (vio_cmd_restart && !cmd_restart_d) restart_cnt <= 16'd1000;
        else if (restart_cnt != 16'd0)         restart_cnt <= restart_cnt - 16'd1;

        cmd_sysrst_d <= vio_cmd_sysreset;
        if (vio_cmd_sysreset && !cmd_sysrst_d) sysrst_cnt <= 20'hFFFFF;
        else if (sysrst_cnt != 20'd0)          sysrst_cnt <= sysrst_cnt - 20'd1;
    end
    wire sys_reset     = ~por_n | (sysrst_cnt != 20'd0);
    wire restart_tx_rx = (restart_cnt != 16'd0);

    // ------------------------------------------------------------ SFP control
    // TX_DIS is active high and pulled up on the board: leaving it floating
    // kills the module transmitter and makes the whole link dark -- the classic
    // false "this board cannot do 10G".  Only the VIO can raise it.
    assign sfp1_tx_dis = vio_cmd_sfp1_tx_dis;
    assign sfp2_tx_dis = vio_cmd_sfp2_tx_dis;

    // ------------------------------------------------------------- core nets
    wire        rx_core_clk_0, rx_core_clk_1;
    wire        tx_mii_clk_0, tx_mii_clk_1;
    wire        rx_clk_out_0, rx_clk_out_1;
    wire [63:0] rx_mii_d_0, rx_mii_d_1;
    wire [7:0]  rx_mii_c_0, rx_mii_c_1;
    wire [63:0] tx_mii_d_0, tx_mii_d_1;
    wire [7:0]  tx_mii_c_0, tx_mii_c_1;

    // vendor example wiring: each recovered clock loops straight back in
    assign rx_core_clk_0 = rx_clk_out_0;
    assign rx_core_clk_1 = rx_clk_out_1;

    wire gtpowergood_out_0, gtpowergood_out_1;
    wire rx_reset_0, tx_reset_0, user_rx_reset_0, user_tx_reset_0;
    wire rx_reset_1, tx_reset_1, user_rx_reset_1, user_tx_reset_1;
    wire        stat_rx_block_lock_0, stat_rx_status_0, stat_rx_hi_ber_0;
    wire        stat_rx_local_fault_0, stat_rx_framing_err_0, stat_rx_framing_err_valid_0;
    wire        stat_rx_valid_ctrl_code_0, stat_rx_bad_code_0, stat_rx_bad_code_valid_0;
    wire        stat_rx_error_valid_0, stat_rx_fifo_error_0, stat_tx_local_fault_0;
    wire [7:0]  stat_rx_error_0;
    wire        stat_rx_block_lock_1, stat_rx_status_1, stat_rx_hi_ber_1;
    wire        stat_rx_local_fault_1, stat_rx_framing_err_1, stat_rx_framing_err_valid_1;
    wire        stat_rx_valid_ctrl_code_1, stat_rx_bad_code_1, stat_rx_bad_code_valid_1;
    wire        stat_rx_error_valid_1, stat_rx_fifo_error_1, stat_tx_local_fault_1;
    wire [7:0]  stat_rx_error_1;

    // deliberately NOT consumed: rxrecclkout / gt_refclk_out can only drive
    // clock resources; wiring them into logic makes route_design fail (measured
    // during the reconnaissance probe).
    wire        rxrecclkout_0, rxrecclkout_1, gt_refclk_out;

    wire ctl_tx_test_pattern_0, ctl_tx_test_pattern_enable_0;
    wire ctl_tx_test_pattern_select_0, ctl_tx_data_pattern_select_0;
    wire [57:0] ctl_tx_test_pattern_seed_a_0, ctl_tx_test_pattern_seed_b_0;
    wire ctl_tx_prbs31_test_pattern_enable_0;
    wire ctl_rx_test_pattern_1, ctl_rx_data_pattern_select_1;
    wire ctl_rx_test_pattern_enable_1, ctl_rx_prbs31_test_pattern_enable_1;

    pcs64 DUT (
        .gt_rxp_in_0                      (sfp1_rxp),
        .gt_rxn_in_0                      (sfp1_rxn),
        .gt_txp_out_0                     (sfp1_txp),
        .gt_txn_out_0                     (sfp1_txn),
        .gt_rxp_in_1                      (sfp2_rxp),
        .gt_rxn_in_1                      (sfp2_rxn),
        .gt_txp_out_1                     (sfp2_txp),
        .gt_txn_out_1                     (sfp2_txn),
        .rx_core_clk_0                    (rx_core_clk_0),
        .rx_core_clk_1                    (rx_core_clk_1),
        .txoutclksel_in_0                 (3'b101),
        .txoutclksel_in_1                 (3'b101),
        .rxoutclksel_in_0                 (3'b101),
        .rxoutclksel_in_1                 (3'b101),
        .gtwiz_reset_tx_datapath_0        (1'b0),
        .gtwiz_reset_tx_datapath_1        (1'b0),
        .gtwiz_reset_rx_datapath_0        (1'b0),
        .gtwiz_reset_rx_datapath_1        (1'b0),
        .rxrecclkout_0                    (rxrecclkout_0),
        .rxrecclkout_1                    (rxrecclkout_1),
        .sys_reset                        (sys_reset),
        .dclk                             (dclk),
        .tx_mii_clk_0                     (tx_mii_clk_0),
        .tx_mii_clk_1                     (tx_mii_clk_1),
        .rx_clk_out_0                     (rx_clk_out_0),
        .rx_clk_out_1                     (rx_clk_out_1),
        .gt_refclk_p                      (gt_refclk_p),
        .gt_refclk_n                      (gt_refclk_n),
        .gt_refclk_out                    (gt_refclk_out),
        .gtpowergood_out_0                (gtpowergood_out_0),
        .gtpowergood_out_1                (gtpowergood_out_1),
        // ---- channel 0 = SFP A = X0Y4 : transmitter of the judged direction
        .rx_reset_0                       (rx_reset_0),
        .user_rx_reset_0                  (user_rx_reset_0),
        .rx_mii_d_0                       (rx_mii_d_0),
        .rx_mii_c_0                       (rx_mii_c_0),
        .ctl_rx_test_pattern_0            (1'b0),
        .ctl_rx_data_pattern_select_0     (1'b0),
        .ctl_rx_test_pattern_enable_0     (1'b0),
        .ctl_rx_prbs31_test_pattern_enable_0 (1'b0),
        .stat_rx_framing_err_0            (stat_rx_framing_err_0),
        .stat_rx_framing_err_valid_0      (stat_rx_framing_err_valid_0),
        .stat_rx_local_fault_0            (stat_rx_local_fault_0),
        .stat_rx_block_lock_0             (stat_rx_block_lock_0),
        .stat_rx_valid_ctrl_code_0        (stat_rx_valid_ctrl_code_0),
        .stat_rx_status_0                 (stat_rx_status_0),
        .stat_rx_hi_ber_0                 (stat_rx_hi_ber_0),
        .stat_rx_bad_code_0               (stat_rx_bad_code_0),
        .stat_rx_bad_code_valid_0         (stat_rx_bad_code_valid_0),
        .stat_rx_error_0                  (stat_rx_error_0),
        .stat_rx_error_valid_0            (stat_rx_error_valid_0),
        .stat_rx_fifo_error_0             (stat_rx_fifo_error_0),
        .tx_reset_0                       (tx_reset_0),
        .user_tx_reset_0                  (user_tx_reset_0),
        .tx_mii_d_0                       (tx_mii_d_0),
        .tx_mii_c_0                       (tx_mii_c_0),
        .stat_tx_local_fault_0            (stat_tx_local_fault_0),
        .ctl_tx_test_pattern_0            (ctl_tx_test_pattern_0),
        .ctl_tx_test_pattern_enable_0     (ctl_tx_test_pattern_enable_0),
        .ctl_tx_test_pattern_select_0     (ctl_tx_test_pattern_select_0),
        .ctl_tx_data_pattern_select_0     (ctl_tx_data_pattern_select_0),
        .ctl_tx_test_pattern_seed_a_0     (ctl_tx_test_pattern_seed_a_0),
        .ctl_tx_test_pattern_seed_b_0     (ctl_tx_test_pattern_seed_b_0),
        .ctl_tx_prbs31_test_pattern_enable_0 (ctl_tx_prbs31_test_pattern_enable_0),
        // ---- channel 1 = SFP B = X0Y5 : receiver of the judged direction
        .rx_reset_1                       (rx_reset_1),
        .user_rx_reset_1                  (user_rx_reset_1),
        .rx_mii_d_1                       (rx_mii_d_1),
        .rx_mii_c_1                       (rx_mii_c_1),
        .ctl_rx_test_pattern_1            (ctl_rx_test_pattern_1),
        .ctl_rx_data_pattern_select_1     (ctl_rx_data_pattern_select_1),
        .ctl_rx_test_pattern_enable_1     (ctl_rx_test_pattern_enable_1),
        .ctl_rx_prbs31_test_pattern_enable_1 (ctl_rx_prbs31_test_pattern_enable_1),
        .stat_rx_framing_err_1            (stat_rx_framing_err_1),
        .stat_rx_framing_err_valid_1      (stat_rx_framing_err_valid_1),
        .stat_rx_local_fault_1            (stat_rx_local_fault_1),
        .stat_rx_block_lock_1             (stat_rx_block_lock_1),
        .stat_rx_valid_ctrl_code_1        (stat_rx_valid_ctrl_code_1),
        .stat_rx_status_1                 (stat_rx_status_1),
        .stat_rx_hi_ber_1                 (stat_rx_hi_ber_1),
        .stat_rx_bad_code_1               (stat_rx_bad_code_1),
        .stat_rx_bad_code_valid_1         (stat_rx_bad_code_valid_1),
        .stat_rx_error_1                  (stat_rx_error_1),
        .stat_rx_error_valid_1            (stat_rx_error_valid_1),
        .stat_rx_fifo_error_1             (stat_rx_fifo_error_1),
        .tx_reset_1                       (tx_reset_1),
        .user_tx_reset_1                  (user_tx_reset_1),
        .tx_mii_d_1                       (tx_mii_d_1),
        .tx_mii_c_1                       (tx_mii_c_1),
        .stat_tx_local_fault_1            (stat_tx_local_fault_1),
        .ctl_tx_test_pattern_1            (1'b0),
        .ctl_tx_test_pattern_enable_1     (1'b0),
        .ctl_tx_test_pattern_select_1     (1'b0),
        .ctl_tx_data_pattern_select_1     (1'b0),
        .ctl_tx_test_pattern_seed_a_1     (58'd0),
        .ctl_tx_test_pattern_seed_b_1     (58'd0),
        .ctl_tx_prbs31_test_pattern_enable_1 (1'b0),
        .gt_loopback_in_0                 (vio_gt_loopback),
        .gt_loopback_in_1                 (3'b000),
        .qpllreset_in_0                   (1'b0),
        .ctl_rx_wdt_disable_0             (1'b0),
        .ctl_rx_wdt_disable_1             (1'b0)
    );

    // X0Y5 transmits a constant 64b/66b IDLE stream (/I/ = 0x07, c=1 on every
    // lane).  10GBASE-R requires a continuous block stream, and it hands the
    // X0Y4 receiver a real signal to lock onto.
    assign tx_mii_d_1 = 64'h0707070707070707;
    assign tx_mii_c_1 = 8'hFF;

    // ------------------------------------------- the vendor traffic module
    wire [4:0] completion_status;
    wire       tgm_gt_locked_led, tgm_block_lock_led;

    pcs64_pkt_gen_mon_ds #(
        .PKT_NUM             (20),
        .FIXED_PACKET_LENGTH (256),   // pkt_len%8 == 0 : the frame geometry that
        .MIN_LENGTH          (64),    // xgmii_rx_chk's constants assume
        .MAX_LENGTH          (9000)
    ) u_tgm (
        .gen_clk                       (tx_mii_clk_0),      // X0Y4 TX domain
        .mon_clk                       (rx_core_clk_1),     // X0Y5 RX domain
        .dclk                          (dclk),
        .sys_reset                     (sys_reset),
        .restart_tx_rx                 (restart_tx_rx),
        .send_continuous_pkts          (vio_send_cont),
        .pay_sel                       (vio_pay_sel),
        // RX end = channel 1
        .rx_reset                      (rx_reset_1),
        .user_rx_reset                 (user_rx_reset_1),
        .rx_mii_d                      (rx_mii_d_1),
        .rx_mii_c                      (rx_mii_c_1),
        .ctl_rx_test_pattern           (ctl_rx_test_pattern_1),
        .ctl_rx_test_pattern_enable    (ctl_rx_test_pattern_enable_1),
        .ctl_rx_data_pattern_select    (ctl_rx_data_pattern_select_1),
        .ctl_rx_prbs31_test_pattern_enable (ctl_rx_prbs31_test_pattern_enable_1),
        .stat_rx_block_lock            (stat_rx_block_lock_1),
        .stat_rx_framing_err_valid     (stat_rx_framing_err_valid_1),
        .stat_rx_framing_err           (stat_rx_framing_err_1),
        .stat_rx_hi_ber                (stat_rx_hi_ber_1),
        .stat_rx_valid_ctrl_code       (stat_rx_valid_ctrl_code_1),
        .stat_rx_bad_code              (stat_rx_bad_code_1),
        .stat_rx_bad_code_valid        (stat_rx_bad_code_valid_1),
        .stat_rx_error_valid           (stat_rx_error_valid_1),
        .stat_rx_error                 (stat_rx_error_1),
        .stat_rx_fifo_error            (stat_rx_fifo_error_1),
        .stat_rx_local_fault           (stat_rx_local_fault_1),
        // TX end = channel 0
        .tx_reset                      (tx_reset_0),
        .user_tx_reset                 (user_tx_reset_0),
        .tx_mii_d                      (tx_mii_d_0),
        .tx_mii_c                      (tx_mii_c_0),
        .ctl_tx_test_pattern           (ctl_tx_test_pattern_0),
        .ctl_tx_test_pattern_enable    (ctl_tx_test_pattern_enable_0),
        .ctl_tx_test_pattern_select    (ctl_tx_test_pattern_select_0),
        .ctl_tx_data_pattern_select    (ctl_tx_data_pattern_select_0),
        .ctl_tx_test_pattern_seed_a    (ctl_tx_test_pattern_seed_a_0),
        .ctl_tx_test_pattern_seed_b    (ctl_tx_test_pattern_seed_b_0),
        .ctl_tx_prbs31_test_pattern_enable (ctl_tx_prbs31_test_pattern_enable_0),
        .stat_tx_local_fault           (stat_tx_local_fault_0),
        .completion_status             (completion_status),
        .rx_gt_locked_led              (tgm_gt_locked_led),
        .rx_block_lock_led             (tgm_block_lock_led)
    );

    // The two core reset inputs the single traffic module does not drive must
    // still be DRIVEN -- a dangling one makes opt_design fail with [Opt 31-67].
    // The vendor ties this class of input to 0 inside its own modules, so 0 is
    // the faithful value.
    assign rx_reset_0 = 1'b0;
    assign tx_reset_1 = 1'b0;

    // ------------------------------------- independent XGMII content checkers
    wire [31:0] c0_words, c0_frames, c0_ctrl, c0_idle, c0_e, c0_pay, c0_badpay;
    wire [31:0] c0_badstart, c0_badhdr, c0_badterm, c0_badlen, c0_abort, c0_lastw;
    wire [63:0] c0_sword;
    wire [7:0]  c0_sc;
    wire [3:0]  c0_tlane;
    wire        c0_inframe;
    wire [31:0] c1_words, c1_frames, c1_ctrl, c1_idle, c1_e, c1_pay, c1_badpay;
    wire [31:0] c1_badstart, c1_badhdr, c1_badterm, c1_badlen, c1_abort, c1_lastw;
    wire [63:0] c1_sword;
    wire [7:0]  c1_sc;
    wire [3:0]  c1_tlane;
    wire        c1_inframe;

    wire [31:0] e_pre0, e_post0, e_pre1, e_post1;
    xgmii_rx_chk u_chk0 (
        .clk_rx      (rx_core_clk_0),
        .rst         (user_rx_reset_0),
        .pay_sel     (vio_pay_sel),
        .d           (rx_mii_d_0),
        .c           (rx_mii_c_0),
        .o_words     (c0_words),   .o_frames (c0_frames), .o_ctrl_words (c0_ctrl),
        .o_idle_words(c0_idle),    .o_e_words(c0_e),      .o_pay_words  (c0_pay),
        .o_bad_pay   (c0_badpay),  .o_bad_start(c0_badstart), .o_bad_hdr (c0_badhdr),
        .o_bad_term  (c0_badterm), .o_bad_len (c0_badlen), .o_abort    (c0_abort),
        .o_last_wpos (c0_lastw),   .o_s_word  (c0_sword),  .o_s_c       (c0_sc),
        .o_t_lane    (c0_tlane),   .o_in_frame(c0_inframe),
        .o_e_pre     (e_pre0),     .o_e_post   (e_post0)
    );
    xgmii_rx_chk u_chk1 (
        .clk_rx      (rx_core_clk_1),
        .rst         (user_rx_reset_1),
        .pay_sel     (vio_pay_sel),
        .d           (rx_mii_d_1),
        .c           (rx_mii_c_1),
        .o_words     (c1_words),   .o_frames (c1_frames), .o_ctrl_words (c1_ctrl),
        .o_idle_words(c1_idle),    .o_e_words(c1_e),      .o_pay_words  (c1_pay),
        .o_bad_pay   (c1_badpay),  .o_bad_start(c1_badstart), .o_bad_hdr (c1_badhdr),
        .o_bad_term  (c1_badterm), .o_bad_len (c1_badlen), .o_abort    (c1_abort),
        .o_last_wpos (c1_lastw),   .o_s_word  (c1_sword),  .o_s_c       (c1_sc),
        .o_t_lane    (c1_tlane),   .o_in_frame(c1_inframe),
        .o_e_pre     (e_pre1),     .o_e_post   (e_post1)
    );

    // --------------------------------------------- level sync into dclk
    wire gtpg0_s, blk0_s, rsts0_s, hber0_s, rlf0_s, ferr0_s, bcd0_s, evld0_s, ffe0_s, tlf0_s;
    wire gtpg1_s, blk1_s, rsts1_s, hber1_s, rlf1_s, ferr1_s, bcd1_s, evld1_s, ffe1_s, tlf1_s;
    wire los1_s, los2_s, urr0_s, utr0_s, urr1_s, utr1_s;

    cdc_sync2 s0_00 (.clk(dclk), .d(gtpowergood_out_0),     .q(gtpg0_s));
    cdc_sync2 s0_01 (.clk(dclk), .d(stat_rx_block_lock_0),  .q(blk0_s));
    cdc_sync2 s0_02 (.clk(dclk), .d(stat_rx_status_0),      .q(rsts0_s));
    cdc_sync2 s0_03 (.clk(dclk), .d(stat_rx_hi_ber_0),      .q(hber0_s));
    cdc_sync2 s0_04 (.clk(dclk), .d(stat_rx_local_fault_0), .q(rlf0_s));
    cdc_sync2 s0_05 (.clk(dclk), .d(stat_rx_framing_err_0), .q(ferr0_s));
    cdc_sync2 s0_06 (.clk(dclk), .d(stat_rx_bad_code_0),    .q(bcd0_s));
    cdc_sync2 s0_07 (.clk(dclk), .d(stat_rx_error_valid_0), .q(evld0_s));
    cdc_sync2 s0_08 (.clk(dclk), .d(stat_rx_fifo_error_0),  .q(ffe0_s));
    cdc_sync2 s0_09 (.clk(dclk), .d(stat_tx_local_fault_0), .q(tlf0_s));
    cdc_sync2 s0_10 (.clk(dclk), .d(gtpowergood_out_1),     .q(gtpg1_s));
    cdc_sync2 s0_11 (.clk(dclk), .d(stat_rx_block_lock_1),  .q(blk1_s));
    cdc_sync2 s0_12 (.clk(dclk), .d(stat_rx_status_1),      .q(rsts1_s));
    cdc_sync2 s0_13 (.clk(dclk), .d(stat_rx_hi_ber_1),      .q(hber1_s));
    cdc_sync2 s0_14 (.clk(dclk), .d(stat_rx_local_fault_1), .q(rlf1_s));
    cdc_sync2 s0_15 (.clk(dclk), .d(stat_rx_framing_err_1), .q(ferr1_s));
    cdc_sync2 s0_16 (.clk(dclk), .d(stat_rx_bad_code_1),    .q(bcd1_s));
    cdc_sync2 s0_17 (.clk(dclk), .d(stat_rx_error_valid_1), .q(evld1_s));
    cdc_sync2 s0_18 (.clk(dclk), .d(stat_rx_fifo_error_1),  .q(ffe1_s));
    cdc_sync2 s0_19 (.clk(dclk), .d(stat_tx_local_fault_1), .q(tlf1_s));
    cdc_sync2 s0_20 (.clk(dclk), .d(sfp1_rx_los),           .q(los1_s));
    cdc_sync2 s0_21 (.clk(dclk), .d(sfp2_rx_los),           .q(los2_s));
    cdc_sync2 s0_22 (.clk(dclk), .d(user_rx_reset_0),       .q(urr0_s));
    cdc_sync2 s0_23 (.clk(dclk), .d(user_tx_reset_0),       .q(utr0_s));
    cdc_sync2 s0_24 (.clk(dclk), .d(user_rx_reset_1),       .q(urr1_s));
    cdc_sync2 s0_25 (.clk(dclk), .d(user_tx_reset_1),       .q(utr1_s));

    // ---------------------------------------------- pulse counters (dclk)
    // stat_* are single-cycle pulses or levels.  Their clock domain is recorded
    // as UNVERIFIED in the P7b spec (presumed dclk).  They are therefore used
    // only as "has it EVER fired" evidence and never as a precise count; the
    // precise error evidence is (a) the vendor FSM's completion_status and
    // (b) the two in-domain xgmii_rx_chk instances.
    // The counters SATURATE at 255 (they do not wrap): a wrapped counter could
    // read exactly 0 after 256 events and turn a real error into a false clean.
    reg [7:0] p_vcc0, p_ferr0, p_bcd0, p_ffe0;
    reg [7:0] p_vcc1, p_ferr1, p_bcd1, p_ffe1;
    // sticky OR of every observed stat_rx_error[7:0] pattern plus a valid-strobe
    // count -- this is the stat_rx_error criterion face (per-lane errors).
    reg [7:0] acc_err0, acc_err1;
    reg [7:0] n_errv0, n_errv1;
    function [7:0] sat8;
        input [7:0] v;
        begin sat8 = (v == 8'hFF) ? v : v + 8'd1; end
    endfunction
    always @(posedge dclk) begin
        if (stat_rx_valid_ctrl_code_0)                 p_vcc0  <= sat8(p_vcc0);
        if (stat_rx_framing_err_valid_0 & ferr0_s)     p_ferr0 <= sat8(p_ferr0);
        if (stat_rx_bad_code_valid_0 & bcd0_s)         p_bcd0  <= sat8(p_bcd0);
        if (stat_rx_fifo_error_0)                      p_ffe0  <= sat8(p_ffe0);
        if (stat_rx_valid_ctrl_code_1)                 p_vcc1  <= sat8(p_vcc1);
        if (stat_rx_framing_err_valid_1 & ferr1_s)     p_ferr1 <= sat8(p_ferr1);
        if (stat_rx_bad_code_valid_1 & bcd1_s)         p_bcd1  <= sat8(p_bcd1);
        if (stat_rx_fifo_error_1)                      p_ffe1  <= sat8(p_ffe1);
        if (stat_rx_error_valid_0) begin
            acc_err0 <= acc_err0 | stat_rx_error_0;
            n_errv0  <= sat8(n_errv0);
        end
        if (stat_rx_error_valid_1) begin
            acc_err1 <= acc_err1 | stat_rx_error_1;
            n_errv1  <= sat8(n_errv1);
        end
    end

    // --------------------------------- stat_* CLOCK DOMAIN probe (spec U8)
    // The same four stat_* signals are counted TWICE: once in dclk (where the
    // next round's MAC will sample them) and once in the ch1 recovered clock.
    //   * a dclk-domain pulse (>=10 ns) is caught by BOTH  -> counts equal
    //   * an rx-domain pulse (6.4 ns) is caught by the rx counter and MISSED
    //     roughly a third of the time by the dclk counter -> rx > dclk
    //   * a LEVEL held for the same wall time gives counts in the ratio of the
    //     clock frequencies (dclk:rx ~ 0.64) -- a third, distinct signature
    // That is what turns U8 ("presumed dclk") into something measurable.
    reg [31:0] s_vcc_d, s_ferr_d, s_bcd_d, s_ffe_d;
    always @(posedge dclk) begin
        if (stat_rx_valid_ctrl_code_1)             s_vcc_d  <= s_vcc_d  + 32'd1;
        if (stat_rx_framing_err_valid_1 & ferr1_s) s_ferr_d <= s_ferr_d + 32'd1;
        if (stat_rx_bad_code_valid_1 & bcd1_s)     s_bcd_d  <= s_bcd_d  + 32'd1;
        if (stat_rx_fifo_error_1)                  s_ffe_d  <= s_ffe_d  + 32'd1;
    end
    reg [31:0] s_vcc_r, s_ferr_r, s_bcd_r, s_ffe_r, s_errv_r;
    always @(posedge rx_core_clk_1) begin
        if (user_rx_reset_1) begin
            s_vcc_r <= 32'd0; s_ferr_r <= 32'd0; s_bcd_r <= 32'd0;
            s_ffe_r <= 32'd0; s_errv_r <= 32'd0;
        end else begin
            if (stat_rx_valid_ctrl_code_1)                           s_vcc_r  <= s_vcc_r  + 32'd1;
            if (stat_rx_framing_err_valid_1 & stat_rx_framing_err_1) s_ferr_r <= s_ferr_r + 32'd1;
            if (stat_rx_bad_code_valid_1 & stat_rx_bad_code_1)       s_bcd_r  <= s_bcd_r  + 32'd1;
            if (stat_rx_fifo_error_1)                                s_ffe_r  <= s_ffe_r  + 32'd1;
            if (stat_rx_error_valid_1)                               s_errv_r <= s_errv_r + 32'd1;
        end
    end

    // ------------------------------------------------ free-running counters
    reg [31:0] dclk_free = 32'd0;
    always @(posedge dclk)         dclk_free <= dclk_free + 32'd1;
    reg [31:0] tx0_free = 32'd0;
    always @(posedge tx_mii_clk_0) tx0_free  <= tx0_free  + 32'd1;
    reg [31:0] rx0_free = 32'd0;
    always @(posedge rx_core_clk_0) rx0_free <= rx0_free  + 32'd1;
    reg [31:0] rx1_free = 32'd0;
    always @(posedge rx_core_clk_1) rx1_free <= rx1_free  + 32'd1;

    // ------------------------------------------------------- snapshot logic
    // One shared request toggle; each source domain latches its own group.
    reg  snap_req_tgl = 1'b0;
    reg  cmd_snap_d   = 1'b0;
    reg [15:0] snap_gen = 16'd0;
    always @(posedge dclk) begin
        cmd_snap_d <= vio_cmd_snap;
        if (vio_cmd_snap && !cmd_snap_d) begin
            snap_req_tgl <= ~snap_req_tgl;
            snap_gen     <= snap_gen + 16'd1;
        end
    end

    // group A: X0Y5 receive domain (the judged direction).  480 bits = 15 x 32:
    //   [31:0] words   [63:32] frames  [95:64] ctrl   [127:96] e
    //   [159:128] pay  [191:160] badpay [223:192] badstart [255:224] badhdr
    //   [287:256] badterm [319:288] badlen [351:320] abort [383:352] lastw
    //   [415:384] idle [447:416] {sc[7:0],tlane[3:0],4'b0,inframe,15'b0}
    //   [479:448] rx1_free
    wire [703:0] rx1_bus = {e_post1, e_pre1, s_errv_r, s_ffe_r, s_bcd_r, s_ferr_r,
                            s_vcc_r,
                            rx1_free, {c1_sc, c1_tlane, 4'b0, c1_inframe, 15'b0},
                            c1_idle, c1_lastw, c1_abort, c1_badlen, c1_badterm,
                            c1_badhdr, c1_badstart, c1_badpay, c1_pay, c1_e,
                            c1_ctrl, c1_frames, c1_words};
    wire [703:0] rx1_hold;
    wire         ack_rx1, gen_rx1;
    snap_hold #(.W(704)) u_snap_rx1 (
        .src_clk(rx_core_clk_1), .obs_clk(dclk),
        .obs_req(snap_req_tgl), .obs_ack(ack_rx1), .obs_gen(gen_rx1),
        .din(rx1_bus), .dout(rx1_hold));

    // group B: X0Y4 transmit domain (TX XGMII word rate)
    wire [31:0] tx0_hold;
    wire        ack_tx0, gen_tx0;
    snap_hold #(.W(32)) u_snap_tx0 (
        .src_clk(tx_mii_clk_0), .obs_clk(dclk),
        .obs_req(snap_req_tgl), .obs_ack(ack_tx0), .obs_gen(gen_tx0),
        .din(tx0_free), .dout(tx0_hold));

    // group C: X0Y4 receive domain (the idle-stream direction).
    //   [31:0] words [63:32] ctrl [95:64] idle [127:96] e
    //   [159:128] frames [191:160] abort [223:192] badterm [255:224] rx0_free
    wire [319:0] rx0_bus = {e_post0, e_pre0, rx0_free, c0_badterm, c0_abort,
                            c0_frames, c0_e, c0_idle, c0_ctrl, c0_words};
    wire [319:0] rx0_hold;
    wire         ack_rx0, gen_rx0;
    snap_hold #(.W(320)) u_snap_rx0 (
        .src_clk(rx_core_clk_0), .obs_clk(dclk),
        .obs_req(snap_req_tgl), .obs_ack(ack_rx0), .obs_gen(gen_rx0),
        .din(rx0_bus), .dout(rx0_hold));

    // group D: the observer domain itself.  dclk_free must be latched by the
    // SAME request as the three counter groups, otherwise the frequency ratios
    // carry the JTAG read-order skew (measured: reading dclk_free live, five
    // probes after the snapshot, shifted a 6.8 s ratio by a few percent).
    wire [31:0] dclk_hold;
    wire        ack_dclk, gen_dclk;
    snap_hold #(.W(32)) u_snap_dclk (
        .src_clk(dclk), .obs_clk(dclk),
        .obs_req(snap_req_tgl), .obs_ack(ack_dclk), .obs_gen(gen_dclk),
        .din(dclk_free), .dout(dclk_hold));

    // ------------------------------------------------- VIO (register window)
    wire [31:0] st0 = {12'b0, tgm_block_lock_led, tgm_gt_locked_led, completion_status,
                       utr0_s, urr0_s,
                       los1_s, tlf0_s, ffe0_s, evld0_s, bcd0_s, ferr0_s, rlf0_s,
                       hber0_s, rsts0_s, blk0_s, gtpg0_s};
    wire [31:0] st1 = {10'b0, c1_inframe, c0_inframe, 3'b0,
                       utr1_s, urr1_s,
                       los2_s, tlf1_s, ffe1_s, evld1_s, bcd1_s, ferr1_s, rlf1_s,
                       hber1_s, rsts1_s, blk1_s, gtpg1_s};
    wire [31:0] cnt0 = {p_vcc0, p_ferr0, p_bcd0, p_ffe0};
    wire [31:0] cnt1 = {p_vcc1, p_ferr1, p_bcd1, p_ffe1};
    wire [31:0] snap_gen_w = {snap_gen, 12'b0, ack_dclk, ack_tx0, ack_rx0, ack_rx1};
    wire [31:0] err_w     = {n_errv1, acc_err1, n_errv0, acc_err0};

    // one obs_reg per probe_in: the VIO's own sampling flops then only ever see
    // dclk-domain logic, and the cross-domain path has one constrainable name.
    wire [31:0] oi00, oi01, oi02, oi03, oi04, oi05, oi06, oi07, oi08, oi09;
    wire [31:0] oi10, oi11, oi12, oi13, oi14, oi15, oi16, oi17, oi18, oi19;
    wire [31:0] oi20, oi21, oi22, oi23, oi24, oi25, oi26, oi27, oi28, oi29;
    wire [31:0] oi30, oi31, oi32, oi33, oi34, oi35, oi36, oi37, oi38, oi39;
    wire [31:0] oi40, oi41, oi42, oi43, oi44, oi45, oi46, oi47;

    obs_reg #(.W(32)) r00 (.clk(dclk), .d(st0),                  .q(oi00));
    obs_reg #(.W(32)) r01 (.clk(dclk), .d(st1),                  .q(oi01));
    obs_reg #(.W(32)) r02 (.clk(dclk), .d(cnt0),                 .q(oi02));
    obs_reg #(.W(32)) r03 (.clk(dclk), .d(cnt1),                 .q(oi03));
    obs_reg #(.W(32)) r04 (.clk(dclk), .d(dclk_free),            .q(oi04));
    obs_reg #(.W(32)) r05 (.clk(dclk), .d(tx0_hold),             .q(oi05));
    obs_reg #(.W(32)) r06 (.clk(dclk), .d(rx0_hold[319:288]),    .q(oi06));
    obs_reg #(.W(32)) r07 (.clk(dclk), .d(rx1_hold[479:448]),    .q(oi07));
    obs_reg #(.W(32)) r08 (.clk(dclk), .d(rx0_hold[31:0]),       .q(oi08));
    obs_reg #(.W(32)) r09 (.clk(dclk), .d(rx0_hold[63:32]),      .q(oi09));
    obs_reg #(.W(32)) r10 (.clk(dclk), .d(rx0_hold[95:64]),      .q(oi10));
    obs_reg #(.W(32)) r11 (.clk(dclk), .d(rx0_hold[127:96]),     .q(oi11));
    obs_reg #(.W(32)) r12 (.clk(dclk), .d(rx0_hold[159:128]),    .q(oi12));
    obs_reg #(.W(32)) r13 (.clk(dclk), .d(rx1_hold[31:0]),       .q(oi13));
    obs_reg #(.W(32)) r14 (.clk(dclk), .d(rx1_hold[63:32]),      .q(oi14));
    obs_reg #(.W(32)) r15 (.clk(dclk), .d(rx1_hold[95:64]),      .q(oi15));
    obs_reg #(.W(32)) r16 (.clk(dclk), .d(rx1_hold[127:96]),     .q(oi16));
    obs_reg #(.W(32)) r17 (.clk(dclk), .d(rx1_hold[159:128]),    .q(oi17));
    obs_reg #(.W(32)) r18 (.clk(dclk), .d(rx1_hold[191:160]),    .q(oi18));
    obs_reg #(.W(32)) r19 (.clk(dclk), .d(rx1_hold[223:192]),    .q(oi19));
    obs_reg #(.W(32)) r20 (.clk(dclk), .d(rx1_hold[255:224]),    .q(oi20));
    obs_reg #(.W(32)) r21 (.clk(dclk), .d(rx1_hold[287:256]),    .q(oi21));
    obs_reg #(.W(32)) r22 (.clk(dclk), .d(rx1_hold[319:288]),    .q(oi22));
    obs_reg #(.W(32)) r23 (.clk(dclk), .d(rx1_hold[351:320]),    .q(oi23));
    obs_reg #(.W(32)) r24 (.clk(dclk), .d(rx1_hold[383:352]),    .q(oi24));
    obs_reg #(.W(32)) r25 (.clk(dclk), .d(rx1_hold[415:384]),    .q(oi25));
    obs_reg #(.W(32)) r26 (.clk(dclk), .d(rx1_hold[447:416]),    .q(oi26));
    obs_reg #(.W(32)) r27 (.clk(dclk), .d(snap_gen_w),           .q(oi27));
    obs_reg #(.W(32)) r28 (.clk(dclk), .d(c1_sword[31:0]),       .q(oi28));
    obs_reg #(.W(32)) r29 (.clk(dclk), .d(c1_sword[63:32]),      .q(oi29));
    obs_reg #(.W(32)) r30 (.clk(dclk), .d(c0_sword[31:0]),       .q(oi30));
    obs_reg #(.W(32)) r31 (.clk(dclk), .d({c1_inframe, c0_inframe, 30'b0}), .q(oi31));
    obs_reg #(.W(32)) r32 (.clk(dclk), .d(err_w),                .q(oi32));
    obs_reg #(.W(32)) r33 (.clk(dclk), .d(dclk_hold),            .q(oi33));
    obs_reg #(.W(32)) r34 (.clk(dclk), .d(err_w),                .q(oi34));
    obs_reg #(.W(32)) r35 (.clk(dclk), .d(dclk_hold),            .q(oi35));
    // stat_* domain probe: dclk-domain count and rx-domain count side by side
    obs_reg #(.W(32)) r36 (.clk(dclk), .d(s_vcc_d),              .q(oi36));
    obs_reg #(.W(32)) r37 (.clk(dclk), .d(rx1_hold[511:480]),    .q(oi37));
    obs_reg #(.W(32)) r38 (.clk(dclk), .d(s_ferr_d),             .q(oi38));
    obs_reg #(.W(32)) r39 (.clk(dclk), .d(rx1_hold[543:512]),    .q(oi39));
    obs_reg #(.W(32)) r40 (.clk(dclk), .d(s_bcd_d),              .q(oi40));
    obs_reg #(.W(32)) r41 (.clk(dclk), .d(rx1_hold[575:544]),    .q(oi41));
    obs_reg #(.W(32)) r42 (.clk(dclk), .d(s_ffe_d),              .q(oi42));
    obs_reg #(.W(32)) r43 (.clk(dclk), .d(rx1_hold[607:576]),    .q(oi43));
    obs_reg #(.W(32)) r44 (.clk(dclk), .d(rx1_hold[639:608]),    .q(oi44));
    obs_reg #(.W(32)) r45 (.clk(dclk), .d(rx1_hold[671:640]),    .q(oi45));
    obs_reg #(.W(32)) r46 (.clk(dclk), .d(rx1_hold[703:672]),    .q(oi46));
    obs_reg #(.W(32)) r47 (.clk(dclk), .d(rx0_hold[287:256]),    .q(oi47));

    vio_0 u_vio (
        .clk        (dclk),
        .probe_in0  (oi00),  .probe_in1 (oi01),  .probe_in2 (oi02),
        .probe_in3  (oi03),  .probe_in4 (oi04),  .probe_in5 (oi05),
        .probe_in6  (oi06),  .probe_in7 (oi07),  .probe_in8 (oi08),
        .probe_in9  (oi09),  .probe_in10(oi10),  .probe_in11(oi11),
        .probe_in12 (oi12),  .probe_in13(oi13),  .probe_in14(oi14),
        .probe_in15 (oi15),  .probe_in16(oi16),  .probe_in17(oi17),
        .probe_in18 (oi18),  .probe_in19(oi19),  .probe_in20(oi20),
        .probe_in21 (oi21),  .probe_in22(oi22),  .probe_in23(oi23),
        .probe_in24 (oi24),  .probe_in25(oi25),  .probe_in26(oi26),
        .probe_in27 (oi27),  .probe_in28(oi28),  .probe_in29(oi29),
        .probe_in30 (oi30),  .probe_in31(oi31),
        .probe_in32 (oi32),  .probe_in33(oi33),  .probe_in34(oi34),
        .probe_in35 (oi35),  .probe_in36(oi36),  .probe_in37(oi37),
        .probe_in38 (oi38),  .probe_in39(oi39),  .probe_in40(oi40),
        .probe_in41 (oi41),  .probe_in42(oi42),  .probe_in43(oi43),
        .probe_in44 (oi44),  .probe_in45(oi45),  .probe_in46(oi46),
        .probe_in47 (oi47),
        .probe_out0 (vio_send_cont),
        .probe_out1 (vio_cmd_restart),
        .probe_out2 (vio_cmd_sysreset),
        .probe_out3 (vio_cmd_sfp1_tx_dis),
        .probe_out4 (vio_cmd_sfp2_tx_dis),
        .probe_out5 (vio_cmd_snap),
        .probe_out6 (vio_gt_loopback),
        .probe_out7 (vio_pay_sel)
    );

    // ------------------------------------------------------------------ LEDs
    assign led[0] = blk1_s;                        // X0Y5 (receiver) block lock
    assign led[1] = blk0_s;                        // X0Y4 (idle) block lock
    assign led[2] = (completion_status == 5'd1);   // official verdict PASS
    assign led[3] = c1_e[0] | ferr0_s | ferr1_s;   // any error indication

endmodule
