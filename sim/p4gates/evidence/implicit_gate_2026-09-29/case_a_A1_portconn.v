// A1: implicit net used as a PORT CONNECTION only (the P5e-T2 form / CLAUDE.md 坑 24).
module sub64 (input clk, input [63:0] d, output reg [63:0] q);
  always @(posedge clk) q <= d;
endmodule

module A1_portconn (input clk, input [63:0] din, output [63:0] dout);
  sub64 u_mid (.clk(clk), .d(din), .q(mid));   // `mid` never declared
  sub64 u_out (.clk(clk), .d(mid), .q(dout));
endmodule
