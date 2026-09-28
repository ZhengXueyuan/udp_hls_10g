`timescale 1ns/1ps
// tb_t3.v - flip <-> update 配对诊断: 自动反复请求跑 200 次, 抓"flip 无对应 update"
module tb_t3;
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
    integer p0, p1;

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
    always @(negedge clk_b) din_b <= {24'h120000 + din_b[23:0], 8'd0};

    wire dbg_tog = u_dut.toggle_a;
    wire dbg_ack = u_dut.ack_b;
    wire dbg_done = u_dut.done_a;
    wire [2:0] dbg_tsb = u_dut.tog_sync_b;
    wire dbg_upd = u_dut.update_b;

    integer nf = 0, nu = 0, nv = 0, n_anom = 0;
    reg tog_prev = 0;
    reg trace = 0;

    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) begin tog_prev <= 0; end
        else begin
            if (dbg_tog !== tog_prev) begin
                nf = nf + 1;
                if (nf - nu > 1) begin
                    n_anom = n_anom + 1;
                    $display("!! FLIP-超前 t=%0t nf=%0d nu=%0d busy=%b tsb=%b tog=%b",
                             $time, nf, nu, busy_a, dbg_tsb, dbg_tog);
                end
                tog_prev <= dbg_tog;
            end
            if (valid_a) nv = nv + 1;
            if (trace)
                $display("   t=%-8d req=%b busy=%b done=%b valid=%b tog=%b ack=%b tsb=%b upd=%b | nf=%0d nu=%0d nv=%0d",
                         $time, req_a, busy_a, dbg_done, valid_a, dbg_tog, dbg_ack, dbg_tsb, dbg_upd, nf, nu, nv);
        end
    end
    always @(posedge clk_b) begin
        if (dbg_upd) begin
            nu = nu + 1;
            if (nu > nf) begin
                n_anom = n_anom + 1;
                $display("!! UPDATE-超前 t=%0t nf=%0d nu=%0d", $time, nf, nu);
            end
        end
    end

    initial begin
        $display("=== tb_t3: flip/update 配对诊断 ===");
        req_mode = 3;
        repeat (4) @(posedge clk_b);
        rst_n = 1;
        repeat (4) @(posedge clk_a);
        $display("  [t] initial 块内的 $time = %0d (此时应 ~ 数十 ns)", $time);
        dump_unit;
        req_mode = 0;
        i = 0;
        while (nv < 200 && i < 200000) begin @(negedge clk_a); i = i + 1; end
        $display("  [t] 200 次 valid 后 t=%0d nf=%0d nu=%0d nv=%0d (迭代 %0d)", $time, nf, nu, nv, i);
        $display("  --- 停请求 t=%0d ---", $time);
        @(posedge clk_a);
        req_mode = 3;
        trace = 1;
        repeat (30) @(posedge clk_a);
        trace = 0;
        $display("  [t] 停请求 30 拍后 t=%0d busy=%b done=%b tog=%b ack=%b tsb=%b nf=%0d nu=%0d nv=%0d",
                 $time, busy_a, dbg_done, dbg_tog, dbg_ack, dbg_tsb, nf, nu, nv);
        $display("  [结果] nf=%0d nu=%0d nv=%0d 异常=%0d", nf, nu, nv, n_anom);
        if (n_anom == 0 && nf == nu && nu == nv)
            $display("PAIR_OK: flips == updates == valids, 无异常");
        else
            $display("PAIR_BAD: 见上");
        $display("=== done ===");
        $finish;
    end
    task dump_unit;
        begin
            $display("  [t] task 内的 $time = %0d (与上面 initial 的对比即可知单位)", $time);
        end
    endtask
    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
