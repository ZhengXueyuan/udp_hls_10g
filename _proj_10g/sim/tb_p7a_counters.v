//======================================================================
// tb_p7a_counters.v -- P7a unit gate: PRBS chain + counters + ATOMIC snapshot
//======================================================================
//
//  Run: sim/run_tb_p7a_counters.bat
//
//  What is under test, and what is not
//  -----------------------------------
//  The gate instantiates the REAL fabric-side chain of p7a_top.v:
//     gt_10gbr_example_stimulus_64b66b_async  (PRBS31 generator, 64b/66b padded)
//          -> an error injector (the TB's model of "the line corrupted a word")
//          -> gt_10gbr_example_checking_64b66b_async (PRBS31 checker)
//          -> p7a_counters  (the counters and the snapshot that decide P7a)
//  driven through the REAL control path (p7a_vio_ctrl <-> p7a_counters), i.e.
//  the gate pokes the same levels the VIO would and reads back the same
//  snapshot registers the host reads.
//
//  NOT under test: the transceiver. The GT is modelled as a wire (TX word in =
//  RX word out), so nothing here says anything about the GT, the gearbox, or
//  the 64b/66b header semantics -- those are what the hardware run measures.
//
//  Gate criteria
//  -------------
//   C1  clear: a clear command zeroes the counters AND drops acq (so a
//       measurement window really restarts).
//   C2  clean run: with the two PRBS ends wired to each other, acq sets,
//       err_word_cnt stays 0, and bits_cnt advances (the positive control that
//       "0 errors" is not the vacuous kind).
//   C3  known error count: K isolated single-bit errors produce exactly K*m
//       errored words, where m is MEASURED first with a single injection
//       (m > 1 is expected -- the checker re-seeds its LFSR from the received
//       data, so one bad word can pollute the next one too).
//   C4  header coverage gap: M corrupted SYNC HEADERS produce hdre = M while
//       err_word_cnt stays 0 -- the payload checker cannot see the header, so
//       R3's gap is demonstrated, not assumed.
//   C5  ⭐ atomicity under race: while ~every word is errored (the counters
//       change every cycle), 200 snapshots are taken at arbitrary phases and
//       every one of them must satisfy the mutual-consistency invariants
//         bits % 64 == 0, err <= bits/64, hdrs == bits/64, hdre <= hdrs,
//         rxcyc >= bits/64
//       which the atomic snapshot satisfies BY CONSTRUCTION.
//   C6  NEGATIVE CONTROL for C5: a second p7a_counters instance with
//       TEAR_INJECT=1 (the four counter groups latched on four different
//       cycles) is fed the identical stimulus. C5's criteria MUST FAIL on it.
//       If they pass, the criteria have no discriminating power and the gate
//       fails, whatever the positive instance did.
//   C7  frozen snapshot: between two requests the snapshot registers must not
//       change even though the live counters keep counting.
//   C8  control protocol: N snap requests produce exactly N acks (the
//       edge-detect + toggle synchroniser path).
//   C9  ratio criterion: (bits_cnt/64)/fr_cyc must read 1.0 +-0.5 % when the
//       payload clock is 156.25 MHz, and MUST read ~1.03125 (i.e. FAIL) when
//       the payload clock is driven at 161.1328125 MHz -- the raw-mode rate.
//       That is the same criterion the board uses to prove the gearbox ratio,
//       so it has to be shown to discriminate.
//======================================================================

`timescale 1ns / 1ps

module tb_p7a_counters;

    //==================================================================
    // clocks
    //==================================================================
    // observation clock: 156.25 MHz (MMCM output on the board)
    reg clk_obs = 1'b0;
    always #3.2 clk_obs = ~clk_obs;

    // payload clock: 156.25 MHz (gearbox) by default; the TB switches it to the
    // raw-mode rate 161.1328125 MHz for criterion C9.
    real rx_half = 3.2;              // ns; 3.1030 ns = 161.1328125 MHz
    reg  clk_rx  = 1'b0;
    always begin #(rx_half) clk_rx = 1'b1; #(rx_half) clk_rx = 1'b0; end

    //==================================================================
    // bookkeeping
    //==================================================================
    integer checks   = 0;
    integer failures = 0;
    integer pos_inv  = 0;     // positive-DUT invariant violations (must be 0)
    integer neg_inv  = 0;     // negative-control violations (must be > 0)
    integer nsnap    = 0;
    integer reqs     = 0;
    integer acks     = 0;
    integer m_words  = 0;     // errored words per single injected bit error
    integer pr_lim   = 0;     // cap on printed invariant violations

    real    ratio_gb  = 0.0;
    real    ratio_raw = 0.0;

    task chk;
        input [8*64:1] name;
        input integer  got;
        input integer  exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                failures = failures + 1;
                $display("  [FAIL] %0s : got=%0d exp=%0d", name, got, exp);
            end else begin
                $display("  [ ok ] %0s : got=%0d exp=%0d", name, got, exp);
            end
        end
    endtask

    task chk_real;
        input [8*64:1] name;
        input real     got;
        input real     lo;
        input real     hi;
        input integer  want_in_range;
        begin
            checks = checks + 1;
            if ((got >= lo) && (got <= hi)) begin
                if (want_in_range == 1) $display("  [ ok ] %0s : %f in [%f,%f]", name, got, lo, hi);
                else begin failures = failures + 1; $display("  [FAIL] %0s : %f in [%f,%f] but expected OUT", name, got, lo, hi); end
            end else begin
                if (want_in_range == 0) $display("  [ ok ] %0s : %f outside [%f,%f] as required", name, got, lo, hi);
                else begin failures = failures + 1; $display("  [FAIL] %0s : %f outside [%f,%f]", name, got, lo, hi); end
            end
        end
    endtask

    //==================================================================
    // control levels (what the VIO drives) and the control module
    //==================================================================
    reg  raw_snap = 1'b0, raw_clear = 1'b0, raw_slip = 1'b0, raw_gt_reset = 1'b0;
    wire snap_tgl, clear_tgl, slip_tgl, gt_reset_level;
    wire snap_pls, clear_pls, slip_pls;
    wire raw_snap_r, raw_clear_r, raw_slip_r, raw_gt_reset_r;

    reg  rst_obs = 1'b1;
    reg  rx_active = 1'b0;

    p7a_vio_ctrl u_vio_ctrl (
        .clk (clk_obs), .rst (rst_obs),
        .raw_snap (raw_snap), .raw_clear (raw_clear),
        .raw_slip (raw_slip), .raw_gt_reset (raw_gt_reset),
        .snap_tgl (snap_tgl), .clear_tgl (clear_tgl), .slip_tgl (slip_tgl),
        .gt_reset_level (gt_reset_level),
        .snap_pls (snap_pls), .clear_pls (clear_pls), .slip_pls (slip_pls),
        .raw_snap_r (raw_snap_r), .raw_clear_r (raw_clear_r),
        .raw_slip_r (raw_slip_r), .raw_gt_reset_r (raw_gt_reset_r)
    );

    //==================================================================
    // PRBS chain: generator -> injector -> checker
    //==================================================================
    reg        prbs_rst = 1'b1;
    wire [63:0] txdata;
    wire  [5:0] txheader;
    wire  [6:0] txseq;

    gt_10gbr_example_stimulus_64b66b_async u_stim (
        .gtwiz_reset_all_in          (prbs_rst),
        .gtwiz_userclk_tx_usrclk2_in (clk_rx),
        .gtwiz_userclk_tx_active_in  (1'b1),
        .txheader_out                (txheader),
        .txsequence_out              (txseq),
        .txdata_out                  (txdata)
    );

    // ---- the line: one register of delay, plus the injectors -------------
    reg  [63:0] err_mask = 64'd0;    // XORed into the word (payload corruption)
    reg   [5:0] hdr_mask = 6'd0;     // XORed into the sync header
    reg         hdrval   = 1'b0;     // rxheadervalid
    reg   [1:0] rxdv     = 2'b11;    // rxdatavalid model
    reg  [63:0] rxdata;
    wire  [5:0] rxheader = txheader ^ hdr_mask;

    always @(posedge clk_rx) rxdata <= txdata ^ err_mask;

    wire chk_slip;
    wire prbs_match;

    gt_10gbr_example_checking_64b66b_async u_chk (
        .gtwiz_reset_all_in          (prbs_rst),
        .gtwiz_userclk_rx_usrclk2_in (clk_rx),
        .gtwiz_userclk_rx_active_in  (1'b1),
        .rxdatavalid_in              (rxdv),
        .rxgearboxslip_out           (chk_slip),
        .rxdata_in                   (rxdata),
        .prbs_match_out              (prbs_match)
    );

    //==================================================================
    // DUT: the real counter module, and the torn twin as negative control
    //==================================================================
    wire [31:0] p_err0, p_err1, n_err0, n_err1;
    wire [47:0] p_bits0, p_bits1, n_bits0, n_bits1;
    wire [47:0] p_hdrs0, p_hdrs1, n_hdrs0, n_hdrs1;
    wire [31:0] p_hdre0, p_hdre1, n_hdre0, n_hdre1;
    wire [47:0] p_rxc0, p_rxc1, n_rxc0, n_rxc1;
    wire [47:0] p_rdvc0, p_rdvc1, n_rdvc0, n_rdvc1;
    wire [1:0]  p_rxdl0, p_rxdl1, n_rxdl0, n_rxdl1;
    wire        p_acq0, p_acq1, n_acq0, n_acq1;
    wire  [5:0] p_href0, p_href1, n_href0, n_href1;
    wire        p_hrefv0, p_hrefv1, n_hrefv0, n_hrefv1;
    wire        p_ack, n_ack;
    wire [47:0] p_fr, n_fr;

    p7a_counters #(.TEAR_INJECT(0)) u_dut_pos (
        .clk (clk_rx), .rst (~rx_active),
        .ch0_match (prbs_match), .ch1_match (prbs_match),
        .ch0_rxdv (rxdv), .ch1_rxdv (rxdv),
        .ch0_hdr (rxheader), .ch1_hdr (rxheader),
        .ch0_hdrval (hdrval), .ch1_hdrval (hdrval),
        .clk_obs (clk_obs), .rst_obs (rst_obs),
        .snap_req_tgl (snap_tgl), .cnt_clear_tgl (clear_tgl),
        .snap_ack_obs (p_ack), .fr_cyc_snap (p_fr),
        .err_snap0 (p_err0), .err_snap1 (p_err1),
        .bits_snap0 (p_bits0), .bits_snap1 (p_bits1),
        .hdrs_snap0 (p_hdrs0), .hdrs_snap1 (p_hdrs1),
        .hdre_snap0 (p_hdre0), .hdre_snap1 (p_hdre1),
        .rxcyc_snap0 (p_rxc0), .rxcyc_snap1 (p_rxc1),
        .rxdvcyc_snap0 (p_rdvc0), .rxdvcyc_snap1 (p_rdvc1),
        .acq0 (p_acq0), .acq1 (p_acq1),
        .hdr_ref0 (p_href0), .hdr_ref1 (p_href1),
        .hdr_ref_valid0 (p_hrefv0), .hdr_ref_valid1 (p_hrefv1),
        .rxdv0_live (p_rxdl0), .rxdv1_live (p_rxdl1)
    );

    p7a_counters #(.TEAR_INJECT(1)) u_dut_neg (
        .clk (clk_rx), .rst (~rx_active),
        .ch0_match (prbs_match), .ch1_match (prbs_match),
        .ch0_rxdv (rxdv), .ch1_rxdv (rxdv),
        .ch0_hdr (rxheader), .ch1_hdr (rxheader),
        .ch0_hdrval (hdrval), .ch1_hdrval (hdrval),
        .clk_obs (clk_obs), .rst_obs (rst_obs),
        .snap_req_tgl (snap_tgl), .cnt_clear_tgl (clear_tgl),
        .snap_ack_obs (n_ack), .fr_cyc_snap (n_fr),
        .err_snap0 (n_err0), .err_snap1 (n_err1),
        .bits_snap0 (n_bits0), .bits_snap1 (n_bits1),
        .hdrs_snap0 (n_hdrs0), .hdrs_snap1 (n_hdrs1),
        .hdre_snap0 (n_hdre0), .hdre_snap1 (n_hdre1),
        .rxcyc_snap0 (n_rxc0), .rxcyc_snap1 (n_rxc1),
        .rxdvcyc_snap0 (n_rdvc0), .rxdvcyc_snap1 (n_rdvc1),
        .acq0 (n_acq0), .acq1 (n_acq1),
        .hdr_ref0 (n_href0), .hdr_ref1 (n_href1),
        .hdr_ref_valid0 (n_hrefv0), .hdr_ref_valid1 (n_hrefv1),
        .rxdv0_live (n_rxdl0), .rxdv1_live (n_rxdl1)
    );

    //==================================================================
    // ack edge counter (criterion C8) -- rising edges of the obs-domain ack
    //==================================================================
    reg ack_d = 1'b0;
    always @(posedge clk_obs) begin
        ack_d <= p_ack;
        if (p_ack !== ack_d) acks = acks + 1;   // a TOGGLE has TWO transitions
    end

    //==================================================================
    // tasks
    //==================================================================
    integer i, k;
    reg [47:0] b0_save, b1_save, s0_save, s1_save;
    reg [31:0] e0_save, e1_save, x0_save, x1_save;
    reg [47:0] rc0_save, rc1_save;
    reg [47:0] c2_fr;
    reg [47:0] w_bits, w_fr;      // window start for the delta ratio (save_pos must not clobber)
    real       ratio_abs     = 0.0;
    real       ratio_abs_raw = 0.0;

    // ---- clear all counters: level high then low, in the obs domain -----
    task do_clear;
        begin
            @(posedge clk_obs); raw_clear <= 1'b1;
            @(posedge clk_obs); raw_clear <= 1'b0;
            repeat (40) @(posedge clk_rx);      // let it cross into the payload domain
        end
    endtask

    // ---- one snapshot request; returns after the ack has moved ----------
    task do_snap;
        integer guard;
        begin
            @(posedge clk_obs); raw_snap <= 1'b1; reqs = reqs + 1;
            @(posedge clk_obs); raw_snap <= 1'b0;
            guard = 0;
            while ((p_ack === ack_d) && (guard < 200)) begin
                @(posedge clk_obs); guard = guard + 1;
            end
            if (guard >= 200) $display("  [WARN] snapshot ack timeout");
            repeat (20) @(posedge clk_obs);     // the host would read now
        end
    endtask

    // ---- save / compare the snapshot registers --------------------------
    task save_pos;
        begin
            b0_save = p_bits0; b1_save = p_bits1;
            s0_save = p_hdrs0; s1_save = p_hdrs1;
            e0_save = p_err0;  e1_save = p_err1;
            x0_save = p_hdre0; x1_save = p_hdre1;
            rc0_save = p_rxc0; rc1_save = p_rxc1;
        end
    endtask

    task save_neg;
        begin
            b0_save = n_bits0; b1_save = n_bits1;
            s0_save = n_hdrs0; s1_save = n_hdrs1;
            e0_save = n_err0;  e1_save = n_err1;
            x0_save = n_hdre0; x1_save = n_hdre1;
            rc0_save = n_rxc0; rc1_save = n_rxc1;
        end
    endtask

    // ---- the mutual-consistency invariants (criterion C5) ---------------
    // Every one of these holds EXACTLY for an atomic snapshot, and is broken by
    // a torn one as soon as errors arrive at (or near) word rate.
    task chk_inv;
        input integer is_neg;
        begin
            checks = checks + 1;
            if (!((b0_save % 64) == 0) || !((b1_save % 64) == 0)) begin
                if (is_neg) neg_inv = neg_inv + 1; else begin pos_inv = pos_inv + 1;
                    if (pr_lim < 8) $display("  [FAIL] bits not a multiple of 64: b0=%0d b1=%0d", b0_save, b1_save); end
            end
            if (!(e0_save <= (b0_save >> 6)) || !(e1_save <= (b1_save >> 6))) begin
                if (is_neg) neg_inv = neg_inv + 1; else begin pos_inv = pos_inv + 1;
                    if (pr_lim < 8) $display("  [FAIL] err > bits/64: e0=%0d b0/64=%0d e1=%0d b1/64=%0d",
                             e0_save, b0_save>>6, e1_save, b1_save>>6); end
            end
            if (!(s0_save == (b0_save >> 6)) || !(s1_save == (b1_save >> 6))) begin
                if (is_neg) neg_inv = neg_inv + 1; else begin pos_inv = pos_inv + 1;
                    if (pr_lim < 8) $display("  [FAIL] hdrs != bits/64: s0=%0d b0/64=%0d s1=%0d b1/64=%0d",
                             s0_save, b0_save>>6, s1_save, b1_save>>6); end
            end
            if (!(x0_save <= s0_save) || !(x1_save <= s1_save)) begin
                if (is_neg) neg_inv = neg_inv + 1; else begin pos_inv = pos_inv + 1;
                    if (pr_lim < 8) $display("  [FAIL] hdre > hdrs: x0=%0d s0=%0d x1=%0d s1=%0d",
                             x0_save, s0_save, x1_save, s1_save); end
            end
            if (!(rc0_save >= (b0_save >> 6)) || !(rc1_save >= (b1_save >> 6))) begin
                if (is_neg) neg_inv = neg_inv + 1; else begin pos_inv = pos_inv + 1;
                    if (pr_lim < 8) $display("  [FAIL] rxcyc < bits/64: rc0=%0d b0/64=%0d", rc0_save, b0_save>>6); end
            end
        end
    endtask

    // ---- one isolated single-bit error on the next word ------------------
    task inject_bit_err;
        begin
            @(posedge clk_rx); err_mask <= 64'h1;     // bit 0 of one word only
            @(posedge clk_rx); err_mask <= 64'd0;
            repeat (20) @(posedge clk_rx);
        end
    endtask

    task inject_hdr_err;
        begin
            @(posedge clk_rx); hdr_mask <= 6'h1;      // one header bit, one word
            @(posedge clk_rx); hdr_mask <= 6'd0;
            repeat (20) @(posedge clk_rx);
        end
    endtask

    task wait_acq;
        integer g;
        begin
            g = 0;
            while (((p_acq0 !== 1'b1) || (p_acq1 !== 1'b1)) && (g < 2000)) begin
                @(posedge clk_rx); g = g + 1;
            end
            if (g >= 2000) $display("  [WARN] acq did not set within 2000 rx cycles");
        end
    endtask

    // ---- ratio criterion (C9) -------------------------------------------
    // DELTA form: two snapshots bracket the window, so the fixed acquisition
    // latency (acq needs LOCK_THRESH words before anything is counted) cancels
    // out. The absolute form is recorded too, because at short windows it is
    // visibly biased by that latency -- which is exactly why the host-side
    // observation script must use deltas as well.
    task calc_ratio;
        input  [47:0] b_start;
        input  [47:0] f_start;
        output real   r;
        output real   r_abs;
        begin
            if (p_fr == f_start) r = 0.0;
            else                 r = (((p_bits0 - b_start) / 64.0)) / ((p_fr - f_start) * 1.0);
            if (p_fr == 0)       r_abs = 0.0;
            else                 r_abs = (p_bits0 / 64.0) / (p_fr * 1.0);
        end
    endtask

    //==================================================================
    // stimulus
    //==================================================================
    initial begin
        $display("===== P7a unit gate: PRBS chain + counters + atomic snapshot =====");
        rst_obs = 1'b1;
        repeat (4) @(posedge clk_obs);
        rst_obs = 1'b0;

        // release the PRBS ends and the payload domain
        repeat (10) @(posedge clk_rx);
        prbs_rst  <= 1'b0;
        rx_active <= 1'b1;
        hdrval    <= 1'b1;
        repeat (10) @(posedge clk_rx);

        //--------------------------------------------------------------
        $display("\n-- C1: acq is sticky through errors; a clear restarts it --");
        wait_acq;
        do_snap;
        $display("  before: bits0=%0d err0=%0d acq0=%b", p_bits0, p_err0, p_acq0);
        chk("C1a pre bits>0", (p_bits0 > 0), 1);
        // Corrupt EVERY word: the consecutive-match run counter then never
        // reaches its threshold, so a NON-sticky implementation would drop acq
        // here and silently restart the measurement. acq must stay set -- errors
        // are there to be COUNTED, never to reset the window.
        err_mask <= 64'hFFFFFFFFFFFFFFFF;
        repeat (200) @(posedge clk_rx);
        do_snap;
        $display("  under full corruption: err0=%0d bits0=%0d acq0=%b", p_err0, p_bits0, p_acq0);
        chk("C1b acq sticky through errors", p_acq0, 1);
        chk("C1b errors counted", (p_err0 > 0), 1);
        chk("C1b bits kept counting", (p_bits0 > 0), 1);
        // now a real clear, with the corruption still running so acq cannot
        // re-acquire before the snapshot is taken
        do_clear;
        do_snap;
        chk("C1c err0==0 after clear",  p_err0, 0);
        chk("C1c bits0==0 after clear", p_bits0, 0);
        chk("C1c hdrs0==0 after clear", p_hdrs0, 0);
        chk("C1c acq0 dropped", p_acq0, 0);
        chk("C1c acq1 dropped", p_acq1, 0);
        chk("C1c rxcyc small (not stale)", (p_rxc0 < 400), 1);
        err_mask <= 64'd0;
        wait_acq;
        chk("C1d acq re-acquires", p_acq0, 1);

        //--------------------------------------------------------------
        $display("\n-- C2: clean run, acq sets, bits advance, err stays 0 --");
        wait_acq;
        do_snap; w_bits = p_bits0; w_fr = p_fr;
        repeat (5000) @(posedge clk_rx);
        do_snap; save_pos;
        calc_ratio(w_bits, w_fr, ratio_gb, ratio_abs);
        $display("  bits0=%0d (words=%0d) err0=%0d hdrs0=%0d hdre0=%0d rxcyc0=%0d fr=%0d",
                 p_bits0, b0_save>>6, e0_save, s0_save, x0_save, rc0_save, p_fr);
        chk("C2 acq0 set", p_acq0, 1);
        chk("C2 err0==0",  e0_save, 0);
        chk("C2 err1==0",  e1_save, 0);
        chk("C2 hdre0==0", x0_save, 0);
        chk("C2 bits0>0 (positive control)", (b0_save > 0), 1);
        chk("C2 hdrs0==bits0/64", s0_save, (b0_save>>6));
        chk("C2 hdr_ref ch0 captured", p_hrefv0, 1);
        chk("C2 hdr_ref ch1 captured", p_hrefv1, 1);
        $display("  hdr_ref ch0 = %b  (the TX header the checker model passed through)", p_href0);
        chk_inv(0);
        chk("C2 pos violations", pos_inv, 0);
        chk("C2 rxdatavalid live sample", p_rxdl0, 2'b11);

        //--------------------------------------------------------------
        $display("\n-- C3: K isolated bit errors -> exactly K*m errored words --");
        do_clear; wait_acq;
        repeat (100) @(posedge clk_rx);
        do_snap; save_pos;                       // baseline (should be 0)
        $display("  baseline err0=%0d", p_err0);
        inject_bit_err;
        do_snap;
        m_words = p_err0;
        $display("  m (errored words per single injected bit error) = %0d", m_words);
        chk("C3 m >= 1", (m_words >= 1), 1);
        // now K = 10 injections, spaced far apart, same bit position
        do_clear; wait_acq;
        repeat (100) @(posedge clk_rx);
        for (k = 0; k < 10; k = k + 1) begin
            inject_bit_err;
            repeat (60) @(posedge clk_rx);
        end
        do_snap;
        $display("  injected K=10 errors -> err0=%0d (expect %0d)", p_err0, 10*m_words);
        chk("C3 err0 == 10*m", p_err0, 10*m_words);
        chk("C3 hdre0==0 for payload errors", p_hdre0, 0);

        //--------------------------------------------------------------
        $display("\n-- C4: header corruption is INVISIBLE to the payload checker --");
        do_clear; wait_acq;
        repeat (100) @(posedge clk_rx);
        for (k = 0; k < 5; k = k + 1) begin
            inject_hdr_err;
            repeat (60) @(posedge clk_rx);
        end
        do_snap;
        $display("  injected M=5 header errors -> hdre0=%0d err0=%0d hdrs0=%0d",
                 p_hdre0, p_err0, p_hdrs0);
        chk("C4 hdre0 == 5", p_hdre0, 5);
        chk("C4 err0 == 0 (the gap R3 describes)", p_err0, 0);
        chk("C4 hdrs0 == bits0/64", p_hdrs0, (p_bits0>>6));

        //--------------------------------------------------------------
        $display("\n-- C5/C6: atomicity under race, with the torn twin as negative control --");
        pos_inv = 0; neg_inv = 0; nsnap = 0; pr_lim = 0;
        do_clear; wait_acq;
        repeat (50) @(posedge clk_rx);
        for (i = 0; i < 200; i = i + 1) begin
            // error on EVERY cycle: the counters move as fast as they can, so a
            // non-atomic snapshot is overwhelmingly likely to be caught
            @(posedge clk_rx); err_mask <= 64'h1;
            do_snap; nsnap = nsnap + 1;
            save_pos; chk_inv(0);
            save_neg; chk_inv(1);
        end
        err_mask <= 64'd0;
        do_snap; save_pos;
        $display("  snapshots evaluated = %0d", nsnap);
        $display("  POSITIVE (atomic)  invariant violations = %0d", pos_inv);
        $display("  NEGATIVE (torn)    invariant violations = %0d", neg_inv);
        $display("  last positive snapshot: err0=%0d bits0=%0d hdrs0=%0d rxcyc0=%0d",
                 p_err0, p_bits0, p_hdrs0, p_rxc0);
        chk("C5 positive violations == 0", pos_inv, 0);
        chk("C6 negative violations >  0", (neg_inv > 0), 1);

        //--------------------------------------------------------------
        $display("\n-- C7: a snapshot is FROZEN until the next request --");
        do_snap; save_pos;
        b0_save = p_bits0; s0_save = p_hdrs0; e0_save = p_err0;
        repeat (500) @(posedge clk_rx);            // counters keep counting
        chk("C7 bits frozen", p_bits0, b0_save);
        chk("C7 hdrs frozen", p_hdrs0, s0_save);
        chk("C7 err  frozen", p_err0,  e0_save);
        do_snap;
        chk("C7 bits advanced after a new request", (p_bits0 != b0_save), 1);

        //--------------------------------------------------------------
        $display("\n-- C8: protocol -- N requests produce exactly N acks --");
        $display("  requests=%0d acks=%0d", reqs, acks);
        chk("C8 acks == requests", acks, reqs);

        //--------------------------------------------------------------
        $display("\n-- C9: the ratio criterion must discriminate 156.25 vs 161.1328125 --");
        $display("  payload clock = 156.25 MHz -> delta ratio = %f (abs=%f, expect 1.0 +- 0.5%%)",
                 ratio_gb, ratio_abs);
        chk_real("C9 ratio at 156.25", ratio_gb, 0.995, 1.005, 1);

        // switch the payload clock to the RAW-mode rate and re-measure.
        // 161.1328125 MHz = 10.3125e9/64 (raw) vs 10.3125e9/66 = 156.25 (gearbox)
        rx_half = 3.1030;                          // 6.2060 ns period
        repeat (20) @(posedge clk_rx);
        do_clear; wait_acq;
        do_snap; w_bits = p_bits0; w_fr = p_fr;
        repeat (20000) @(posedge clk_rx);
        do_snap; save_pos;
        calc_ratio(w_bits, w_fr, ratio_raw, ratio_abs_raw);
        $display("  payload clock = 161.1328125 MHz -> ratio = %f (expect ~1.03125)", ratio_raw);
        chk_real("C9 ratio at 161.1328125", ratio_raw, 0.995, 1.005, 0);
        rx_half = 3.2;

        //--------------------------------------------------------------
        $display("\n===== RESULT: checks=%0d failures=%0d =====", checks, failures);
        if (failures == 0) $display("GATE PASS");
        else               $display("GATE FAIL");
        $display("SUMMARY m_words_per_injected_bit_error=%0d nsnap=%0d pos_inv=%0d neg_inv=%0d ratio_gb=%f ratio_raw=%f ratio_abs_gb=%f",
                 m_words, nsnap, pos_inv, neg_inv, ratio_gb, ratio_raw, ratio_abs);
        $finish;
    end

    // hard stop so a broken gate cannot hang the runner
    initial begin
        #4_000_000;                                 // 4 ms of simulated time
        $display("TIMEOUT after 4 ms: checks=%0d failures=%0d", checks, failures);
        $display("GATE FAIL (timeout)");
        $finish;
    end

endmodule
