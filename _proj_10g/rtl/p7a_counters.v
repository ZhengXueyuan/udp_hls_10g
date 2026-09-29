//======================================================================
// p7a_counters.v -- P7a: per-channel BER counters + ATOMIC snapshot
//======================================================================
//
//  Why this module exists (spec P7A_SPEC.md 1.5 / R2)
//  --------------------------------------------------
//  The wizard example judges the link with a LEAKY BUCKET: in
//  gt_10gbr_example_top.v ST_LINK_UP a single errored word only subtracts 34
//  from a counter whose full scale is 67, so it takes TWO consecutive errors to
//  drop the link. A clean `link_status_out` therefore does NOT mean "zero
//  errors" -- it tolerates isolated ones. P7a has to state a BER, so the error
//  and bit counts are made HERE, with semantics a reader can recompute.
//
//  Channel map (measured, not assumed)
//  -----------------------------------
//    ch0 = quad 225 ch0 = X0Y4 = SFP A      ch1 = quad 225 ch1 = X0Y5 = SFP B
//    (source: _ibert/m2_loopback.tcl:133-134)  external loopback = X0Y4 <-> X0Y5
//
//  Counter semantics
//  -----------------
//  acq  (sticky, per channel): set once LOCK_THRESH consecutive words matched;
//       cleared only by cnt_clear/rst. EVERYTHING is counted only while acq is
//       set, so (a) the pre-lock bit-alignment hunt does not pollute the
//       numbers, and (b) "0 errors" can never be the vacuous kind: bits_cnt > 0
//       is the positive control that the counters were actually running.
//       An isolated error does NOT clear acq -- acq is not a lock indicator, it
//       is a "the measurement is live" indicator, so an error is always counted.
//
//  err_word_cnt   +1 per word with !prbs_match while acq.
//                 prbs_any in check mode re-seeds its LFSR from the received
//                 data, so one bad bit pollutes exactly one word (spec 5.1).
//                 => this counts ISOLATED ERRORED WORDS, not bit errors.
//  bits_cnt       +64 per word while acq => BER = err_word_cnt / (bits_cnt/64)
//  hdrs_cnt       +1 per word while acq with rxheadervalid. The 2-bit 64B/66B
//                 sync header is NOT part of the fabric payload (the gearbox
//                 inserts/strips it), so this is the only side of it the fabric
//                 can observe -- spec R3, an acknowledged coverage gap.
//  hdre_cnt       +1 when hdrs_cnt counts and rxheader != the reference value
//                 captured on the first header after acq. The encoding of the
//                 6-bit RXHEADER field was NOT decoded (spec 9.2), so the
//                 criterion is STABILITY against the first observed value, not
//                 equality with a constant guessed here.
//  rxcyc_cnt      +1 every clk while acq        (rate cross-check)
//  rxdvcyc_cnt    +1 every clk with |rxdatavalid while acq. rxdatavalid's
//                 duty cycle at 64-bit width is not documented (spec 9.12);
//                 this measures it instead of assuming it.
//
//  TWO clocks, on purpose
//  ----------------------
//   clk     = rx_usrclk2, 156.25 MHz recovered from the GT RX (the payload).
//   clk_obs = 156.25 MHz fabric clock (MMCM from the 100 MHz core-board crystal
//             Y1). It is INDEPENDENT of the GT configuration, which is what
//             makes fr_cyc a usable reference:
//               gearbox (66/64):  rx word rate = 10.3125e9 / 66 = 156.25 MHz
//                                 => (bits_cnt/64)/fr_cyc = 156.25/156.25 = 1.0
//               raw (64/64)    :  rx word rate = 10.3125e9 / 64 = 161.1328125 MHz
//                                 => ratio = 161.1328125/156.25 = 1.03125
//             A 3.125 % separation, measurable far more precisely than that, so
//             this is a RUN-TIME proof of the gearbox ratio (spec 4.2 / 5.4) and
//             not just a configuration attribute read back at build time.
//
//  ⭐ Why the snapshot is not optional (spec 5.2, R7)
//  -------------------------------------------------
//  Every counter here is far faster than a JTAG transaction (tens of ms). Read
//  live, err_word_cnt and bits_cnt would come from two different instants and a
//  carry between them would produce a combination that NEVER EXISTED ("low word
//  already carried, high word not yet"). That is the same failure class as "an
//  empty read-out is not a real zero". Therefore:
//    * snap_req arrives as a TOGGLE from the observation domain, is synchronised
//      here and edge-detected into a one-cycle snap_lat pulse on clk;
//    * ALL snapshot registers load from ONE always block on that pulse => every
//      value is from the same clk edge, by construction, not by luck;
//    * snap_ack_tgl flips on that same edge; the host must see it move before
//      it reads, which is what distinguishes "frozen" from "moving".
//
//  TEAR_INJECT (test-only fault injection)
//  ---------------------------------------
//  0 (default, and what the delivered bitstream uses) = the snapshot is atomic.
//  1 = deliberately torn: the counter groups are latched on four different
//      cycles, i.e. exactly the defect the atomic snapshot exists to prevent.
//      sim/tb_p7a_counters.v uses it as the NEGATIVE CONTROL: the gate's
//      mutual-consistency criteria must PASS on 0 and FAIL on 1. Without that,
//      the criteria would have no demonstrated discriminating power.
//      It sits inside a generate-if on a constant parameter, so the
//      TEAR_INJECT=0 elaboration contains none of the injected logic (the false
//      branch is not elaborated at all).
//======================================================================

`timescale 1ns / 1ps

module p7a_counters #(
    parameter integer LOCK_THRESH = 64,
    parameter integer TEAR_INJECT = 0
)(
    // -------- payload domain: rx_usrclk2 (156.25 MHz from the GT RX) --------
    input  wire        clk,
    input  wire        rst,             // synchronous, active high

    input  wire        ch0_match,       // ch0 prbs_match_out (lock = match)
    input  wire        ch1_match,
    input  wire  [1:0] ch0_rxdv,        // ch0 rxdatavalid_out[1:0]
    input  wire  [1:0] ch1_rxdv,
    input  wire  [5:0] ch0_hdr,         // ch0 rxheader_out[5:0]
    input  wire  [5:0] ch1_hdr,
    input  wire        ch0_hdrval,      // ch0 rxheadervalid_out
    input  wire        ch1_hdrval,

    // -------- observation domain: clk_obs (156.25 MHz fabric, MMCM) ---------
    input  wire        clk_obs,
    input  wire        rst_obs,
    input  wire        snap_req_tgl,    // 0->1->0 or 1->0->1 = one snapshot
    input  wire        cnt_clear_tgl,   // same protocol: restart the window
    output wire        snap_ack_obs,    // flips once per snapshot, IN THIS DOMAIN
    output wire [47:0] fr_cyc_snap,     // obs-domain cycle count at that snapshot

    // -------- snapshot + status (clk domain, static between snapshots) ------
    output wire [31:0] err_snap0,   output wire [31:0] err_snap1,
    output wire [47:0] bits_snap0,  output wire [47:0] bits_snap1,
    output wire [47:0] hdrs_snap0,  output wire [47:0] hdrs_snap1,
    output wire [31:0] hdre_snap0,  output wire [31:0] hdre_snap1,
    output wire [47:0] rxcyc_snap0, output wire [47:0] rxcyc_snap1,
    output wire [47:0] rxdvcyc_snap0, output wire [47:0] rxdvcyc_snap1,
    output wire        acq0,        output wire        acq1,
    output wire  [5:0] hdr_ref0,    output wire  [5:0] hdr_ref1,
    output wire        hdr_ref_valid0, output wire    hdr_ref_valid1,
    output wire  [1:0] rxdv0_live,  output wire  [1:0] rxdv1_live
);

    localparam [15:0] RUN_TOP = LOCK_THRESH[15:0];

    //==================================================================
    // 1. control synchronisers: observation domain -> payload domain
    //==================================================================
    wire snap_lat;
    wire clear_pulse;

    p7a_tgl_sync u_snap_sync  (.clk(clk), .rst(rst), .tgl_in(snap_req_tgl),  .pulse_out(snap_lat));
    p7a_tgl_sync u_clear_sync (.clk(clk), .rst(rst), .tgl_in(cnt_clear_tgl), .pulse_out(clear_pulse));

    //==================================================================
    // 2. live counters (payload domain)
    //==================================================================
    reg [15:0] run0, run1;
    reg        acq0_r, acq1_r;
    reg [31:0] err0,  err1;
    reg [47:0] bits0, bits1;
    reg [47:0] hdrs0, hdrs1;
    reg [31:0] hdre0, hdre1;
    reg [47:0] rxcyc0, rxcyc1;
    reg [47:0] rxdvcyc0, rxdvcyc1;
    reg  [5:0] hdr_ref0_r, hdr_ref1_r;
    reg        hdr_ref_valid0_r, hdr_ref_valid1_r;
    reg  [5:0] hdr_ref0_pub, hdr_ref1_pub;
    reg        hdr_ref_valid0_pub, hdr_ref_valid1_pub;

    always @(posedge clk) begin
        if (rst || clear_pulse) begin
            run0  <= 16'd0;      run1  <= 16'd0;
            acq0_r <= 1'b0;      acq1_r <= 1'b0;
            err0   <= 32'd0;     err1   <= 32'd0;
            bits0  <= 48'd0;     bits1  <= 48'd0;
            hdrs0  <= 48'd0;     hdrs1  <= 48'd0;
            hdre0  <= 32'd0;     hdre1  <= 32'd0;
            rxcyc0 <= 48'd0;     rxcyc1 <= 48'd0;
            rxdvcyc0 <= 48'd0;   rxdvcyc1 <= 48'd0;
            hdr_ref0_r <= 6'd0;  hdr_ref1_r <= 6'd0;
            hdr_ref_valid0_r <= 1'b0;  hdr_ref_valid1_r <= 1'b0;
        end else begin
            // ---------------- channel 0 ----------------
            rxcyc0 <= rxcyc0 + 48'd1;
            if (|ch0_rxdv) rxdvcyc0 <= rxdvcyc0 + 48'd1;

            if (ch0_match) begin
                if (run0 < RUN_TOP) run0 <= run0 + 16'd1;
                if ((run0 + 16'd1) >= RUN_TOP) acq0_r <= 1'b1;   // sticky
            end else begin
                run0 <= 16'd0;
            end

            if (acq0_r) begin
                bits0 <= bits0 + 48'd64;
                if (!ch0_match) err0 <= err0 + 32'd1;
                if (ch0_hdrval) begin
                    hdrs0 <= hdrs0 + 48'd1;
                    if (!hdr_ref_valid0_r) begin
                        hdr_ref0_r       <= ch0_hdr;   // first header after acq
                        hdr_ref_valid0_r <= 1'b1;
                    end else if (ch0_hdr != hdr_ref0_r) begin
                        hdre0 <= hdre0 + 32'd1;
                    end
                end
            end

            // ---------------- channel 1 (mirror) ----------------
            rxcyc1 <= rxcyc1 + 48'd1;
            if (|ch1_rxdv) rxdvcyc1 <= rxdvcyc1 + 48'd1;

            if (ch1_match) begin
                if (run1 < RUN_TOP) run1 <= run1 + 16'd1;
                if ((run1 + 16'd1) >= RUN_TOP) acq1_r <= 1'b1;   // sticky
            end else begin
                run1 <= 16'd0;
            end

            if (acq1_r) begin
                bits1 <= bits1 + 48'd64;
                if (!ch1_match) err1 <= err1 + 32'd1;
                if (ch1_hdrval) begin
                    hdrs1 <= hdrs1 + 48'd1;
                    if (!hdr_ref_valid1_r) begin
                        hdr_ref1_r       <= ch1_hdr;
                        hdr_ref_valid1_r <= 1'b1;
                    end else if (ch1_hdr != hdr_ref1_r) begin
                        hdre1 <= hdre1 + 32'd1;
                    end
                end
            end

            // published copies: the host waits for *_valid_pub, which rises one
            // cycle AFTER the value has settled => the 6-bit reference is a
            // stable multi-cycle value when it is first visible (no mixed read).
            hdr_ref0_pub <= hdr_ref0_r;  hdr_ref1_pub <= hdr_ref1_r;
            hdr_ref_valid0_pub <= hdr_ref_valid0_r;
            hdr_ref_valid1_pub <= hdr_ref_valid1_r;
        end
    end

    //==================================================================
    // 3. ATOMIC snapshot -- one always block, one clk edge
    //==================================================================
    reg [31:0] err_snap0_r, err_snap1_r;
    reg [47:0] bits_snap0_r, bits_snap1_r;
    reg [47:0] hdrs_snap0_r, hdrs_snap1_r;
    reg [31:0] hdre_snap0_r, hdre_snap1_r;
    reg [47:0] rxcyc_snap0_r, rxcyc_snap1_r;
    reg [47:0] rxdvcyc_snap0_r, rxdvcyc_snap1_r;
    reg        snap_ack_tgl_r;

    generate
    if (TEAR_INJECT == 0) begin : g_atomic
        always @(posedge clk) begin
            if (rst) begin
                err_snap0_r <= 32'd0;      err_snap1_r <= 32'd0;
                bits_snap0_r <= 48'd0;     bits_snap1_r <= 48'd0;
                hdrs_snap0_r <= 48'd0;     hdrs_snap1_r <= 48'd0;
                hdre_snap0_r <= 32'd0;     hdre_snap1_r <= 32'd0;
                rxcyc_snap0_r <= 48'd0;    rxcyc_snap1_r <= 48'd0;
                rxdvcyc_snap0_r <= 48'd0;  rxdvcyc_snap1_r <= 48'd0;
                snap_ack_tgl_r <= 1'b0;
            end else if (snap_lat) begin
                err_snap0_r   <= err0;     err_snap1_r   <= err1;
                bits_snap0_r  <= bits0;    bits_snap1_r  <= bits1;
                hdrs_snap0_r  <= hdrs0;    hdrs_snap1_r  <= hdrs1;
                hdre_snap0_r  <= hdre0;    hdre_snap1_r  <= hdre1;
                rxcyc_snap0_r <= rxcyc0;   rxcyc_snap1_r <= rxcyc1;
                rxdvcyc_snap0_r <= rxdvcyc0; rxdvcyc_snap1_r <= rxdvcyc1;
                snap_ack_tgl_r <= ~snap_ack_tgl_r;
            end
        end
    end else begin : g_torn
        // ---- NEGATIVE-CONTROL ONLY (see header). -------------------------
        // bits is latched first and err last, so while errors are arriving at
        // word rate the frozen pair can read err > bits/64: a combination the
        // atomic version can never produce.
        reg [3:0] dly;
        always @(posedge clk) begin
            if (rst) dly <= 4'd0;
            else     dly <= {dly[2:0], snap_lat};
        end
        always @(posedge clk) begin
            if (rst) begin
                err_snap0_r <= 32'd0;      err_snap1_r <= 32'd0;
                bits_snap0_r <= 48'd0;     bits_snap1_r <= 48'd0;
                hdrs_snap0_r <= 48'd0;     hdrs_snap1_r <= 48'd0;
                hdre_snap0_r <= 32'd0;     hdre_snap1_r <= 32'd0;
                rxcyc_snap0_r <= 48'd0;    rxcyc_snap1_r <= 48'd0;
                rxdvcyc_snap0_r <= 48'd0;  rxdvcyc_snap1_r <= 48'd0;
                snap_ack_tgl_r <= 1'b0;
            end else begin
                if (snap_lat) begin
                    bits_snap0_r <= bits0;  bits_snap1_r <= bits1;
                end
                if (dly[0]) begin
                    hdrs_snap0_r <= hdrs0;  hdrs_snap1_r <= hdrs1;
                end
                if (dly[1]) begin
                    hdre_snap0_r <= hdre0;  hdre_snap1_r <= hdre1;
                end
                if (dly[2]) begin
                    err_snap0_r <= err0;    err_snap1_r <= err1;
                end
                if (dly[3]) begin
                    rxcyc_snap0_r <= rxcyc0;  rxcyc_snap1_r <= rxcyc1;
                    rxdvcyc_snap0_r <= rxdvcyc0; rxdvcyc_snap1_r <= rxdvcyc1;
                    snap_ack_tgl_r <= ~snap_ack_tgl_r;
                end
            end
        end
    end
    endgenerate

    //==================================================================
    // 4. observation-domain side: free-running reference + ack sync
    //==================================================================
    reg [47:0] fr_cyc_r;
    reg [47:0] fr_cyc_snap_r;
    wire clear_pulse_obs;

    // cnt_clear_tgl originates in this domain, so the edge is taken directly
    // (no CDC): one pulse per host clear command.
    (* ASYNC_REG = "TRUE" *) reg [2:0] clr_sr    = 3'd0;
                             reg       clr_sr_d  = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] ack_sr    = 3'd0;
                             reg       ack_sr_d  = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] snap_sr   = 3'd0;
                             reg       snap_sr_d = 1'b0;

    // snap_req_tgl is generated in THIS domain (p7a_vio_ctrl) but the counter
    // module is also instantiated standalone in the test bench, where it is
    // driven from the observation domain -> keep a synchroniser here so the
    // module is correct in both uses.
    always @(posedge clk_obs) begin
        if (rst_obs) begin
            clr_sr <= 3'd0;  clr_sr_d <= 1'b0;
            ack_sr <= 3'd0;  ack_sr_d <= 1'b0;
            snap_sr <= 3'd0; snap_sr_d <= 1'b0;
            fr_cyc_r <= 48'd0; fr_cyc_snap_r <= 48'd0;
        end else begin
            clr_sr   <= {clr_sr[1:0], cnt_clear_tgl};
            clr_sr_d <= clr_sr[2];
            ack_sr   <= {ack_sr[1:0], snap_ack_tgl_r};
            ack_sr_d <= ack_sr[2];
            snap_sr  <= {snap_sr[1:0], snap_req_tgl};
            snap_sr_d<= snap_sr[2];

            if (clear_pulse_obs) fr_cyc_r <= 48'd0;
            else                 fr_cyc_r <= fr_cyc_r + 48'd1;

            if (snap_sr[2] ^ snap_sr_d) fr_cyc_snap_r <= fr_cyc_r;  // same edge as ack
        end
    end

    assign clear_pulse_obs = clr_sr[2] ^ clr_sr_d;

    //==================================================================
    // 5. outputs
    //==================================================================
    assign err_snap0 = err_snap0_r;     assign err_snap1 = err_snap1_r;
    assign bits_snap0 = bits_snap0_r;   assign bits_snap1 = bits_snap1_r;
    assign hdrs_snap0 = hdrs_snap0_r;   assign hdrs_snap1 = hdrs_snap1_r;
    assign hdre_snap0 = hdre_snap0_r;   assign hdre_snap1 = hdre_snap1_r;
    assign rxcyc_snap0 = rxcyc_snap0_r; assign rxcyc_snap1 = rxcyc_snap1_r;
    assign rxdvcyc_snap0 = rxdvcyc_snap0_r;
    assign rxdvcyc_snap1 = rxdvcyc_snap1_r;

    assign acq0 = acq0_r;               assign acq1 = acq1_r;
    assign hdr_ref0 = hdr_ref0_pub;     assign hdr_ref1 = hdr_ref1_pub;
    assign hdr_ref_valid0 = hdr_ref_valid0_pub;
    assign hdr_ref_valid1 = hdr_ref_valid1_pub;
    assign rxdv0_live = ch0_rxdv;       assign rxdv1_live = ch1_rxdv;

    // ⭐ the ack handed out is the one ALREADY SYNCHRONISED into the observation
    // domain: a host that waits for this edge is guaranteed to be looking at
    // frozen snapshot registers (they only change on the next snap_lat).
    assign snap_ack_obs = ack_sr[2];
    assign fr_cyc_snap  = fr_cyc_snap_r;

endmodule
