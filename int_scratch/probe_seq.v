`timescale 1ns/1ps
module probe_seq;
  reg clk_axi=0, clk_gmii=0, clk_dp=0;
  always #2.0 clk_axi=~clk_axi;
  always #4.0 clk_gmii=~clk_gmii;
  always #3.2 clk_dp=~clk_dp;
  reg rst_n=0, req=0;
  wire busy, valid, req_fe, req_dp, busy_fe, busy_dp, valid_fe, valid_dp;
  wire [1:0] dbg;
  wire [13*32-1:0] fe_o; wire [21*32-1:0] dp_o;
  wire [35*32-1:0] dout;
  wire [31:0] t_fe, t_dp;
  wire [13*32-1:0] fe_src = {(14*32){1'b1}};
  wire [21*32-1:0] dp_src = {(22*32){1'b0}};
  fake_cdc #(.W(14),.LAG_B(3),.LAG_A(2)) uf (.clk_a(clk_axi),.rst_n_a(rst_n),.req_a(req_fe),.busy_a(busy_fe),.dout_a(fe_o),.valid_a(valid_fe),.clk_b(clk_gmii),.rst_n_b(rst_n),.din_b(fe_src),.t_cap_b(t_fe),.gen_b());
  fake_cdc #(.W(22),.LAG_B(1),.LAG_A(1)) ud (.clk_a(clk_axi),.rst_n_a(rst_n),.req_a(req_dp),.busy_a(busy_dp),.dout_a(dp_o),.valid_a(valid_dp),.clk_b(clk_dp),.rst_n_b(rst_n),.din_b(dp_src),.t_cap_b(t_dp),.gen_b());
  snap_seq #(.FW(14),.DW(22)) dut (.clk(clk_axi),.rst_n(rst_n),.req(req),.busy(busy),.dout(dout),.valid(valid),.fe_state(),.dbg_state(dbg),
     .req_fe(req_fe),.busy_fe(busy_fe),.valid_fe(valid_fe),.dout_fe(fe_o),
     .req_dp(req_dp),.busy_dp(busy_dp),.valid_dp(valid_dp),.dout_dp(dp_o));
  initial begin
    repeat(8) @(posedge clk_axi); rst_n=1; repeat(4) @(posedge clk_axi);
    @(posedge clk_axi); req<=1; @(posedge clk_axi); req<=0;
    repeat(60) @(posedge clk_axi);
    $display("END dbg=%0d busy=%b valid=%b req_fe=%b busy_fe=%b valid_fe=%b req_dp=%b busy_dp=%b valid_dp=%b t_fe=%0d t_dp=%0d",
      dbg,busy,valid,req_fe,busy_fe,valid_fe,req_dp,busy_dp,valid_dp,t_fe,t_dp);
    $finish;
  end
  always @(posedge clk_axi) if (req_fe)  $display("[%0t] req_fe hi", $time);
  always @(posedge clk_axi) if (valid_fe)$display("[%0t] valid_fe hi", $time);
  always @(posedge clk_axi) if (req_dp)  $display("[%0t] req_dp hi", $time);
  always @(posedge clk_axi) if (valid_dp)$display("[%0t] valid_dp hi", $time);
  always @(posedge clk_axi) if (valid)   $display("[%0t] DUT valid", $time);
endmodule
