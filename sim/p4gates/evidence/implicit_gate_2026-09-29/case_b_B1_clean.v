// B1: CLEAN control -- identical topology to A1, but `mid` IS declared.
module sub64 (input clk, input [63:0] d, output reg [63:0] q);
  always @(posedge clk) q <= d;
endmodule

module B1_clean (input clk, input [63:0] din, output [63:0] dout);
  wire [63:0] mid;
  sub64 u_mid (.clk(clk), .d(din), .q(mid));
  sub64 u_out (.clk(clk), .d(mid), .q(dout));
endmodule
