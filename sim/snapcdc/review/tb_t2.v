`timescale 1ns/1ps
// tb_t2.v - 逐拍追踪: 自动请求运行中突然停止请求 (req_a -> 0) 时握手是否卡死
module tb_t2;
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
    integer tcost = 0;

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
    always @(negedge clk_b) din_b <= {24'h123400 + din_b[23:0], 8'd0};

    wire dbg_tog = u_dut.toggle_a;
    wire dbg_ack = u_dut.ack_b;
    wire dbg_done = u_dut.done_a;
    wire [2:0] dbg_asa = u_dut.ack_sync_a;
    wire [2:0] dbg_tsb = u_dut.tog_sync_b;
    wire dbg_upd = u_dut.update_b;

    integer nv = 0, nf = 0, nu = 0;
    reg tog_prev = 0;
    reg logging = 0;
    integer edge_no = 0;

    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) begin tog_prev <= 0; end
        else begin
            if (dbg_tog !== tog_prev) begin nf = nf + 1; tog_prev <= dbg_tog; end
            if (valid_a) nv = nv + 1;
            if (logging) begin
                edge_no = edge_no + 1;
                $display("  e%-3d t=%-6d req=%b busy=%b done=%b valid=%b tog=%b ack=%b asa=%b tsb=%b upd=%b | nf=%0d nv=%0d nu=%0d",
                    edge_no, $time, req_a, busy_a, dbg_done, valid_a, dbg_tog, dbg_ack,
                    dbg_asa, dbg_tsb, dbg_upd, nf, nv, nu);
            end
        end
    end
    always @(posedge clk_b) if (dbg_upd) nu = nu + 1;

    initial begin
        $display("=== tb_t2: 停止请求瞬间的逐拍追踪 ===");
        req_mode = 3;
        repeat (4) @(posedge clk_b);
        rst_n = 1;
        repeat (4) @(posedge clk_a);
        // 测时钟周期
        @(posedge clk_a); tcost = $time;
        @(posedge clk_a); $display("  [t] clk_a 周期实测 = %0d (pa 设 %0d)", $time - tcost, pa);
        req_mode = 0;
        i = 0;
        while (nv < 20 && i < 20000) begin @(negedge clk_a); i = i + 1; end
        $display("  [t] 20 次 valid 后 t=%0d nf=%0d nv=%0d nu=%0d", $time, nf, nv, nu);

        // 从 clk_a posedge 同步停请求, 逐拍看 40 拍
        @(posedge clk_a);
        $display("  --- 停请求 (req_mode=3) t=%0d ---", $time);
        req_mode = 3;
        logging = 1;
        repeat (40) @(posedge clk_a);
        logging = 0;
        $display("  [t] 停请求 40 拍后 t=%0d busy=%b done=%b nf=%0d nv=%0d nu=%0d",
                 $time, busy_a, dbg_done, nf, nv, nu);

        // 再开请求, 看能否恢复
        $display("  --- 重开请求 t=%0d ---", $time);
        req_mode = 0;
        logging = 1;
        repeat (30) @(posedge clk_a);
        logging = 0;
        i = 0;
        while (nv < 23 && i < 20000) begin @(negedge clk_a); i = i + 1; end
        $display("  [t] 重开后 t=%0d nf=%0d nv=%0d nu=%0d busy=%b", $time, nf, nv, nu, busy_a);
        $display("=== done ===");
        $finish;
    end
    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
