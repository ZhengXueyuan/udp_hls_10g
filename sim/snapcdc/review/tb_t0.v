`timescale 1ns/1ps
// tb_t0.v - 最小测量: 每次快照的真实往返仿真时间 (排除我的 TB 记账干扰)
module tb_t0;
    parameter W = 32, NW = 6, NB = NW*W;
    reg clk_a = 0, clk_b = 0;
    integer pa = 4, pb = 8;
    always #(pa/2.0) clk_a = ~clk_a;
    always #(pb/2.0) clk_b = ~clk_b;

    reg rst_n = 0;
    reg [NB-1:0] din_b = 0;
    wire busy_a, valid_a;
    wire [NB-1:0] dout_a;
    reg req_a;
    integer req_mode = 3, i;

    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b), .din_b(din_b)
    );
    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n)             req_a <= 1'b0;
        else if (req_mode == 0) req_a <= !busy_a;
        else                    req_a <= 1'b0;
    end

    wire dbg_tog = u_dut.toggle_a;
    wire dbg_upd = u_dut.update_b;
    wire dbg_ack = u_dut.ack_b;

    integer nv = 0, nf = 0, nu = 0;
    integer t_first_flip = 0, t_first_valid = 0;
    reg tog_prev = 0, upd_prev = 0;

    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) tog_prev <= 0;
        else begin
            if (dbg_tog !== tog_prev) begin
                nf = nf + 1;
                if (nf == 1) t_first_flip = $time;
                $display("  flip #%0d t=%0d busy=%b", nf, $time, busy_a);
                tog_prev <= dbg_tog;
            end
            if (valid_a) begin
                nv = nv + 1;
                if (nv == 1) t_first_valid = $time;
                if (nv <= 4 || nv % 50 == 0)
                    $display("  valid #%0d t=%0d (距首flip %0d) tag=%h busy=%b",
                             nv, $time, $time - t_first_flip, dout_a[23:0], busy_a);
            end
        end
    end
    always @(posedge clk_b) begin
        if (dbg_upd) begin
            nu = nu + 1;
            if (nu <= 4) $display("  update #%0d t=%0d ack_pre=%b", nu, $time, dbg_ack);
        end
    end

    initial begin
        $display("=== tb_t0: 往返时间实测 (timescale 1ns/1ps; pa=%0d pb=%0d) ===", pa, pb);
        req_mode = 3;
        repeat (4) @(posedge clk_b);
        rst_n = 1;
        repeat (4) @(posedge clk_a);
        $display("  [t] reset 释放完毕 t=%0d (应为 数十字节 ns 量级)", $time);
        req_mode = 0;
        i = 0;
        while (nv < 10 && i < 100000) begin @(negedge clk_a); i = i + 1; end
        $display("  [t] 10 次 valid 后 t=%0d  (迭代 %0d)", $time, i);
        i = 0;
        while (nv < 200 && i < 400000) begin @(negedge clk_a); i = i + 1; end
        $display("  [t] 200 次 valid 后 t=%0d (迭代 %0d) flips=%0d updates=%0d", $time, i, nf, nu);

        // 换慢 a 时钟
        pa = 100; pb = 8;
        repeat (20) @(posedge clk_a);
        $display("  [t] 切到 pa=100 后 t=%0d nv=%0d", $time, nv);
        i = 0;
        while (nv < 230 && i < 400000) begin @(negedge clk_a); i = i + 1; end
        $display("  [t] +30 次 valid 后 t=%0d (迭代 %0d) flips=%0d updates=%0d", $time, i, nf, nu);
        $display("=== done ===");
        $finish;
    end
    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
