// C1: UNRELATED-WARNING control -- no implicit net, but benign warnings present.
// Deliberately: undriven-but-unused net, unused register, width mismatch.
module C1_benign (input clk, input a, input [3:0] b4, output reg [63:0] dout);
  wire unused_net;                      // never driven, never read
  reg [63:0] unused_reg;                // written, never read
  reg [7:0]  narrow;
  wire [63:0] wide_from_narrow;
  assign wide_from_narrow = {60'b0, b4};   // 4 -> 64 width adaptation
  always @(posedge clk) begin
    unused_reg <= dout ^ 64'h1;
    narrow     <= a;                       // 1 -> 8 width adaptation
  end
  always @(posedge clk) dout <= wide_from_narrow;
endmodule
