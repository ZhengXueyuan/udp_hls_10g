`timescale 1ns/1ps
// ===========================================================================
// tb_rate_rxc -- rx_classify v2 写侧接受速率核算 TB (独立核算; 只读)
// ---------------------------------------------------------------------------
// 问题 (任务书点名): v2 的**写侧**是"每拍灌一个字"还是"每帧灌一个字"?
// 方法: 饱和写侧源 (每拍 present 一个字, 零气泡, 背靠背帧) + 两条路由 ready=1,
//       量 WINDOW 窗内 words_in 与 cycles 的关系 + stall 计数 + 丢字自检计数。
// 判据 (打印 "RXC " 前缀):
//   IN_PER_CYCLE_X1000 == 1000  => 写侧稳态 1 字/拍 (零死拍)
//   STALL == 0 && OVF == 0 && RQ_OVF == 0
// plusarg: FW  = 每帧字数 (默认 8 = 最小帧内容 60B 的 8 字),
//          TCP = 1 走 fast(TCP) 路由 / 0 走 slow 路由, CYCLES = 窗拍数
// ===========================================================================
module tb_rate_rxc;

    reg  clk, rst_n;
    integer fw_i, run_cycles, tcp_mode;

    always #3.2 clk = ~clk;          // 156.25 MHz

    // ---- 饱和帧流源: 每拍 1 字, 背靠背帧 --------------------------------
    reg  [15:0] widx;
    reg  [31:0] fcnt;
    wire [3:0]  widx_nxt = (widx == fw_i[15:0] - 16'd1) ? 4'd0 : (widx[3:0] + 4'd1);
    wire        cur_last = (widx == fw_i[15:0] - 16'd1);
    wire        cur_sop  = (widx == 16'd0);
    // 帧内容: w1[31:16] = 0x0800 (IPv4) 让分类看 w2; w2[7:0] = 协议号 (低位!)
    wire [63:0] cur_data = cur_sop                  ? 64'hAABBCCDDEEFF0000 :
                           (widx == 16'd1)          ? 64'h1122334408004500 :
                           (widx == 16'd2)          ? {48'h0, 8'h00, tcp_mode ? 8'd6 : 8'd17} :
                                                      // w5 的 flags[2:0] 必须为 0 才走 FAST 路由
                                                      64'h5A5A5A5A5A5A5A00;
    wire [7:0]  cur_keep = 8'hFF;
    wire        s_ready;
    wire        s_acc = s_ready;     // tvalid 恒 1 (饱和)
    reg  [31:0] acc_cnt;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            widx <= 16'd0; fcnt <= 32'd0; acc_cnt <= 32'd0;
        end else if (s_acc) begin
            acc_cnt <= acc_cnt + 32'd1;
            if (cur_last) begin
                widx <= 16'd0; fcnt <= fcnt + 32'd1;
            end else widx <= widx + 16'd1;
        end

    // ---- DUT --------------------------------------------------------------
    wire [63:0] f_tdata, s_tdata;
    wire [7:0]  f_tkeep, s_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    wire [31:0] st_fast, st_slow, win_words, wout_words, ovf, rq_ovf, stall;
    wire [4:0]  occ;

    rx_classify u_rxc (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(cur_data), .s_axis_tkeep(cur_keep),
        .s_axis_tvalid(1'b1), .s_axis_tready(s_ready), .s_axis_tlast(cur_last),
        .s_axis_tuser(cur_sop), .s_axis_tcrs(1'b1), .s_axis_terr(1'b0),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep), .m_fast_tvalid(f_tvalid),
        .m_fast_tready(f_tready), .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(s_tdata), .m_slow_tkeep(s_tkeep), .m_slow_tvalid(s_tvalid),
        .m_slow_tready(s_tready), .m_slow_tlast(s_tlast), .m_slow_tuser(s_tuser),
        .m_slow_tcrs(s_tcrs), .m_slow_terr(s_terr),
        .stat_fast(st_fast), .stat_slow(st_slow),
        .dbg_stat_words_in(win_words), .dbg_stat_words_out(wout_words),
        .dbg_stat_ovf(ovf), .dbg_stat_route_ovf(rq_ovf),
        .dbg_stat_stall_in(stall), .dbg_occ(occ)
    );

    assign f_tready = 1'b1;     // 两条路由都恒 ready (最乐观消费者)
    assign s_tready = 1'b1;

    reg  [31:0] c0_in, c0_out, c0_stall, c0_fast, c0_slow;
    integer     c;

    initial begin
        clk = 0; rst_n = 0;
        fw_i = 8; run_cycles = 20000; tcp_mode = 1;
        if (!$value$plusargs("FW=%d", fw_i))     fw_i = 8;
        if (!$value$plusargs("CYCLES=%d", run_cycles)) run_cycles = 20000;
        if (!$value$plusargs("TCP=%d", tcp_mode))      tcp_mode = 1;
        $display("RXC FW=%0d TCP=%0d CYCLES=%0d", fw_i, tcp_mode, run_cycles);
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (2000) @(posedge clk);       // 预热 (填管线)
        c0_in = win_words; c0_out = wout_words; c0_stall = stall;
        c0_fast = st_fast; c0_slow = st_slow;
        repeat (run_cycles) @(posedge clk);
        $display("RXC CYCLES=%0d", run_cycles);
        $display("RXC WORDS_IN=%0d", win_words - c0_in);
        $display("RXC WORDS_OUT=%0d", wout_words - c0_out);
        $display("RXC FRAMES_FAST=%0d FRAMES_SLOW=%0d", st_fast - c0_fast, st_slow - c0_slow);
        $display("RXC IN_PER_CYCLE_X1000=%0d", ((win_words - c0_in) * 1000) / run_cycles);
        $display("RXC OUT_PER_CYCLE_X1000=%0d", ((wout_words - c0_out) * 1000) / run_cycles);
        $display("RXC STALL=%0d OVF=%0d RQ_OVF=%0d OCC_END=%0d",
                 stall - c0_stall, ovf, rq_ovf, occ);
        $finish;
    end

endmodule
