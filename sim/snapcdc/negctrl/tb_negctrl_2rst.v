`timescale 1ns/1ps
//=============================================================================
// tb_negctrl_2rst.v — 实测"两个域各用各的复位"会不会把握手永久卡死
//   场景: ① 请求发出 (toggle_a=1, 在飞) → ② **只**复位 b 域 (a 域继续跑)
//         → ③ 释放 b 域复位 → ④ 等足够久, 看 busy_a 会不会自己下来
//   预期 (被检验的论断): ack_b 被清 0 而 toggle_a 仍是 1 ⇒ done_a 永为真不了 ⇒ busy 挂死。
//   若本 TB 打印 FAIL, 说明正式版注释里那条论断是错的, 必须改注释。
//=============================================================================
module tb_negctrl_2rst;
    parameter W = 32, NW = 6, NB = NW*W;
    reg clk_a = 0, clk_b = 0;
    reg rst_a_n = 0, rst_b_n = 0;
    always #2 clk_a = ~clk_a;
    always #4 clk_b = ~clk_b;

    reg  [NB-1:0] din_b;
    reg           req_a;
    wire          busy_a, valid_a;
    wire [NB-1:0] dout_a;
    integer n_valid = 0, fails = 0, i;

    snap_cdc_2rst #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_a_n(rst_a_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b), .rst_b_n(rst_b_n), .din_b(din_b)
    );

    always @(posedge clk_a) if (valid_a) n_valid = n_valid + 1;

    initial begin
        $display("=== negctrl: 两个域各用各的复位 (旧结构) ===");
        din_b = {NW{32'h0A0B0C0D}}; req_a = 0;
        repeat (4) @(posedge clk_b);
        rst_a_n = 1; rst_b_n = 1;
        repeat (4) @(posedge clk_a);

        // 请求发出, 让它飞出去 (还没回来)
        @(negedge clk_a); req_a = 1; @(negedge clk_a); req_a = 0;
        repeat (2) @(posedge clk_a);
        if (!busy_a) begin $display("  [FAIL] 前置: busy 没拉高, 场景没成立"); fails = fails + 1; end

        // **只复位 b 域** (a 域照常跑) —— 这就是"两域复位不同步"
        rst_b_n = 0;
        repeat (4) @(posedge clk_b);
        rst_b_n = 1;
        $display("  [INFO] b 域复位已释放, 现在看 busy_a 能否自己下来 ...");

        for (i = 0; i < 200; i = i + 1) @(negedge clk_a);   // 等 200 个 a 拍 (远超 6 拍往返)
        if (busy_a) begin
            $display("  [RESULT] busy_a **永久挂死** (等了 200 拍仍为高, valid 次数 %0d)", n_valid);
            $display("NEGCTRL CONFIRMED: 两域复位不同步 ⇒ 握手死锁 ⇒ 正式版改成同源复位是必要的");
        end
        else begin
            $display("  [RESULT] busy_a 自己恢复了 (valid 次数 %0d)", n_valid);
            $display("NEGCTRL REFUTED: 旧结构并不会死锁 ⇒ rtl/snap_cdc.v 头注释里那条论断是错的, 必须改");
        end
        $display("=== done ===");
        $finish;
    end
    initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
