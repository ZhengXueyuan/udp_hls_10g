// CLEAN B: identical to PATH_a_implicit but `mid` IS declared.
module sub64 (input clk, input [63:0] d, output reg [63:0] q);
  always @(posedge clk) q <= d;
endmodule

module PATH_b_clean (input clk, input [63:0] din, output [63:0] dout);
  wire [63:0] mid;
  sub64 u_mid (.clk(clk), .d(din), .q(mid));
  sub64 u_out (.clk(clk), .d(mid), .q(dout));
endmodule

module PATH_b_clean_expr (input clk, input [63:0] din, input pay_sel, output reg [63:0] dout);
  always @(posedge clk) dout <= {64{pay_sel}} & din;
endmodule
