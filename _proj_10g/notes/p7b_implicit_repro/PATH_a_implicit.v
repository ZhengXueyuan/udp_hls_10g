// PATHOLOGICAL A: real implicit net.
// `mid` is NEVER declared -> Verilog implicit 1-bit wire -> 64-bit path silently truncated.
module sub64 (input clk, input [63:0] d, output reg [63:0] q);
  always @(posedge clk) q <= d;
endmodule

module PATH_a_implicit (input clk, input [63:0] din, output [63:0] dout);
  // A1: undeclared net used as a PORT CONNECTION
  sub64 u_mid (.clk(clk), .d(din),  .q(mid));
  sub64 u_out (.clk(clk), .d(mid),  .q(dout));
endmodule

// A2: undeclared identifier used INSIDE AN EXPRESSION (separate module on purpose)
module PATH_a_implicit_expr (input clk, input [63:0] din, output reg [63:0] dout);
  always @(posedge clk) dout <= pay_sel & din;
endmodule
