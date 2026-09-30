`timescale 1ns/1ps
// ===========================================================================
// tb_rate_mac -- mac_tx_10g 每帧 XGMII 拍数核算 TB (独立核算; 只读)
// ---------------------------------------------------------------------------
// 方法: 饱和帧源 (每拍 1 字, **背靠背**: 上一帧末字的下一拍就是下一帧首字)
//       -> mac_tx_10g -> XGMII (无消费者, MAC 每拍必发 1 个 XGMII 字)。
// 量: 窗内 frames 与 cycles => CYCLES_PER_FRAME (= 帧占用的 XGMII 拍数)。
//   线侧预算 = 8(前导组) + L(内容) + 4(FCS) + 12(IFG) 字节; 效率 = 预算/8/拍数。
// plusarg: L = 帧内容字节数 (默认 60 = 最小帧), CYCLES = 窗拍数
// ===========================================================================
module tb_rate_mac;

    reg  clk, rst_n;
    integer l_i, run_cycles;
    integer nw_i;

    always #3.2 clk = ~clk;          // 156.25 MHz

    // ---- 饱和帧源 --------------------------------------------------------
    reg  [15:0] widx;
    wire        cur_last = (widx == nw_i[15:0] - 16'd1);
    wire [63:0] cur_data = {8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'hEE, 8'hFF, widx[7:0], widx[15:8]};
    wire [7:0]  cur_keep = (cur_last && ((l_i % 8) != 0))
                           ? (8'hFF << (8 - (l_i % 8))) : 8'hFF;
    wire        s_ready;
    wire        s_acc = s_ready;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) widx <= 16'd0;
        else if (s_acc) widx <= cur_last ? 16'd0 : (widx + 16'd1);

    // ---- DUT --------------------------------------------------------------
    wire [63:0] xd;
    wire [7:0]  xc;
    wire [31:0] frames, abort, flush_w, flush_d, txw, ctrl, short_f;
    wire [15:0] last_clen;
    wire [1:0]  st;

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(cur_data), .s_axis_tkeep(cur_keep),
        .s_axis_tvalid(1'b1), .s_axis_tready(s_ready), .s_axis_tlast(cur_last),
        .xgmii_txd(xd), .xgmii_txc(xc),
        .stat_frames(frames), .stat_abort(abort),
        .stat_flush_words(flush_w), .stat_flush_done(flush_d),
        .stat_tx_words(txw), .stat_tx_ctrl_char(ctrl), .stat_tx_short(short_f),
        .dbg_tx_last_clen(last_clen), .dbg_tx_state(st)
    );

    reg [31:0] c0_f, c0_w, c0_c;
    integer    cpf, line_bytes;

    initial begin
        clk = 0; rst_n = 0;
        l_i = 60; run_cycles = 20000;
        if (!$value$plusargs("L=%d", l_i)) l_i = 60;
        if (!$value$plusargs("CYCLES=%d", run_cycles)) run_cycles = 20000;
        nw_i = (l_i + 7) / 8;
        $display("MAC L=%0d NW=%0d CYCLES=%0d", l_i, nw_i, run_cycles);
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (500) @(posedge clk);
        c0_f = frames; c0_w = txw; c0_c = ctrl;
        repeat (run_cycles) @(posedge clk);
        $display("MAC CYCLES=%0d", run_cycles);
        $display("MAC FRAMES=%0d", frames - c0_f);
        $display("MAC XGMII_WORDS=%0d", txw - c0_w);
        $display("MAC CTRL_CHARS=%0d", ctrl - c0_c);
        if ((frames - c0_f) != 0) begin
            cpf = run_cycles / (frames - c0_f);
            line_bytes = 8 + l_i + 4 + 12;
            $display("MAC CYCLES_PER_FRAME=%0d", cpf);
            $display("MAC CYCLES_PER_FRAME_X1000=%0d", (run_cycles * 1000) / (frames - c0_f));
            $display("MAC XGMII_WORDS_PER_FRAME=%0d", (txw - c0_w) / (frames - c0_f));
            $display("MAC LINE_BYTES=%0d", line_bytes);
            $display("MAC EFF_X1000=%0d", (line_bytes * 1000) / (cpf * 8));
        end
        $display("MAC ABORT=%0d FLUSH_W=%0d FLUSH_D=%0d SHORT=%0d CLEN=%0d",
                 abort, flush_w, flush_d, short_f, last_clen);
        $finish;
    end

endmodule
