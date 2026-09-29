// W1: width mismatch with the net PROPERLY DECLARED (no implicit net).
// Probe: does xvlog itself ever emit VRFC 10-3091 (project already greps it in xvlog logs)?
module subW (input clk, input [63:0] d, output reg [63:0] q);
  always @(posedge clk) q <= d;
endmodule

module W1_widthmis (input clk, input [63:0] din, output [63:0] dout);
  wire [0:0] narrow;                 // DECLARED, 1 bit -- legal code, wrong width
  assign narrow = din[0];
  subW u_a (.clk(clk), .d(din),    .q());
  subW u_b (.clk(clk), .d(narrow), .q(dout));
endmodule
