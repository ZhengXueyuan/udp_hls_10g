//======================================================================
// p7a_bit_sync.v -- P7a: W independent single-bit level synchronisers
//======================================================================
//
//  Two flops, ASYNC_REG tagged so the placer clusters them into one slice.
//  Use it for LEVELS that change slowly or once (match/lock indicators, a
//  valid flag, a live sample) -- NOT for multi-bit values that change while
//  being read, and NOT for events (use p7a_tgl_sync.v for those).
//
//  The W bits are INDEPENDENT signals, not a bus: each bit is its own CDC and
//  there is no coherence requirement between them (they are status flags).
//  The one multi-bit value routed through this module -- the captured 6-bit
//  header reference -- is a multi-cycle-path value: it is written once per
//  measurement window and never changes while the host is looking, which is
//  what makes the crossing safe. That property is documented at the
//  instantiation site, not assumed here.
//======================================================================

`timescale 1ns / 1ps

module p7a_bit_sync #(
    parameter integer W = 1
)(
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);

    (* ASYNC_REG = "TRUE" *) reg [W-1:0] s0 = {W{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] s1 = {W{1'b0}};

    always @(posedge clk) begin
        s0 <= d;
        s1 <= s0;
    end

    assign q = s1;

endmodule
