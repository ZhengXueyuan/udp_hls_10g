`timescale 1ns/1ps
//=============================================================================
// tb_skew.v — 判决实验: 源位束带**位间偏斜** + 时钟非整比 (4ns : 9ns)
//   动机: 零延迟仿真里"多比特直通"(dout_a <= din_b)天然相干 ⇒ 单元门看不出它坏。
//         真实危害来自采样沿与 b 域跳变沿**异步**时的位间偏斜。
//   本 TB 的源: 每 b 拍在 clk_b negedge 更新, 但每字晚 j*0.5ns 落地 (总展开 2.5ns,
//         仍在下一个 b posedge 之前稳定) —— 这正是"b 域寄存器 + 布线偏斜"的行为模型。
//   clk_a 4ns / clk_b 9ns ⇒ a 沿相对 b 沿**滑动** ⇒ 必然有 a 沿落进跳变窗。
//   期望: 真 RTL (在 b posedge 一次性锁存) ⇒ 零位混;
//         m2_direct 变体 (dout_a 直采 din_b) ⇒ 必然抓到位混。
//   跑法: 同一 TB, 分别链接 rtl/snap_cdc.v 与 mut/m2_direct.v。
//=============================================================================
module tb_skew;
    parameter W = 32, NW = 6, NB = NW*W;
    reg clk_a = 0, clk_b = 0;
    always #2.0 clk_a = ~clk_a;      // 4ns
    always #4.55 clk_b = ~clk_b;     // 9.1ns (与 a **非整比**: 相位滑动)

    reg rst_n = 0;
    reg [NB-1:0] din_b = 0;
    wire busy_a, valid_a;
    wire [NB-1:0] dout_a;
    reg req_a;
    integer gen = 0, i;

    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b), .din_b(din_b)
    );
    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) req_a <= 1'b0;
        else        req_a <= !busy_a;          // 自动反复请求
    end

    // ---- 源: 每 b 拍整代更新, 但**逐字带偏斜** (0.0 / 0.5 / ... / 2.5 ns) ----
    always @(negedge clk_b) begin
        gen = gen + 1;
        din_b[0*W +: W] <= #0.0 {gen[23:0], 8'd0};
        din_b[1*W +: W] <= #0.5 {gen[23:0], 8'd1};
        din_b[2*W +: W] <= #1.0 {gen[23:0], 8'd2};
        din_b[3*W +: W] <= #1.5 {gen[23:0], 8'd3};
        din_b[4*W +: W] <= #2.0 {gen[23:0], 8'd4};
        din_b[5*W +: W] <= #2.5 {gen[23:0], 8'd5};
    end

    integer nv = 0, nmix = 0, nidx = 0;
    reg [NB-1:0] cap;
    integer k;
    reg [23:0] t0, tk;
    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) begin nv = 0; end
        else if (valid_a) begin
            nv = nv + 1;
            cap = dout_a;
            t0 = cap[8 +: 24];
            for (k = 0; k < NW; k = k + 1) begin
                tk = cap[k*W + 8 +: 24];
                if (tk !== t0) begin
                    nmix = nmix + 1;
                    if (nmix <= 3)
                        $display("  [MIX] #%0d t=%0t tags=%h %h %h %h %h %h", nv, $time,
                            cap[0*W+:W], cap[1*W+:W], cap[2*W+:W],
                            cap[3*W+:W], cap[4*W+:W], cap[5*W+:W]);
                    k = NW;                      // 一次快照只报一次
                end
            end
            for (k = 0; k < NW; k = k + 1)
                if (cap[k*W +: 8] !== k[7:0]) nidx = nidx + 1;
        end
    end

    initial begin
        $display("=== tb_skew: 源位间偏斜 + 非整比时钟 (clk_a 4ns / clk_b 9ns) ===");
        repeat (6) @(posedge clk_b);
        rst_n = 1;
        i = 0;
        while (nv < 400 && i < 200000) begin @(negedge clk_a); i = i + 1; end
        $display("  [结果] valid=%0d 位混=%0d 字序号错=%0d", nv, nmix, nidx);
        if (nmix == 0) $display("SKEW_RESULT: 零位混 (在 b 沿一次性锁存 ⇒ 抗位间偏斜)");
        else           $display("SKEW_RESULT: 抓到 %0d 次位混 (采样沿落进跳变窗 ⇒ 无锁存保护)", nmix);
        $display("=== done ===");
        $finish;
    end
    initial begin #2000000; $display("TIMEOUT"); $finish; end
endmodule
