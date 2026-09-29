//======================================================================
// p7a_ref_bucket.v -- P7a: the EXAMPLE's leaky bucket, kept for reference only
//======================================================================
//
//  This is a copy of the link-status state machine from
//  gt_10gbr_example_top.v (ST_LINK_DOWN / ST_LINK_UP, 67-point counter), one
//  instance per channel, running in the observation domain on a synchronised
//  prbs_error bit.
//
//  ⚠ IT IS NOT EVIDENCE OF ANYTHING. It is a LEAKY BUCKET: in ST_LINK_UP one
//  errored word only subtracts 34 from a counter whose full scale is 67, so an
//  isolated error leaves link_status high and link_down_latched untouched. It is
//  wired in for two reasons only:
//    1. it reproduces, in the P7a bitstream, the signal the wizard example would
//       have exported -- so the next phase can compare "example says link up"
//       against "our counters say N errors" and SEE the leaky bucket at work;
//    2. it gives an immediate "did the link ever come up" indication (0 -> 1
//       transition of ref_link) before any host-side arithmetic is done.
//  Every acceptance judgement in P7a uses err_word_cnt/bits_cnt from
//  p7a_counters.v instead, which is why this module is named ref_*.
//
//  Behaviour copied verbatim from the example (including the 67/34/33 numbers),
//  so the copy can be diffed against the source by eye.
//======================================================================

`timescale 1ns / 1ps

module p7a_ref_bucket (
    input  wire clk,
    input  wire rst,
    input  wire prbs_error_in,      // synchronised single-bit error indicator
    input  wire dl_reset,           // clear the sticky "link was down" flag

    output reg  ref_link,           // == the example's link_status_out
    output reg  ref_down_latched    // == the example's link_down_latched_out
);

    localparam ST_LINK_DOWN = 1'b0;
    localparam ST_LINK_UP   = 1'b1;

    reg [6:0] link_ctr = 7'd0;

    always @(posedge clk) begin
        if (rst) begin
            ref_link          <= ST_LINK_DOWN;
            link_ctr          <= 7'd0;
            ref_down_latched  <= 1'b1;
        end else begin
            case (ref_link)
                ST_LINK_DOWN: begin
                    if (prbs_error_in !== 1'b0) begin
                        link_ctr <= 7'd0;
                    end else begin
                        if (link_ctr < 7'd67) link_ctr <= link_ctr + 7'd1;
                        else                  ref_link <= ST_LINK_UP;
                    end
                end
                ST_LINK_UP: begin
                    if (prbs_error_in !== 1'b0) begin
                        if (link_ctr > 7'd33) begin
                            link_ctr <= link_ctr - 7'd34;
                            if (link_ctr == 7'd34) ref_link <= ST_LINK_DOWN;
                        end else begin
                            link_ctr <= 7'd0;
                            ref_link <= ST_LINK_DOWN;
                        end
                    end else begin
                        if (link_ctr < 7'd67) link_ctr <= link_ctr + 7'd1;
                    end
                end
            endcase

            if (dl_reset)        ref_down_latched <= 1'b0;
            else if (!ref_link)  ref_down_latched <= 1'b1;
        end
    end

endmodule
