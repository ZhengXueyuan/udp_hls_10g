// probe_design.v -- P6b 最小探针顶层: clk_gen_p6b + 一个 clk_dp 域计数器
// 目的: 让 T25/U25 -> IBUFDS -> MMCME4_BASE -> BUFG 这条链路真正经过
//       synth / opt / place / route, 从而拿到 DRC + 时钟报告 + 时序读数。
// 只用一个输出脚 (led_locked, H9/Aurora_LED), 把两个域的信号异或出去。
module probe_design (
    input  wire clk_p,
    input  wire clk_n,
    output wire led_locked
);
    wire clk_dp;
    wire clk_ref;
    wire locked;
    wire rst_dp;

    clk_gen_p6b #(
        .SIM_BYPASS       (0),
        .CLKIN1_PERIOD_NS (10.000),
        .CLKFBOUT_MULT_F  (12.500),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (8.000)
    ) u_clkgen (
        .clk_p      (clk_p),
        .clk_n      (clk_n),
        .rst_ext    (1'b0),
        .clk_dp     (clk_dp),
        .clk_in_100 (clk_ref),
        .locked     (locked),
        .rst_dp     (rst_dp)
    );

    reg [24:0] cnt;
    always @(posedge clk_dp) begin
        if (rst_dp) cnt <= 25'd0;
        else        cnt <= cnt + 25'd1;
    end

    // 两个域都扇出到同一个脚, 保证时钟网络不被裁掉
    assign led_locked = locked ^ cnt[24] ^ clk_ref;

endmodule
