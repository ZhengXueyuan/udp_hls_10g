// ============================================================================
// probe_macpcs64_top.v -- P7b probe: thin board wrapper around the OFFICIAL
//   xxv_ethernet 5.0 core, CORE = "Ethernet MAC+PCS/PMA 64-bit", 10G BASE-R,
//   GTY, 156.25 MHz reference, GTY X0Y4 (= SFP A on the XCKU5P Mini).
//
// Core wiring follows the vendor example design (macpcs64_exdes.v):
//     rx_core_clk_0 = rx_clk_out_0
//     txoutclksel_in_0 = rxoutclksel_in_0 = 3'b101
//     gtwiz_reset_{tx,rx}_datapath_0 = 0 ; qpllreset_in_0 = 0
//     ctl_rx_wdt_disable_0 = 0 ; gt_loopback_in_0 = 0
//
// ctl_* steady-state values are the vendor packet generator's own defaults
//   (macpcs64_pkt_gen_mon.v:1380-1395 / 2497-2510):
//     ctl_tx_enable=1 ctl_tx_fcs_ins_enable=1 ctl_tx_ignore_fcs=0
//     ctl_tx_send_{rfi,lfi,idle}=0 ctl_tx_custom_preamble_enable=0
//     ctl_tx_ipg_value=4'd12
//     ctl_rx_enable=1 ctl_rx_check_preamble=1 ctl_rx_check_sfd=1
//     ctl_rx_delete_fcs=1 ctl_rx_ignore_fcs=0 ctl_rx_process_lfi=0
//     ctl_rx_max_packet_len=9600 ctl_rx_custom_preamble_enable=0
//
// This design exists to answer "does the licence let it build" -- it is NOT
// for programming the board.
// ============================================================================
`timescale 1ns/1ps

module probe_macpcs64_top (
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

    assign sfp1_tx_dis = 1'b0;

    // ------------------------------------------------------------- core nets
    wire        rx_core_clk, rx_clk_out, tx_clk_out, rxrecclkout;
    wire        rx_reset, user_rx_reset, tx_reset, user_tx_reset;
    wire        gtpowergood, gt_refclk_out;
    wire [63:0] rx_axis_tdata, tx_axis_tdata;
    wire [7:0]  rx_axis_tkeep, tx_axis_tkeep;
    wire        rx_axis_tvalid, rx_axis_tlast, rx_axis_tuser, tx_axis_tready;
    wire [55:0] rx_preambleout;
    wire        stat_rx_block_lock, stat_rx_status, stat_rx_hi_ber;
    wire        stat_rx_local_fault, stat_rx_framing_err, stat_rx_framing_err_valid;
    wire        stat_rx_bad_fcs_0, stat_rx_bad_fcs_1;
    wire [1:0]  stat_rx_bad_fcs;
    wire        stat_rx_got_signal_os, stat_rx_truncated;
    wire        stat_tx_local_fault, stat_tx_frame_error, tx_unfout;

    assign rx_core_clk = rx_clk_out;   // vendor example wiring

    macpcs64 DUT (
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
        .tx_clk_out_0                     (tx_clk_out),
        .rx_clk_out_0                     (rx_clk_out),
        .gt_refclk_p                      (gt_refclk_p),
        .gt_refclk_n                      (gt_refclk_n),
        .gt_refclk_out                    (gt_refclk_out),
        .gtpowergood_out_0                (gtpowergood),
        .rx_reset_0                       (rx_reset),
        .user_rx_reset_0                  (user_rx_reset),
        .tx_reset_0                       (tx_reset),
        .user_tx_reset_0                  (user_tx_reset),

        // -------- RX AXIS (MAC -> user) --------
        .rx_axis_tvalid_0                 (rx_axis_tvalid),
        .rx_axis_tdata_0                  (rx_axis_tdata),
        .rx_axis_tlast_0                  (rx_axis_tlast),
        .rx_axis_tkeep_0                  (rx_axis_tkeep),
        .rx_axis_tuser_0                  (rx_axis_tuser),
        .rx_preambleout_0                 (rx_preambleout),

        // -------- TX AXIS (user -> MAC) --------
        .tx_axis_tready_0                 (tx_axis_tready),
        .tx_axis_tvalid_0                 (tx_axis_tvalid),
        .tx_axis_tdata_0                  (tx_axis_tdata),
        .tx_axis_tlast_0                  (tx_axis_tlast),
        .tx_axis_tkeep_0                  (tx_axis_tkeep),
        .tx_axis_tuser_0                  (tx_axis_tuser),
        .tx_unfout_0                      (tx_unfout),
        .tx_preamblein_0                  (56'd0),

        // -------- RX control --------
        .ctl_rx_enable_0                  (1'b1),
        .ctl_rx_check_preamble_0          (1'b1),
        .ctl_rx_check_sfd_0               (1'b1),
        .ctl_rx_force_resync_0            (1'b0),
        .ctl_rx_delete_fcs_0              (1'b1),
        .ctl_rx_ignore_fcs_0              (1'b0),
        .ctl_rx_max_packet_len_0          (15'd9600),
        .ctl_rx_min_packet_len_0          (8'd64),
        .ctl_rx_process_lfi_0             (1'b0),
        .ctl_rx_test_pattern_0            (1'b0),
        .ctl_rx_data_pattern_select_0     (1'b0),
        .ctl_rx_test_pattern_enable_0     (1'b0),
        .ctl_rx_custom_preamble_enable_0  (1'b0),
        .ctl_rx_wdt_disable_0             (1'b0),

        // -------- TX control --------
        .ctl_tx_enable_0                  (1'b1),
        .ctl_tx_send_rfi_0                (1'b0),
        .ctl_tx_send_lfi_0                (1'b0),
        .ctl_tx_send_idle_0               (1'b0),
        .ctl_tx_fcs_ins_enable_0          (1'b1),
        .ctl_tx_ignore_fcs_0              (1'b0),
        .ctl_tx_ipg_value_0               (4'd12),
        .ctl_tx_custom_preamble_enable_0  (1'b0),
        .ctl_tx_test_pattern_0            (1'b0),
        .ctl_tx_test_pattern_enable_0     (1'b0),
        .ctl_tx_test_pattern_select_0     (1'b0),
        .ctl_tx_data_pattern_select_0     (1'b0),
        .ctl_tx_test_pattern_seed_a_0     (58'd0),
        .ctl_tx_test_pattern_seed_b_0     (58'd0),

        // -------- RX status --------
        .stat_rx_framing_err_0            (stat_rx_framing_err),
        .stat_rx_framing_err_valid_0      (stat_rx_framing_err_valid),
        .stat_rx_local_fault_0            (stat_rx_local_fault),
        .stat_rx_block_lock_0             (stat_rx_block_lock),
        .stat_rx_valid_ctrl_code_0        (),
        .stat_rx_status_0                 (stat_rx_status),
        .stat_rx_remote_fault_0           (),
        .stat_rx_bad_fcs_0                (stat_rx_bad_fcs),
        .stat_rx_stomped_fcs_0            (),
        .stat_rx_truncated_0              (stat_rx_truncated),
        .stat_rx_internal_local_fault_0   (),
        .stat_rx_received_local_fault_0   (),
        .stat_rx_hi_ber_0                 (stat_rx_hi_ber),
        .stat_rx_got_signal_os_0          (stat_rx_got_signal_os),
        .stat_rx_test_pattern_mismatch_0  (),
        .stat_rx_total_bytes_0            (),
        .stat_rx_total_packets_0          (),
        .stat_rx_total_good_bytes_0       (),
        .stat_rx_total_good_packets_0     (),
        .stat_rx_packet_bad_fcs_0         (),
        .stat_rx_packet_64_bytes_0        (),
        .stat_rx_packet_65_127_bytes_0    (),
        .stat_rx_packet_128_255_bytes_0   (),
        .stat_rx_packet_256_511_bytes_0   (),
        .stat_rx_packet_512_1023_bytes_0  (),
        .stat_rx_packet_1024_1518_bytes_0 (),
        .stat_rx_packet_1519_1522_bytes_0 (),
        .stat_rx_packet_1523_1548_bytes_0 (),
        .stat_rx_packet_1549_2047_bytes_0 (),
        .stat_rx_packet_2048_4095_bytes_0 (),
        .stat_rx_packet_4096_8191_bytes_0 (),
        .stat_rx_packet_8192_9215_bytes_0 (),
        .stat_rx_packet_small_0           (),
        .stat_rx_packet_large_0           (),
        .stat_rx_unicast_0                (),
        .stat_rx_multicast_0              (),
        .stat_rx_broadcast_0              (),
        .stat_rx_oversize_0               (),
        .stat_rx_toolong_0                (),
        .stat_rx_undersize_0              (),
        .stat_rx_fragment_0               (),
        .stat_rx_vlan_0                   (),
        .stat_rx_inrangeerr_0             (),
        .stat_rx_jabber_0                 (),
        .stat_rx_bad_code_0               (),
        .stat_rx_bad_sfd_0                (),
        .stat_rx_bad_preamble_0           (),

        // -------- TX status --------
        .stat_tx_local_fault_0            (stat_tx_local_fault),
        .stat_tx_total_bytes_0            (),
        .stat_tx_total_packets_0          (),
        .stat_tx_total_good_bytes_0       (),
        .stat_tx_total_good_packets_0     (),
        .stat_tx_bad_fcs_0                (),
        .stat_tx_packet_64_bytes_0        (),
        .stat_tx_packet_65_127_bytes_0    (),
        .stat_tx_packet_128_255_bytes_0   (),
        .stat_tx_packet_256_511_bytes_0   (),
        .stat_tx_packet_512_1023_bytes_0  (),
        .stat_tx_packet_1024_1518_bytes_0 (),
        .stat_tx_packet_1519_1522_bytes_0 (),
        .stat_tx_packet_1523_1548_bytes_0 (),
        .stat_tx_packet_1549_2047_bytes_0 (),
        .stat_tx_packet_2048_4095_bytes_0 (),
        .stat_tx_packet_4096_8191_bytes_0 (),
        .stat_tx_packet_8192_9215_bytes_0 (),
        .stat_tx_packet_small_0           (),
        .stat_tx_packet_large_0           (),
        .stat_tx_unicast_0                (),
        .stat_tx_multicast_0              (),
        .stat_tx_broadcast_0              (),
        .stat_tx_vlan_0                   (),
        .stat_tx_frame_error_0            (stat_tx_frame_error),

        .gt_loopback_in_0                 (3'b000),
        .qpllreset_in_0                   (1'b0)
    );

    // ======================================================================
    // Minimal AXIS frame source: one 64-byte frame every 1024 tx_clk_out
    // cycles.  tkeep all-ones (64-byte frame = 8 full words), tlast on the
    // 8th, tuser = 0 (good frame).
    // ======================================================================
    reg [15:0] gap;
    reg [3:0]  wcnt;
    reg [63:0] pay;
    reg        tvalid_r;
    reg [63:0] tdata_r;

    always @(posedge tx_clk_out) begin
        if (gap == 16'd0) begin
            gap      <= 16'd1024;
            wcnt     <= 4'd0;
            tvalid_r <= 1'b1;
            pay      <= pay + 64'h0101010101010101;
        end else begin
            gap <= gap - 16'd1;
        end

        if (tvalid_r && tx_axis_tready) begin
            tdata_r <= pay;
            if (wcnt == 4'd7) tvalid_r <= 1'b0;
            else              wcnt <= wcnt + 4'd1;
        end
    end

    assign tx_axis_tdata  = tdata_r;
    assign tx_axis_tkeep  = 8'hFF;
    assign tx_axis_tvalid = tvalid_r;
    assign tx_axis_tlast  = tvalid_r && (wcnt == 4'd7);
    assign tx_axis_tuser  = 1'b0;

    // ======================================================================
    // RX sink + counters
    // ======================================================================
    reg [31:0] rx_bytes;
    reg [15:0] rx_frames;
    reg [15:0] rx_errs;

    always @(posedge rx_core_clk) begin
        if (rx_axis_tvalid) begin
            rx_bytes <= rx_bytes + {24'd0, rx_axis_tkeep[0]} + {24'd0, rx_axis_tkeep[1]}
                      + {24'd0, rx_axis_tkeep[2]} + {24'd0, rx_axis_tkeep[3]}
                      + {24'd0, rx_axis_tkeep[4]} + {24'd0, rx_axis_tkeep[5]}
                      + {24'd0, rx_axis_tkeep[6]} + {24'd0, rx_axis_tkeep[7]};
            if (rx_axis_tlast) begin
                rx_frames <= rx_frames + 16'd1;
                if (rx_axis_tuser) rx_errs <= rx_errs + 16'd1;
            end
        end
    end

    assign led[0] = stat_rx_block_lock;
    assign led[1] = stat_rx_status;
    assign led[2] = rx_axis_tuser | stat_rx_bad_fcs[0];

    // ======================================================================
    // MEASURED GOTCHA: leaving the core's rx_reset_0 / tx_reset_0 outputs
    // unconsumed makes opt_design fail with
    //   WARNING: [Opt 31-155] Driverless net
    //       DUT/inst/i_..._core_cdc_sync_gt_rx_resetdone_0/rx_reset_0 is
    //       driving LUT input pin I0 ...
    //   ERROR:   [Opt 31-67] ... missing a connection on input pin I0 ...
    // (the core's internal reset-done CDC LUT reads the net back).  Consuming
    // them through a shift register fixes it.
    // ======================================================================
    wire obs = rx_reset | tx_reset | user_rx_reset | user_tx_reset
             | gtpowergood | tx_unfout
             | (^rx_preambleout) | rx_frames[0];
    reg [3:0] obs_sr;
    always @(posedge dclk) obs_sr <= {obs_sr[2:0], obs};

    assign led[3] = obs_sr[3];

endmodule
