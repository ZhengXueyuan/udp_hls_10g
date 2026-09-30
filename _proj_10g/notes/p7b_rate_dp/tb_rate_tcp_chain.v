`timescale 1ns/1ps
// ===========================================================================
// tb_rate_tcp_chain -- TCP fast path TX 速率核算 TB (独立核算; 只读)
// ---------------------------------------------------------------------------
// 链路: 饱和载荷源 -> tcp_tx_frame -> tx_arb(TCP 优先) -> mac_tx_10g
//   (TCP 侧不需要 udp_tx_cfg, 也没有第二个 tx_arb —— 它就是 u_tx_arb 的 s_fast)
// TCB/CAM 读口钉常量 (纯速率核算; 不建连接语义):
//   rb_state=ESTAB, win_open=1, rb_snd_wnd!=0 但 rb_snd_nxt==rb_snd_una
//   ⇒ RTO 扫描条件恒假 ⇒ **不会**自发重传会话 (否则 svc/ring 会污染速率读数)
// plusarg: NW = 每帧载荷字数 (默认 183 = 1460 B), LASTK = 末字有效字节数 (默认 4),
//          CYCLES = 观测窗拍数
// ===========================================================================
module tb_rate_tcp_chain;

    reg  clk, rst_n;
    integer nw_i, lastk_i, run_cycles;

    always #3.2 clk = ~clk;          // 156.25 MHz

    // ---- 饱和载荷源 -------------------------------------------------------
    reg  [15:0] swcnt;
    reg         src_en;
    wire        cur_last = (swcnt == nw_i[15:0] - 16'd1);
    wire [63:0] src_data = {swcnt, 48'h0123456789AB};
    wire [7:0]  src_keep = cur_last ? (8'hFF << (8 - lastk_i[3:0])) : 8'hFF;
    wire        src_ready;
    wire        src_acc   = src_en && src_ready;
    reg  [31:0] src_accepts;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) swcnt <= 16'd0;
        else if (src_acc) swcnt <= cur_last ? 16'd0 : (swcnt + 16'd1);

    // ---- tcp_tx_frame -----------------------------------------------------
    wire [63:0] ttx_tdata, tx_tdata;
    wire [7:0]  ttx_tkeep, tx_tkeep;
    wire        ttx_tvalid, ttx_tready, ttx_tlast;
    wire        tx_tvalid, tx_tready, tx_tlast;
    wire [31:0] ttx_frames, ttx_bytes, ttx_ack, ttx_ackdrop, ttx_eend,
                ttx_droplen, ttx_fin, ttx_rst, ttx_tlastin;

    tcp_tx_frame u_ttf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(src_data), .s_axis_tkeep(src_keep),
        .s_axis_tvalid(src_en), .s_axis_tready(src_ready), .s_axis_tlast(cur_last),
        .s_axis_tid(4'd0),
        .ack_req(1'b0), .ack_id(4'd0), .ack_val(32'd0), .ack_syn(1'b0),
        .ack_fin(1'b0), .ack_rst(1'b0),
        .fin_req(16'd0), .rst_req(16'd0),
        .cfg_up(1'b0), .cfg_up_id(4'd0),
        .o_fin_sent(), .o_rst_sent(),
        .wu_req(1'b0), .wu_id(4'd0), .wu_val(32'd0), .wu_gnt(),
        .rb_id(), .rb_snd_nxt(32'd0), .rb_rcv_nxt(32'd0), .rb_rcv_wnd(16'hC000),
        .rb_snd_una(32'd0), .rb_snd_wnd(16'hC000), .rb_state(4'd1),
        .win_open(1'b1), .win_inflight(16'd0), .win_wnd_eff(16'hC000),
        .retx_req(1'b0), .retx_id(4'd0), .retx_gnt(), .stat_retx(),
        .o_retx_hi(), .o_retx_active(), .o_retx_id(),
        .upd_wr(), .upd_id(), .upd_sel(), .upd_val(),
        .cam_rd_id(), .cam_rd_dmac(48'h112233445566), .cam_rd_sip(32'hC0A86403),
        .cam_rd_sport(16'd40000), .cam_rd_dport(16'd8080),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(ttx_tdata), .m_axis_tkeep(ttx_tkeep),
        .m_axis_tvalid(ttx_tvalid), .m_axis_tready(ttx_tready), .m_axis_tlast(ttx_tlast),
        .stat_frames(ttx_frames), .stat_bytes(ttx_bytes), .stat_ack(ttx_ack),
        .stat_ack_drop(ttx_ackdrop), .stat_eend(ttx_eend),
        .stat_drop_len(ttx_droplen), .stat_fin(ttx_fin), .stat_rst(ttx_rst),
        .stat_tlast_in(ttx_tlastin),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    tx_arb u_tcp_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(ttx_tdata), .s_fast_tkeep(ttx_tkeep),
        .s_fast_tvalid(ttx_tvalid), .s_fast_tready(ttx_tready), .s_fast_tlast(ttx_tlast),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'd0),
        .s_slow_tvalid(1'b0), .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(tx_tdata), .m_axis_tkeep(tx_tkeep),
        .m_axis_tvalid(tx_tvalid), .m_axis_tready(tx_tready), .m_axis_tlast(tx_tlast)
    );

    wire [63:0] xgmii_txd;
    wire [7:0]  xgmii_txc;
    wire [31:0] mac_frames, mac_abort, mac_flush_w, mac_flush_d, mac_tx_words,
                mac_tx_ctrl, mac_tx_short;
    wire [15:0] mac_last_clen;
    wire [1:0]  mac_state;

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tx_tdata), .s_axis_tkeep(tx_tkeep),
        .s_axis_tvalid(tx_tvalid), .s_axis_tready(tx_tready), .s_axis_tlast(tx_tlast),
        .xgmii_txd(xgmii_txd), .xgmii_txc(xgmii_txc),
        .stat_frames(mac_frames), .stat_abort(mac_abort),
        .stat_flush_words(mac_flush_w), .stat_flush_done(mac_flush_d),
        .stat_tx_words(mac_tx_words), .stat_tx_ctrl_char(mac_tx_ctrl),
        .stat_tx_short(mac_tx_short),
        .dbg_tx_last_clen(mac_last_clen), .dbg_tx_state(mac_state)
    );


    // ---- 端到端帧周期监视 (tx_arb -> mac_tx 的 TLAST 间隔; 单位: 拍) ----------
    reg  [31:0] egap, emin, emax, tpuls;
    reg         eseen;
    wire        etl = tx_tlast && tx_tvalid && tx_tready;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            egap <= 32'd0; emin <= 32'hFFFFFFFF; emax <= 32'd0; eseen <= 1'b0; tpuls <= 32'd0;
        end else if (etl) begin
            if (eseen) begin
                if (egap < emin) emin <= egap;
                if (egap > emax) emax <= egap;
            end
            egap <= 32'd0; eseen <= 1'b1; tpuls <= tpuls + 32'd1;
        end else egap <= egap + 32'd1;

    reg  [31:0] c0_f, c0_w, c0_acc, c0_tf;
    reg  [63:0] cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cyc <= 64'd0; else cyc <= cyc + 64'd1;
    integer     i;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) src_accepts <= 32'd0;
        else if (src_acc) src_accepts <= src_accepts + 32'd1;

    initial begin
        clk = 0; rst_n = 0; src_en = 0;
        nw_i = 183; lastk_i = 4; run_cycles = 200000;
        if (!$value$plusargs("NW=%d", nw_i))       nw_i = 183;
        if (!$value$plusargs("LASTK=%d", lastk_i)) lastk_i = 4;
        if (!$value$plusargs("CYCLES=%d", run_cycles)) run_cycles = 200000;
        $display("TCPRATE NW=%0d LASTK=%0d CYCLES=%0d", nw_i, lastk_i, run_cycles);
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
        src_en <= 1'b1;
        repeat (2000) @(posedge clk);
        c0_f = mac_frames; c0_w = mac_tx_words; c0_acc = src_accepts; c0_tf = ttx_frames;
        repeat (run_cycles) @(posedge clk);
        $display("TCPRATE CYCLES=%0d", run_cycles);
        $display("TCPRATE TCP_FRAMES=%0d", ttx_frames - c0_tf);
        $display("TCPRATE MAC_FRAMES=%0d", mac_frames - c0_f);
        $display("TCPRATE SRC_ACCEPTS=%0d", src_accepts - c0_acc);
        $display("TCPRATE PAY_BYTES=%0d", (src_accepts - c0_acc) * 8
                 - (ttx_frames - c0_tf) * (8 - lastk_i));
        $display("TCPRATE GBPS_X1000=%0d",
                 (((src_accepts - c0_acc) * 8 - (ttx_frames - c0_tf) * (8 - lastk_i)) * 1250)
                 / run_cycles);
        if ((mac_frames - c0_f) != 0)
            $display("TCPRATE CYCLES_PER_FRAME=%0d", run_cycles / (mac_frames - c0_f));
        if ((mac_frames - c0_f) != 0)
            $display("TCPRATE CYCLES_PER_FRAME_X1000=%0d",
                     (run_cycles * 1000) / (mac_frames - c0_f));
        $display("TCPRATE E2E_PERIOD_MIN=%0d E2E_PERIOD_MAX=%0d", emin, emax);
        $display("TCPRATE TLAST_PULSES=%0d CYCLES_SEEN=%0d AVG_PERIOD_X1000=%0d",
                 tpuls, cyc, (cyc*1000)/(tpuls?tpuls:1));
        $display("TCPRATE ACK=%0d ACKDROP=%0d EEND=%0d DROPLEN=%0d FIN=%0d TLIN=%0d",
                 ttx_ack, ttx_ackdrop, ttx_eend, ttx_droplen, ttx_fin, ttx_tlastin);
        $display("TCPRATE ABORT=%0d FLUSH_W=%0d SHORT=%0d CLEN=%0d",
                 mac_abort, mac_flush_w, mac_tx_short, mac_last_clen);
        $finish;
    end

endmodule
