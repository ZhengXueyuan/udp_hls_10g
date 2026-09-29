//======================================================================
// p7a_top.v -- P7a: 10GBASE-R (64b/66b gearbox) on the XCKU5P Mini
//======================================================================
//
//  What this is
//  ------------
//  Two GTY channels of quad 225 running 10GBASE-R (64B66B_ASYNC encoding,
//  64-bit internal + user data width, buffer enabled) at 10.3125 GBd, with
//  SFP A (X0Y4) and SFP B (X0Y5) wired to each other through the AOC cable
//  (external loopback). PRBS31 is generated on TX and checked on RX; the error
//  and bit counts that decide the P7a verdict are made in p7a_counters.v, NOT
//  by the wizard example's leaky bucket.
//
//  Clocking
//  --------
//   sys_clk_p/n (T25/U25)  = core-board Y1, 100 MHz differential oscillator
//        -> clk_gen_p6b (MMCM, 1250 MHz VCO / 8) -> clk_obs = 156.25 MHz
//   clk_obs drives: gtwiz_reset_clk_freerun_in, the VIO core, the free-running
//        reference counter (fr_cyc) and the reference leaky bucket.
//   The GT reference clock (Y2, 156.25 MHz) reaches the quad through
//   IBUFDS_GTE4 on MGTREFCLK0_225 = V7/V6.
//   The GT's own gtwiz_userclk_tx_usrclk2_out / _rx_usrclk2_out (156.25 MHz)
//   clock the PRBS generator and checker respectively.
//
//   Why the reference must be clk_obs and not a GT clock: the whole point of
//   fr_cyc is to measure the RATIO between the RX word rate and a clock that
//   does not depend on the transceiver configuration (spec 4.2 / 5.4). clk_obs
//   comes from the core-board crystal through the MMCM, so a ratio of 1.0 is
//   only possible if 64 payload bits are carried per 66 baud -- i.e. if the
//   gearbox is in the datapath.
//
//  Reset
//  -----
//   The IP's reset controller is LOCATE_RESET_CONTROLLER=CORE, so it lives
//   inside gt_10gbr. It starts its bring-up sequence by itself after
//   configuration (that is why the example works with reset_all tied low) and
//   is re-runnable from the VIO. reset_all is synchronised inside the IP.
//
//  SFP control -- read this before touching the XDC
//  ------------------------------------------------
//   TX_DIS is ACTIVE HIGH and pin-mapped by MEASUREMENT, not by the vendor
//   XDCs: SFP1_TX_DIS = C11, SFP2_TX_DIS = D9 (the vendor files swap each pair).
//   Both are driven LOW here on purpose. If they are ever left floating they are
//   pulled high by a 10k resistor and BOTH modules stop emitting -- a total
//   dark link that looks exactly like "this board cannot do 10G".
//   RX_LOS (B11 / C9) is only observed, in the status word.
//======================================================================

`timescale 1ns / 1ps

module p7a_top (
    // ---- fabrication clock: core board Y1, SYS_CLK_P/N = T25/U25 (100 MHz) --
    input  wire sys_clk_p,
    input  wire sys_clk_n,

    // ---- GT reference clock: Y2 156.25 MHz -> MGTREFCLK0_225 = V7/V6 -------
    input  wire mgtrefclk0_x0y1_p,
    input  wire mgtrefclk0_x0y1_n,

    // ---- SFP A = quad 225 ch0 = X0Y4 --------------------------------------
    input  wire ch0_gtyrxn_in,
    input  wire ch0_gtyrxp_in,
    output wire ch0_gtytxn_out,
    output wire ch0_gtytxp_out,

    // ---- SFP B = quad 225 ch1 = X0Y5 --------------------------------------
    input  wire ch1_gtyrxn_in,
    input  wire ch1_gtyrxp_in,
    output wire ch1_gtytxn_out,
    output wire ch1_gtytxp_out,

    // ---- SFP control (see header) -----------------------------------------
    output wire sfp1_tx_dis,
    output wire sfp2_tx_dis,
    input  wire sfp1_rx_los,
    input  wire sfp2_rx_los
);

    //==================================================================
    // 1. fabric clocks and the observation-domain reset
    //==================================================================
    wire clk_obs;          // 156.25 MHz (MMCM from the 100 MHz crystal)
    wire clk_100_unused;   // 100 MHz buffered crystal, intentionally unused
    wire mmcm_locked;
    wire rst_obs;

    clk_gen_p6b u_clk_gen_p6b (
        .clk_p      (sys_clk_p),
        .clk_n      (sys_clk_n),
        .rst_ext    (1'b0),
        .clk_dp     (clk_obs),
        .clk_in_100 (clk_100_unused),
        .locked     (mmcm_locked),
        .rst_dp     (rst_obs)
    );

    //==================================================================
    // 2. GT reference clock buffer (MGTREFCLK0_225)
    //==================================================================
    wire gtrefclk00_int;

    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_ibufds_gte4_refclk (
        .I     (mgtrefclk0_x0y1_p),
        .IB    (mgtrefclk0_x0y1_n),
        .CEB   (1'b0),
        .O     (gtrefclk00_int),
        .ODIV2 ()
    );

    //==================================================================
    // 3. GT wizard core: 2 channels, 10GBASE-R
    //==================================================================
    wire [0:0]   gtwiz_userclk_tx_reset_int;
    wire [0:0]   gtwiz_userclk_tx_usrclk2_int;
    wire [0:0]   gtwiz_userclk_tx_active_int;
    wire [0:0]   gtwiz_userclk_rx_reset_int;
    wire [0:0]   gtwiz_userclk_rx_usrclk2_int;
    wire [0:0]   gtwiz_userclk_rx_active_int;
    wire [0:0]   gtwiz_reset_all_int;
    wire [0:0]   gtwiz_reset_rx_cdr_stable_int;
    wire [0:0]   gtwiz_reset_tx_done_int;
    wire [0:0]   gtwiz_reset_rx_done_int;
    wire [127:0] gtwiz_userdata_tx_int;
    wire [127:0] gtwiz_userdata_rx_int;
    wire [1:0]   gtyrxn_int;
    wire [1:0]   gtyrxp_int;
    wire [1:0]   gtytxn_int;
    wire [1:0]   gtytxp_int;
    wire [1:0]   rxgearboxslip_int;
    wire [11:0]  txheader_int;
    wire [13:0]  txsequence_int;
    wire [1:0]   gtpowergood_int;
    wire [3:0]   rxdatavalid_int;
    wire [11:0]  rxheader_int;
    wire [3:0]   rxheadervalid_int;
    wire [1:0]   rxpmaresetdone_int;
    wire [1:0]   rxprgdivresetdone_int;
    wire [3:0]   rxstartofseq_int;
    wire [1:0]   txpmaresetdone_int;
    wire [1:0]   txprgdivresetdone_int;

    wire clk_tx = gtwiz_userclk_tx_usrclk2_int[0];   // 156.25 MHz TX payload
    wire clk_rx = gtwiz_userclk_rx_usrclk2_int[0];   // 156.25 MHz RX payload
    wire tx_active = gtwiz_userclk_tx_active_int[0];
    wire rx_active = gtwiz_userclk_rx_active_int[0];

    assign gtyrxn_int[0] = ch0_gtyrxn_in;
    assign gtyrxn_int[1] = ch1_gtyrxn_in;
    assign gtyrxp_int[0] = ch0_gtyrxp_in;
    assign gtyrxp_int[1] = ch1_gtyrxp_in;
    assign ch0_gtytxn_out = gtytxn_int[0];
    assign ch0_gtytxp_out = gtytxp_int[0];
    assign ch1_gtytxn_out = gtytxn_int[1];
    assign ch1_gtytxp_out = gtytxp_int[1];

    // TX/RX user clocking resets: held until the clock source is known stable
    // (same conditions the example design uses).
    assign gtwiz_userclk_tx_reset_int[0] = ~(&txprgdivresetdone_int & &txpmaresetdone_int);
    assign gtwiz_userclk_rx_reset_int[0] = ~(&rxprgdivresetdone_int & &rxpmaresetdone_int);

    gt_10gbr u_gt (
        .gtwiz_userclk_tx_reset_in         (gtwiz_userclk_tx_reset_int),
        .gtwiz_userclk_tx_srcclk_out       (),
        .gtwiz_userclk_tx_usrclk_out       (),
        .gtwiz_userclk_tx_usrclk2_out      (gtwiz_userclk_tx_usrclk2_int),
        .gtwiz_userclk_tx_active_out       (gtwiz_userclk_tx_active_int),
        .gtwiz_userclk_rx_reset_in         (gtwiz_userclk_rx_reset_int),
        .gtwiz_userclk_rx_srcclk_out       (),
        .gtwiz_userclk_rx_usrclk_out       (),
        .gtwiz_userclk_rx_usrclk2_out      (gtwiz_userclk_rx_usrclk2_int),
        .gtwiz_userclk_rx_active_out       (gtwiz_userclk_rx_active_int),
        .gtwiz_reset_clk_freerun_in        (clk_obs),
        .gtwiz_reset_all_in                (gtwiz_reset_all_int),
        .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_tx_datapath_in        (1'b0),
        .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_rx_datapath_in        (1'b0),
        .gtwiz_reset_rx_cdr_stable_out     (gtwiz_reset_rx_cdr_stable_int),
        .gtwiz_reset_tx_done_out           (gtwiz_reset_tx_done_int),
        .gtwiz_reset_rx_done_out           (gtwiz_reset_rx_done_int),
        .gtwiz_userdata_tx_in              (gtwiz_userdata_tx_int),
        .gtwiz_userdata_rx_out             (gtwiz_userdata_rx_int),
        .gtrefclk00_in                     (gtrefclk00_int),
        .qpll0outclk_out                   (),
        .qpll0outrefclk_out                (),
        .gtyrxn_in                         (gtyrxn_int),
        .gtyrxp_in                         (gtyrxp_int),
        .gtytxn_out                        (gtytxn_int),
        .gtytxp_out                        (gtytxp_int),
        .rxgearboxslip_in                  (rxgearboxslip_int),
        .txheader_in                       (txheader_int),
        .txsequence_in                     (txsequence_int),
        .gtpowergood_out                   (gtpowergood_int),
        .rxdatavalid_out                   (rxdatavalid_int),
        .rxheader_out                      (rxheader_int),
        .rxheadervalid_out                 (rxheadervalid_int),
        .rxpmaresetdone_out                (rxpmaresetdone_int),
        .rxprgdivresetdone_out             (rxprgdivresetdone_int),
        .rxstartofseq_out                  (rxstartofseq_int),
        .txpmaresetdone_out                (txpmaresetdone_int),
        .txprgdivresetdone_out             (txprgdivresetdone_int)
    );

    //==================================================================
    // 4. per-channel fabric-side slices
    //==================================================================
    wire [63:0] ch0_txdata = gtwiz_userdata_tx_int[63:0];
    wire [63:0] ch1_txdata = gtwiz_userdata_tx_int[127:64];
    wire [63:0] ch0_rxdata = gtwiz_userdata_rx_int[63:0];
    wire [63:0] ch1_rxdata = gtwiz_userdata_rx_int[127:64];
    wire [5:0]  ch0_txheader;
    wire [5:0]  ch1_txheader;
    wire [6:0]  ch0_txsequence;
    wire [6:0]  ch1_txsequence;
    wire [5:0]  ch0_rxheader = rxheader_int[5:0];
    wire [5:0]  ch1_rxheader = rxheader_int[11:6];
    wire [1:0]  ch0_rxhdrval = rxheadervalid_int[1:0];
    wire [1:0]  ch1_rxhdrval = rxheadervalid_int[3:2];
    wire [1:0]  ch0_rxdv     = rxdatavalid_int[1:0];
    wire [1:0]  ch1_rxdv     = rxdatavalid_int[3:2];

    wire ch0_slip_checker;
    wire ch1_slip_checker;
    wire ch0_prbs_match;
    wire ch1_prbs_match;

    // ---- PRBS31 stimulus (copies of the wizard example modules) ------------
    gt_10gbr_example_stimulus_64b66b_async u_stim0 (
        .gtwiz_reset_all_in          (gtwiz_reset_all_int[0]),
        .gtwiz_userclk_tx_usrclk2_in (clk_tx),
        .gtwiz_userclk_tx_active_in  (tx_active),
        .txheader_out                (ch0_txheader),
        .txsequence_out              (ch0_txsequence),
        .txdata_out                  (ch0_txdata)
    );

    gt_10gbr_example_stimulus_64b66b_async u_stim1 (
        .gtwiz_reset_all_in          (gtwiz_reset_all_int[0]),
        .gtwiz_userclk_tx_usrclk2_in (clk_tx),
        .gtwiz_userclk_tx_active_in  (tx_active),
        .txheader_out                (ch1_txheader),
        .txsequence_out              (ch1_txsequence),
        .txdata_out                  (ch1_txdata)
    );

    assign txheader_int[5:0]   = ch0_txheader;
    assign txheader_int[11:6]  = ch1_txheader;
    assign txsequence_int[6:0] = ch0_txsequence;
    assign txsequence_int[13:7]= ch1_txsequence;

    // ---- PRBS31 checkers ---------------------------------------------------
    // The checker resets when the RX user clock is not active and, as the
    // example does, when the RX reset has not completed.
    gt_10gbr_example_checking_64b66b_async u_chk0 (
        .gtwiz_reset_all_in          (gtwiz_reset_all_int[0] | ~gtwiz_reset_rx_done_int[0]),
        .gtwiz_userclk_rx_usrclk2_in (clk_rx),
        .gtwiz_userclk_rx_active_in  (rx_active),
        .rxdatavalid_in              (ch0_rxdv),
        .rxgearboxslip_out           (ch0_slip_checker),
        .rxdata_in                   (ch0_rxdata),
        .prbs_match_out              (ch0_prbs_match)
    );

    gt_10gbr_example_checking_64b66b_async u_chk1 (
        .gtwiz_reset_all_in          (gtwiz_reset_all_int[0] | ~gtwiz_reset_rx_done_int[0]),
        .gtwiz_userclk_rx_usrclk2_in (clk_rx),
        .gtwiz_userclk_rx_active_in  (rx_active),
        .rxdatavalid_in              (ch1_rxdv),
        .rxgearboxslip_out           (ch1_slip_checker),
        .rxdata_in                   (ch1_rxdata),
        .prbs_match_out              (ch1_prbs_match)
    );

    //==================================================================
    // 5. VIO control (observation domain) and its payload-domain hand-off
    //==================================================================
    wire raw_snap, raw_clear, raw_slip, raw_gt_reset;
    wire snap_tgl, clear_tgl, slip_tgl;
    wire gt_reset_level;
    wire snap_pls, clear_pls, slip_pls;
    wire raw_snap_r, raw_clear_r, raw_slip_r, raw_gt_reset_r;

    p7a_vio_ctrl u_vio_ctrl (
        .clk           (clk_obs),
        .rst           (rst_obs),
        .raw_snap      (raw_snap),
        .raw_clear     (raw_clear),
        .raw_slip      (raw_slip),
        .raw_gt_reset  (raw_gt_reset),
        .snap_tgl      (snap_tgl),
        .clear_tgl     (clear_tgl),
        .slip_tgl      (slip_tgl),
        .gt_reset_level(gt_reset_level),
        .snap_pls      (snap_pls),
        .clear_pls     (clear_pls),
        .slip_pls      (slip_pls),
        .raw_snap_r    (raw_snap_r),
        .raw_clear_r   (raw_clear_r),
        .raw_slip_r    (raw_slip_r),
        .raw_gt_reset_r(raw_gt_reset_r)
    );

    assign gtwiz_reset_all_int[0] = gt_reset_level;

    // forced gearbox slip (negative control A): a toggle from the observation
    // domain, turned into a ONE-cycle pulse in the RX payload domain.
    wire slip_force_pulse;
    p7a_tgl_sync u_slip_sync (
        .clk  (clk_rx),
        .rst  (~rx_active),
        .tgl_in (slip_tgl),
        .pulse_out (slip_force_pulse)
    );

    // The checker's own hunt and the forced slip are ORed: either can move the
    // gearbox alignment. Both are one-cycle pulses in this domain.
    assign rxgearboxslip_int[0] = ch0_slip_checker | slip_force_pulse;
    assign rxgearboxslip_int[1] = ch1_slip_checker | slip_force_pulse;

    //==================================================================
    // 6. counters + atomic snapshot
    //==================================================================
    wire [31:0] err_snap0, err_snap1;
    wire [47:0] bits_snap0, bits_snap1;
    wire [47:0] hdrs_snap0, hdrs_snap1;
    wire [31:0] hdre_snap0, hdre_snap1;
    wire [47:0] rxcyc_snap0, rxcyc_snap1;
    wire [47:0] rxdvcyc_snap0, rxdvcyc_snap1;
    wire        acq0, acq1;
    wire [5:0]  hdr_ref0, hdr_ref1;
    wire        hdr_ref_valid0, hdr_ref_valid1;
    wire [1:0]  rxdv0_live, rxdv1_live;
    wire        snap_ack_obs;
    wire [47:0] fr_cyc_snap;

    p7a_counters u_counters (
        .clk            (clk_rx),
        .rst            (~rx_active),
        .ch0_match      (ch0_prbs_match),
        .ch1_match      (ch1_prbs_match),
        .ch0_rxdv       (ch0_rxdv),
        .ch1_rxdv       (ch1_rxdv),
        .ch0_hdr        (ch0_rxheader),
        .ch1_hdr        (ch1_rxheader),
        .ch0_hdrval     (ch0_rxhdrval[0]),
        .ch1_hdrval     (ch1_rxhdrval[0]),
        .clk_obs        (clk_obs),
        .rst_obs        (rst_obs),
        .snap_req_tgl   (snap_tgl),
        .cnt_clear_tgl  (clear_tgl),
        .snap_ack_obs   (snap_ack_obs),
        .fr_cyc_snap    (fr_cyc_snap),
        .err_snap0      (err_snap0),      .err_snap1      (err_snap1),
        .bits_snap0     (bits_snap0),     .bits_snap1     (bits_snap1),
        .hdrs_snap0     (hdrs_snap0),     .hdrs_snap1     (hdrs_snap1),
        .hdre_snap0     (hdre_snap0),     .hdre_snap1     (hdre_snap1),
        .rxcyc_snap0    (rxcyc_snap0),    .rxcyc_snap1    (rxcyc_snap1),
        .rxdvcyc_snap0  (rxdvcyc_snap0),  .rxdvcyc_snap1  (rxdvcyc_snap1),
        .acq0           (acq0),           .acq1           (acq1),
        .hdr_ref0       (hdr_ref0),       .hdr_ref1       (hdr_ref1),
        .hdr_ref_valid0 (hdr_ref_valid0), .hdr_ref_valid1 (hdr_ref_valid1),
        .rxdv0_live     (rxdv0_live),     .rxdv1_live     (rxdv1_live)
    );

    //==================================================================
    // 7. payload -> observation: status levels and the reference bucket
    //==================================================================
    wire [1:0] match_o;
    wire [1:0] acq_o;
    wire [3:0] rxdv_o;
    wire [13:0] href_o;      // {hdr_ref1, hdr_ref0, valid1, valid0}

    p7a_bit_sync #(.W(2)) u_sync_match (
        .clk (clk_obs), .d ({ch1_prbs_match, ch0_prbs_match}), .q (match_o));

    p7a_bit_sync #(.W(2)) u_sync_acq (
        .clk (clk_obs), .d ({acq1, acq0}), .q (acq_o));

    p7a_bit_sync #(.W(4)) u_sync_rxdv (
        .clk (clk_obs), .d ({rxdv1_live, rxdv0_live}), .q (rxdv_o));

    // MCP value: written once per measurement window, never changes while the
    // host reads it, so a plain 2-flop sync is safe here (see p7a_bit_sync.v).
    p7a_bit_sync #(.W(14)) u_sync_href (
        .clk (clk_obs),
        .d   ({hdr_ref1, hdr_ref0, hdr_ref_valid1, hdr_ref_valid0}),
        .q   (href_o));

    wire ref_link0, ref_link1, ref_dl0, ref_dl1;

    p7a_ref_bucket u_ref0 (
        .clk (clk_obs), .rst (rst_obs),
        .prbs_error_in (~match_o[0]), .dl_reset (clear_pls),
        .ref_link (ref_link0), .ref_down_latched (ref_dl0));

    p7a_ref_bucket u_ref1 (
        .clk (clk_obs), .rst (rst_obs),
        .prbs_error_in (~match_o[1]), .dl_reset (clear_pls),
        .ref_link (ref_link1), .ref_down_latched (ref_dl1));

    //==================================================================
    // 8. VIO packing  (probe names in the .ltx come from the NET names,
    //    which is why every probe below is driven by an explicitly named wire)
    //==================================================================
    wire [63:0] vio_err_snap     = {err_snap1, err_snap0};
    wire [95:0] vio_bits_snap    = {bits_snap1, bits_snap0};
    wire [95:0] vio_hdrs_snap    = {hdrs_snap1, hdrs_snap0};
    wire [63:0] vio_hdre_snap    = {hdre_snap1, hdre_snap0};
    wire [95:0] vio_rxcyc_snap   = {rxcyc_snap1, rxcyc_snap0};
    wire [95:0] vio_rxdvcyc_snap = {rxdvcyc_snap1, rxdvcyc_snap0};

    //  status word bit map (MSB first as written below)
    //   [95:89] 0
    //   [88:87] rxdatavalid ch1 (live sample, synced)
    //   [86:85] rxdatavalid ch0 (live sample, synced)
    //   [84:83] 0
    //   [82:77] hdr_ref ch1[5:0]      (captured, stable for the window)
    //   [76:71] hdr_ref ch0[5:0]
    //   [70]    build fingerprint = 1
    //   [69]    rst_obs
    //   [68]    vio_gt_reset echo
    //   [67]    vio_slip_force echo
    //   [66]    vio_cnt_clear echo
    //   [65]    vio_snap_req echo
    //   [64]    hdr_ref_valid ch1
    //   [63]    hdr_ref_valid ch0
    //   [62]    ref_down_latched ch1    (example leaky bucket, INFO ONLY)
    //   [61]    ref_down_latched ch0
    //   [60]    ref_link ch1            (example leaky bucket, INFO ONLY)
    //   [59]    ref_link ch0
    //   [58]    acq ch1                 (our criterion's live state)
    //   [57]    acq ch0
    //   [56]    sfp2_rx_los
    //   [55]    sfp1_rx_los
    //   [54]    gtwiz_reset_rx_cdr_stable
    //   [53]    gtwiz_reset_rx_done
    //   [52]    gtwiz_reset_tx_done
    //   [51]    gtpowergood ch1
    //   [50]    gtpowergood ch0
    //   [49]    mmcm_locked
    //   [48]    snap_ack (toggle: flips once per snapshot)
    //   [47:0]  fr_cyc_snap (observation-domain cycles at that snapshot)
    wire [95:0] vio_status = {
        7'd0,
        rxdv_o[3:2],
        rxdv_o[1:0],
        2'd0,
        href_o[13:8],
        href_o[7:2],
        1'b1,
        rst_obs,
        raw_gt_reset_r,
        raw_slip_r,
        raw_clear_r,
        raw_snap_r,
        href_o[1],
        href_o[0],
        ref_dl1,
        ref_dl0,
        ref_link1,
        ref_link0,
        acq_o[1],
        acq_o[0],
        sfp2_rx_los,
        sfp1_rx_los,
        gtwiz_reset_rx_cdr_stable_int[0],
        gtwiz_reset_rx_done_int[0],
        gtwiz_reset_tx_done_int[0],
        gtpowergood_int[1],
        gtpowergood_int[0],
        mmcm_locked,
        snap_ack_obs,
        fr_cyc_snap
    };

    vio_p7a u_vio (
        .clk        (clk_obs),
        .probe_in0  (vio_err_snap),
        .probe_in1  (vio_bits_snap),
        .probe_in2  (vio_hdrs_snap),
        .probe_in3  (vio_hdre_snap),
        .probe_in4  (vio_rxcyc_snap),
        .probe_in5  (vio_rxdvcyc_snap),
        .probe_in6  (vio_status),
        .probe_out0 (raw_snap),
        .probe_out1 (raw_clear),
        .probe_out2 (raw_slip),
        .probe_out3 (raw_gt_reset)
    );

    //==================================================================
    // 9. SFP control  (see the header: both TX_DIS must be LOW)
    //==================================================================
    assign sfp1_tx_dis = 1'b0;
    assign sfp2_tx_dis = 1'b0;

endmodule
