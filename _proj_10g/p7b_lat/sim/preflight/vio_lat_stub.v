// 仅用于 xvlog/xelab 前置 lint 的 VIO 替身 (位宽与 build tcl 里的 vio_lat 一致)
module vio_lat (
    input  wire         clk,
    input  wire [127:0] probe_in0,
    input  wire [127:0] probe_in1,
    input  wire [127:0] probe_in2,
    input  wire [127:0] probe_in3,
    input  wire [127:0] probe_in4,
    input  wire [127:0] probe_in5,
    output wire [0:0]   probe_out0,
    output wire [0:0]   probe_out1,
    output wire [3:0]   probe_out2,
    output wire [7:0]   probe_out3,
    output wire [15:0]  probe_out4,
    output wire [1:0]   probe_out5
);
    assign probe_out0 = 1'b0; assign probe_out1 = 1'b0;
    assign probe_out2 = 4'd0; assign probe_out3 = 8'd0;
    assign probe_out4 = 16'd0; assign probe_out5 = 2'd0;
endmodule
