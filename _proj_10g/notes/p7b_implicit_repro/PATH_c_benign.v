// UNRELATED-WARNING C: no implicit net at all, but several benign warnings.
module PATH_c_benign (input clk, input a, output reg [63:0] dout);
  reg [63:0] unused_reg;      // warning family: unused / removed
  reg [7:0]  narrow;
  always @(posedge clk) begin
    unused_reg <= dout ^ 64'h1;
    narrow     <= a;          // width-mismatch family (1 -> 8 bits)
  end
  always @(posedge clk) dout <= {64{a}};
endmodule
