// ============================================================================
// obs_util.v -- three tiny building blocks for the xxv_loop observation path.
//
//   cdc_sync2   : 2-flop synchroniser for a LEVEL (one bit).
//   snap_hold   : multi-bit snapshot latch with a toggle handshake, so a
//                 counter living in clock domain A can be read from clock
//                 domain B WITHOUT the classic multi-bit CDC hazard
//                 ("bit-mixed" reads).  The value is registered in the SOURCE
//                 domain and only replaced when a request arrives, and the
//                 request is acknowledged in the OBSERVER domain -- so by the
//                 time the observer sees the ack, the data has been stable for
//                 at least one full source clock plus the two sync stages.
//   obs_reg     : one register in the observer domain.  Every VIO probe_in net
//                 is registered here, so the VIO's own sampling flops only ever
//                 see same-domain logic (keeps the timing report clean and puts
//                 the cross-domain path under one constrainable cell name).
//
// Project rule honoured here: a multi-bit value NEVER crosses a clock boundary
// through two flops; it crosses through a holding register plus a handshake.
// ============================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------- cdc_sync2
module cdc_sync2 (
    input  wire clk,
    input  wire d,
    output wire q
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sr;
    always @(posedge clk) sr <= {sr[0], d};
    assign q = sr[1];
endmodule

// ---------------------------------------------------------------- snap_hold
module snap_hold #(
    parameter integer W = 32
) (
    input  wire         src_clk,
    input  wire         obs_clk,
    input  wire         obs_req,     // toggle, launched in the obs domain
    output wire         obs_ack,     // toggle, synchronised back to the obs domain
    output wire         obs_gen,     // one obs_clk pulse per serviced request
    input  wire [W-1:0] din,
    output wire [W-1:0] dout
);
    // request synchronised into the source domain + edge detect
    wire req_s;
    cdc_sync2 u_req (.clk(src_clk), .d(obs_req), .q(req_s));
    reg req_d;
    reg [W-1:0] hold;
    reg         ack_tgl;

    always @(posedge src_clk) begin
        req_d <= req_s;
        if (req_s != req_d) begin
            hold    <= din;
            ack_tgl <= ~ack_tgl;
        end
    end
    assign dout = hold;

    // acknowledge synchronised back into the observer domain
    wire ack_s;
    cdc_sync2 u_ack (.clk(obs_clk), .d(ack_tgl), .q(ack_s));
    reg ack_d;
    always @(posedge obs_clk) begin
        ack_d <= ack_s;
    end
    assign obs_ack = ack_s;
    assign obs_gen = ack_s ^ ack_d;
endmodule

// ------------------------------------------------------------------ obs_reg
module obs_reg #(
    parameter integer W = 32
) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    reg [W-1:0] r;
    always @(posedge clk) r <= d;
    assign q = r;
endmodule
