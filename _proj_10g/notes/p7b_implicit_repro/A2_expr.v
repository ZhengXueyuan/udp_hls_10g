// A2: implicit net used INSIDE AN EXPRESSION only.
module A2_expr (input clk, input [63:0] din, output reg [63:0] dout);
  always @(posedge clk) dout <= pay_sel & din;   // `pay_sel` never declared
endmodule
