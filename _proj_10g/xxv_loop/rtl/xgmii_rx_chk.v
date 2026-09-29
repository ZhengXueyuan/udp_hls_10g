// ============================================================================
// xgmii_rx_chk.v -- an INDEPENDENT XGMII receive-side observer.
//
// WHY IT EXISTS
//   The vendor's pcs64_mii_traf_chk (inside pcs64_pkt_gen_mon) counts frames,
//   byte-lane positions and /E/ control characters.  Its "zero error" claim is
//   therefore a statement about frame/byte COUNTING and about /E/ characters --
//   it never compares payload CONTENT.  This module adds the content check, and
//   it also produces a positive, non-vacuous evidence floor:
//       o_words      free-running XGMII word counter  (rate evidence)
//       o_ctrl_words words carrying any control character (are blocks arriving?)
//       o_pay_words  payload words actually checked    (denominator of the check)
//   A "0 errors" reading is only meaningful next to a non-zero denominator.
//
// THE EXPECTED FRAME, DERIVED FROM THE VENDOR GENERATOR'S OWN LITERALS
//   pcs64_pkt_gen_mon.v  (xxv_probe/pcs64_ex/pcs64_ex/imports/):
//     preamble   = 64'hFB_55_55_55_55_55_55_D5
//     dest_addr  = 48'hFF_FF_FF_FF_FF_FF
//     source_addr= 48'h14_FE_B5_DD_9A_82
//     length_type= 16'h0600
//     eth_header = {preamble, dest_addr, source_addr, length_type}   (176 bits)
//     tx_mii_d  <= swapn(tx_datain)     -- swapn reverses the 8 bytes, so lane 0
//                                          (= tx_mii_d[7:0]) carries the FIRST
//                                          byte of the frame  => XGMII is
//                                          LSB-first, the opposite of this
//                                          project's tdata[63:56] convention.
//     data_select = 0  => op_data = 64'h0  (payload is ZEROS, not PRBS)
//     insert_crc  = 0  => no FCS is inserted
//     pkt_len = FIXED_PACKET_LENGTH = 256, 256%8 = 0
//   => 33 data words (word 0 = S + 6x55 + D5, word 1 = DA+SA[0:1],
//      word 2 = SA[2:5]+type+2 payload bytes, words 3..32 = zero payload),
//      then one terminating word with /T/ at lane 0.
//   Word values (lane0 = LSB byte):
//      w0 : 64'hD5555555555555FB   c = 8'h01
//      w1 : 64'hFE14FFFFFFFFFFFF   c = 8'h00
//      w2 : 64'h00000006829ADDB5   c = 8'h00
//      w3..w32 : 64'h0000000000000000  c = 8'h00
//      w33: c[0]=1 and d[7:0]=8'hFD    (lanes 1..7 are junk; /T/ is the last
//                                        valid byte, whatever follows it in the
//                                        same word belongs to no frame)
//   These constants are the checker's ONLY hard-coded expectation, and they come
//   from the vendor RTL above -- not from this design's own behaviour.
//
// FAILURE-MODE DISCRIMINATION (matters when reading the log)
//   * checker arithmetic wrong  -> EVERY word mismatches (o_bad_pay ~ o_words)
//   * real link damage          -> a few mismatches, /E/ characters, aborts
//   * lane rotation by 4        -> o_bad_start == o_frames while o_frames still
//                                  counts (frames arrive, content shifted)
// ============================================================================
`timescale 1ns/1ps

module xgmii_rx_chk (
    input  wire        clk_rx,
    input  wire        rst,           // synchronous reset (user_rx_reset_n)
    input  wire        pay_sel,       // 0: the vendor's all-zero XGMII payload
                                      // 1: the all-ones variant (see the note below)
    input  wire [63:0] d,
    input  wire [7:0]  c,
    output reg  [31:0] o_words,
    output reg  [31:0] o_frames,
    output reg  [31:0] o_ctrl_words,
    output reg  [31:0] o_idle_words,
    output reg  [31:0] o_e_words,
    output reg  [31:0] o_e_pre,      // /E/ words BEFORE the first completed frame
    output reg  [31:0] o_e_post,     // /E/ words AFTER it (i.e. on a live link)
    output reg  [31:0] o_pay_words,
    output reg  [31:0] o_bad_pay,
    output reg  [31:0] o_bad_start,
    output reg  [31:0] o_bad_hdr,
    output reg  [31:0] o_bad_term,
    output reg  [31:0] o_bad_len,
    output reg  [31:0] o_abort,
    output reg  [31:0] o_last_wpos,
    output reg  [63:0] o_s_word,
    output reg  [7:0]  o_s_c,
    output reg  [3:0]  o_t_lane,
    output reg         o_in_frame
);

    // expected frame geometry for FIXED_PACKET_LENGTH = 256
    localparam [63:0] W_START = 64'hD5555555555555FB;
    localparam [63:0] W_ONE   = 64'hFE14FFFFFFFFFFFF;
    localparam [63:0] W_TWO   = 64'h00000006829ADDB5;
    // MEASURED 2026-09-29 (first board run): the terminate word arrives with
    // wpos == 32, i.e. the frame is 32 data words (start word included) plus one
    // terminating word = 33 XGMII words.  The arithmetic in this file's header
    // had predicted 33 data words (34 words total) -- it was off by one, and the
    // board settled it.  Cross-check: the payload case must then run 29 times
    // per frame (wpos 3..31), which is what the board measured (580/20 = 29),
    // and the vendor's own tx_total_bytes == rx_total_bytes held exactly, so no
    // word is missing in transit.
    localparam [5:0]  LAST_DW = 6'd32;   // data words incl. the start word

    // Payload content.  The vendor generator hard-wires data_select = 2'b0, i.e. a
    // ZERO payload; this design's parameterised copy (rtl/pcs64_pkt_gen_mon_ds.v)
    // can also emit 2'b01 = an ALL-ONES payload, which exercises a completely
    // different scrambler/DC-balance state.  Only the payload lanes are affected:
    //   word 2 = lanes5..0 header (0x0006829ADDB5 in d[47:0]) + lanes7,6 payload
    //   words 3..32 = pure payload
    wire [63:0] pay64 = pay_sel ? 64'hFFFFFFFFFFFFFFFF : 64'h0000000000000000;
    wire [15:0] pay16 = pay_sel ? 16'hFFFF             : 16'h0000;

    // ---- word-granular detection (no per-lane adder tree: timing at 156 MHz)
    wire s_here    = c[0] & (d[7:0] == 8'hFB);
    wire idle_word = (c == 8'hFF) && (d == 64'h0707070707070707);
    wire ctl_any   = |c;

    function [3:0] tfind;
        input [63:0] dd;
        input [7:0]  cc;
        integer i;
        begin
            tfind = 4'hF;
            for (i = 0; i < 8; i = i + 1)
                if (cc[i] && (dd[i*8 +: 8] == 8'hFD) && (tfind == 4'hF)) tfind = i[3:0];
        end
    endfunction

    function eany;
        input [63:0] dd;
        input [7:0]  cc;
        integer i;
        begin
            eany = 1'b0;
            for (i = 0; i < 8; i = i + 1)
                if (cc[i] && (dd[i*8 +: 8] == 8'hFE)) eany = 1'b1;
        end
    endfunction

    wire [3:0] t_lane_now = tfind(d, c);
    wire       e_now      = eany(d, c);

    reg [5:0] wpos;
    reg       seen_frame;    // set by the first /T/: splits /E/ into pre/post

    always @(posedge clk_rx) begin
        if (rst) begin
            o_words <= 32'd0; o_frames <= 32'd0; o_ctrl_words <= 32'd0;
            o_idle_words <= 32'd0; o_e_words <= 32'd0; o_pay_words <= 32'd0;
            o_e_pre <= 32'd0; o_e_post <= 32'd0;
            o_bad_pay <= 32'd0; o_bad_start <= 32'd0; o_bad_hdr <= 32'd0;
            o_bad_term <= 32'd0; o_bad_len <= 32'd0; o_abort <= 32'd0;
            o_last_wpos <= 32'd0; o_s_word <= 64'd0; o_s_c <= 8'd0;
            o_t_lane <= 4'd0; o_in_frame <= 1'b0;
            wpos <= 6'd0;
            seen_frame <= 1'b0;
        end else begin
            o_words <= o_words + 32'd1;
            if (ctl_any)   o_ctrl_words <= o_ctrl_words + 32'd1;
            if (idle_word) o_idle_words <= o_idle_words + 32'd1;
            if (e_now) begin
                o_e_words <= o_e_words + 32'd1;
                if (!seen_frame) o_e_pre  <= o_e_pre  + 32'd1;
                else             o_e_post <= o_e_post + 32'd1;
            end

            if (!o_in_frame) begin
                if (s_here) begin
                    o_in_frame <= 1'b1;
                    wpos       <= 6'd1;
                    o_s_word   <= d;
                    o_s_c      <= c;
                    if ((d != W_START) || (c != 8'h01))
                        o_bad_start <= o_bad_start + 32'd1;
                end
            end else begin
                if (t_lane_now != 4'hF) begin
                    o_in_frame  <= 1'b0;
                    seen_frame  <= 1'b1;
                    o_frames    <= o_frames + 32'd1;
                    o_t_lane    <= t_lane_now;
                    o_last_wpos <= {26'd0, wpos};
                    if (!(c[0] && (d[7:0] == 8'hFD)))
                        o_bad_term <= o_bad_term + 32'd1;
                    if (wpos != LAST_DW)
                        o_bad_len <= o_bad_len + 32'd1;
                end else if (idle_word) begin
                    // an idle word cannot occur inside a frame: the generator or
                    // the link was reset mid-frame (e.g. by restart_tx_rx).
                    o_in_frame <= 1'b0;
                    o_abort    <= o_abort + 32'd1;
                end else begin
                    case (wpos)
                        6'd1: if ((d != W_ONE) || (c != 8'h00))
                                  o_bad_hdr <= o_bad_hdr + 32'd1;
                        6'd2: if ((d[47:0] != W_TWO[47:0]) || (d[63:48] != pay16)
                                  || (c != 8'h00))
                                  o_bad_hdr <= o_bad_hdr + 32'd1;
                        default: begin
                            o_pay_words <= o_pay_words + 32'd1;
                            if ((d != pay64) || (c != 8'h00))
                                o_bad_pay <= o_bad_pay + 32'd1;
                        end
                    endcase
                    wpos <= wpos + 6'd1;
                end
            end
        end
    end

endmodule
