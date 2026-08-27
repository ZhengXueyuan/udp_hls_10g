`timescale 1ns/1ps
// tcp_cam + tcb 合并 TB: 固定向量 + 自检 (MISMATCH 计数), 末尾 ALL_OK / FAIL。
module tb_tcp_cam_tcb;

    reg        clk, rst_n;
    reg        cfg_wr;
    reg [3:0]  cfg_addr;
    reg [31:0] cfg_sip, cfg_dip;
    reg [15:0] cfg_sport, cfg_dport;
    reg [31:0] q_sip, q_dip;
    reg [15:0] q_sport, q_dport;
    wire [3:0] q_id;
    wire       q_hit;

    reg [3:0]  ra_id, rb_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd, ra_snd_wnd;
    wire [3:0]  ra_state;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    reg        upd_wr;
    reg [3:0]  upd_id;
    reg [2:0]  upd_sel;
    reg [31:0] upd_val;

    integer    errs;
    integer    step;

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cfg_wr), .cfg_addr(cfg_addr),
        .cfg_sip(cfg_sip), .cfg_dip(cfg_dip),
        .cfg_sport(cfg_sport), .cfg_dport(cfg_dport),
        .q_sip(q_sip), .q_dip(q_dip), .q_sport(q_sport), .q_dport(q_dport),
        .q_id(q_id), .q_hit(q_hit)
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(ra_id), .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt),
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(ra_snd_wnd),
        .ra_state(ra_state),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .upd_wr(upd_wr), .upd_id(upd_id), .upd_sel(upd_sel), .upd_val(upd_val)
    );

    always #4 clk = ~clk;

    task chk;
        input [511:0] name;
        input ok;
        begin
            if (!ok) begin
                errs = errs + 1;
                $display("MISMATCH @step %0d: %0s", step, name);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; errs = 0; step = 0;
        cfg_wr = 0; cfg_addr = 0; cfg_sip = 0; cfg_dip = 0;
        cfg_sport = 0; cfg_dport = 0;
        q_sip = 0; q_dip = 0; q_sport = 0; q_dport = 0;
        ra_id = 0; rb_id = 0;
        upd_wr = 0; upd_id = 0; upd_sel = 0; upd_val = 0;
        #200; rst_n = 1;
        @(posedge clk);

        // ---- CAM 配置 3 条 ----
        cfg_wr = 1; cfg_addr = 0;
        cfg_sip = 32'h0A000001; cfg_dip = 32'hC0A86402;
        cfg_sport = 16'h3039; cfg_dport = 16'h1F90;
        @(posedge clk); step = step + 1;
        cfg_addr = 1;
        cfg_sip = 32'h0A000002; cfg_dip = 32'hC0A86402;
        cfg_sport = 16'h4000; cfg_dport = 16'h1F91;
        @(posedge clk); step = step + 1;
        cfg_addr = 15;
        cfg_sip = 32'h0A00000F; cfg_dip = 32'hC0A86402;
        cfg_sport = 16'h5000; cfg_dport = 16'h1F92;
        @(posedge clk); step = step + 1;
        cfg_wr = 0;
        @(posedge clk); step = step + 1;

        // ---- CAM 查询 ----
        q_sip = 32'h0A000001; q_dip = 32'hC0A86402;
        q_sport = 16'h3039; q_dport = 16'h1F90;
        #1;
        chk("cam hit0", q_hit && q_id == 4'd0);
        q_sip = 32'h0A00000F; q_dip = 32'hC0A86402;
        q_sport = 16'h5000; q_dport = 16'h1F92;
        #1;
        chk("cam hit15", q_hit && q_id == 4'd15);
        q_sport = 16'h3038;   // 端口差 1 -> 未命中
        #1;
        chk("cam miss", !q_hit);
        q_sip = 32'hDEADBEEF;
        #1;
        chk("cam miss2", !q_hit);
        @(posedge clk); step = step + 1;

        // ---- TCB 更新 + 双读 ----
        upd_wr = 1; upd_id = 3; upd_sel = 0; upd_val = 32'h12345678;
        @(posedge clk); step = step + 1;
        upd_sel = 1; upd_val = 32'hDEAD0001;
        @(posedge clk); step = step + 1;
        upd_sel = 3; upd_val = 32'h0000F000;   // rcv_wnd
        @(posedge clk); step = step + 1;
        upd_wr = 0;
        @(posedge clk); step = step + 1;
        ra_id = 3; rb_id = 0;
        #1;
        chk("tcb ra rcv_nxt", ra_rcv_nxt == 32'h12345678);
        chk("tcb ra snd_nxt", ra_snd_nxt == 32'hDEAD0001);
        chk("tcb ra rcv_wnd", ra_rcv_wnd == 16'hF000);
        chk("tcb rb zero", rb_rcv_nxt == 32'h0 && rb_snd_nxt == 32'h0);
        ra_id = 0; rb_id = 3;
        #1;
        chk("tcb rb 读同一条", rb_rcv_nxt == 32'h12345678);
        @(posedge clk); step = step + 1;

        if (errs == 0) $display("ALL_OK steps=%0d", step);
        else $display("FAIL errs=%0d", errs);
        $finish;
    end
endmodule
