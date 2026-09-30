`timescale 1ns/1ps
// ===========================================================================
// tb_rate_udp_chain -- 10G 数据面 TX 速率核算 TB (独立核算; 只读, 不改任何 RTL)
// ---------------------------------------------------------------------------
// 前提 (任务设定): **发生器不再是瓶颈** = 载荷源是**饱和源**: 每拍都 present
//   一个字 (8 B/拍), 数据由寄存器 swcnt 组合导出 => tdata/tkeep/tlast 在
//   "valid && !ready" 期间恒定, 且在 ready 的下一拍立刻换新字 (零气泡)。
// 链路 (与 board/wrapper_p4.v 的 P7B_10G + APP_MODE 分支同构):
//   饱和载荷源 -> udp_tx_cfg -> udp_tx_frame -> tx_arb(UDP 压 HLS)
//               -> tx_arb(TCP 严格优先) -> mac_tx_10g -> XGMII
// 本 TB **只量吞吐**, 不判协议内容 (内容正确性由既有门负责)。
// 打印 (全部以 "RATE " 前缀): CYCLES / UDP_FRAMES / MAC_FRAMES / PAY_BYTES /
//   GBPS / CYCLES_PER_FRAME / XGMII_WORDS_PER_FRAME / SRC_ACCEPTS
// plusarg: NW = 每帧载荷字数 (默认 184 = 1472 B), CYCLES = 观测窗拍数
// ===========================================================================
module tb_rate_udp_chain;

    reg  clk, rst_n;
    integer nw_i, run_cycles, lastk_i;
    integer tnw_i, tlastk_i;

    always #3.2 clk = ~clk;          // 156.25 MHz (10G 数据面时钟)

    // ---- 饱和载荷源 -------------------------------------------------------
    reg  [15:0] swcnt;
    reg         src_en;
    wire [15:0] swcnt_nxt = (swcnt == nw_i[15:0] - 16'd1) ? 16'd0
                                                          : (swcnt + 16'd1);
    wire        src_last  = (swcnt == nw_i[15:0] - 16'd1);
    wire [63:0] src_data  = {swcnt, 48'h0123456789AB};
    wire [7:0]  src_keep  = src_last ? (8'hFF << (8 - lastk_i[3:0])) : 8'hFF;
    wire        src_ready;
    wire        src_acc   = src_en && src_ready;
    reg  [31:0] src_accepts;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) swcnt <= 16'd0;
        else if (src_acc) swcnt <= swcnt_nxt;


    // ---- TCP fast path 饱和载荷源 (与 wrapper 的 u_tx_arb.s_fast 同构) -------
    reg  [15:0] twcnt;
    reg         tsrc_en;
    wire        t_cur_last = (twcnt == tnw_i[15:0] - 16'd1);
    wire [63:0] t_src_data = {twcnt, 48'hFEDCBA987654};
    wire [7:0]  t_src_keep = t_cur_last ? (8'hFF << (8 - tlastk_i[3:0])) : 8'hFF;
    wire        t_src_ready;
    wire        t_src_acc = tsrc_en && t_src_ready;
    reg  [31:0] t_accepts;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) twcnt <= 16'd0;
        else if (t_src_acc) twcnt <= t_cur_last ? 16'd0 : (twcnt + 16'd1);

    // ---- udp_tx_cfg -------------------------------------------------------
    reg         peer_wr;
    wire [63:0] cfg_tdata;
    wire [7:0]  cfg_tkeep;
    wire        cfg_tvalid, cfg_tready, cfg_tlast;
    wire [47:0] u_dst_mac, u_src_mac;
    wire [31:0] u_dst_ip,  u_src_ip;
    wire [15:0] u_dst_port, u_src_port;
    wire        u_csum_en, u_ready, u_busy;
    wire [31:0] cfg_stat_frames, cfg_stat_deny;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(48'h112233445566), .peer_ip(32'hC0A86403),
        .frame_busy(u_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'd8081), .cfg_dst_port(16'd8081), .cfg_csum_en(1'b1),
        .s_axis_tdata(src_data), .s_axis_tkeep(src_keep),
        .s_axis_tvalid(src_en), .s_axis_tready(src_ready), .s_axis_tlast(src_last),
        .m_axis_tdata(cfg_tdata), .m_axis_tkeep(cfg_tkeep),
        .m_axis_tvalid(cfg_tvalid), .m_axis_tready(cfg_tready), .m_axis_tlast(cfg_tlast),
        .o_dst_mac(u_dst_mac), .o_dst_ip(u_dst_ip), .o_dst_port(u_dst_port),
        .o_src_mac(u_src_mac), .o_src_ip(u_src_ip), .o_src_port(u_src_port),
        .o_csum_en(u_csum_en), .o_ready(u_ready),
        .stat_frames(cfg_stat_frames), .stat_deny(cfg_stat_deny)
    );

    // ---- udp_tx_frame -----------------------------------------------------
    wire [63:0] utx_tdata;
    wire [7:0]  utx_tkeep;
    wire        utx_tvalid, utx_tready, utx_tlast;
    wire [31:0] utx_frames, utx_bytes, utx_drop_len;

    udp_tx_frame u_utf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(cfg_tdata), .s_axis_tkeep(cfg_tkeep),
        .s_axis_tvalid(cfg_tvalid), .s_axis_tready(cfg_tready), .s_axis_tlast(cfg_tlast),
        .cfg_src_mac(u_src_mac), .cfg_dst_mac(u_dst_mac),
        .cfg_src_ip(u_src_ip),   .cfg_dst_ip(u_dst_ip),
        .cfg_src_port(u_src_port), .cfg_dst_port(u_dst_port),
        .cfg_csum_en(u_csum_en),
        .m_axis_tdata(utx_tdata), .m_axis_tkeep(utx_tkeep),
        .m_axis_tvalid(utx_tvalid), .m_axis_tready(utx_tready), .m_axis_tlast(utx_tlast),
        .stat_frames(utx_frames), .stat_bytes(utx_bytes),
        .stat_drop_len(utx_drop_len), .o_busy(u_busy)
    );

    // ---- 合流器 x2 (与 wrapper 同构: TCP 优先 > UDP app > HLS) -------------
    wire [63:0] mrg_tdata, tx_tdata;
    wire [7:0]  mrg_tkeep, tx_tkeep;
    wire        mrg_tvalid, mrg_tready, mrg_tlast;
    wire        tx_tvalid, tx_tready, tx_tlast;

    tx_arb u_udp_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(utx_tdata), .s_fast_tkeep(utx_tkeep),
        .s_fast_tvalid(utx_tvalid), .s_fast_tready(utx_tready), .s_fast_tlast(utx_tlast),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'd0),
        .s_slow_tvalid(1'b0), .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(mrg_tdata), .m_axis_tkeep(mrg_tkeep),
        .m_axis_tvalid(mrg_tvalid), .m_axis_tready(mrg_tready), .m_axis_tlast(mrg_tlast)
    );

    wire [63:0] ttx_tdata;
    wire [7:0]  ttx_tkeep;
    wire        ttx_tvalid, ttx_tready, ttx_tlast;
    wire [31:0] ttx_frames;

    tcp_tx_frame u_ttf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(t_src_data), .s_axis_tkeep(t_src_keep),
        .s_axis_tvalid(tsrc_en), .s_axis_tready(t_src_ready), .s_axis_tlast(t_cur_last),
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
        .stat_frames(ttx_frames), .stat_bytes(), .stat_ack(), .stat_ack_drop(),
        .stat_eend(), .stat_drop_len(), .stat_fin(), .stat_rst(), .stat_tlast_in(),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    tx_arb u_tcp_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(ttx_tdata), .s_fast_tkeep(ttx_tkeep),
        .s_fast_tvalid(ttx_tvalid), .s_fast_tready(ttx_tready), .s_fast_tlast(ttx_tlast),
        .s_slow_tdata(mrg_tdata), .s_slow_tkeep(mrg_tkeep),
        .s_slow_tvalid(mrg_tvalid), .s_slow_tready(mrg_tready), .s_slow_tlast(mrg_tlast),
        .m_axis_tdata(tx_tdata), .m_axis_tkeep(tx_tkeep),
        .m_axis_tvalid(tx_tvalid), .m_axis_tready(tx_tready), .m_axis_tlast(tx_tlast)
    );

    // ---- mac_tx_10g -------------------------------------------------------
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

    // ---- 观测窗 -----------------------------------------------------------

    // ---- 帧周期监视 (u_udp_tx.m_axis_tlast 到下一次 tlast 的拍数) -------------
    reg  [31:0] pgap, pmin, pmax, tpuls;
    reg         pseen;
    wire        tl_fire = utx_tlast && utx_tvalid && utx_tready;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            pgap <= 32'd0; pmin <= 32'hFFFFFFFF; pmax <= 32'd0; pseen <= 1'b0;
            tpuls <= 32'd0;
        end else if (tl_fire) begin
            if (pseen) begin
                if (pgap < pmin) pmin <= pgap;
                if (pgap > pmax) pmax <= pgap;
            end
            pgap <= 32'd0; pseen <= 1'b1; tpuls <= tpuls + 32'd1;
        end else pgap <= pgap + 32'd1;

    reg  [63:0] cyc;
    reg         win;
    reg  [31:0] c0_macf, c0_txw, c0_utxf, c0_acc, c0_tacc;
    reg  [31:0] wcyc, wbusy, widle, wacc, wfrm;      // 窗口内的拍/相位计数
    reg  [31:0] t_acc_w;
    integer     i;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            cyc <= 64'd0; win <= 1'b0; src_accepts <= 32'd0; t_accepts <= 32'd0;
        end else begin
            cyc <= cyc + 64'd1;
            if (src_acc) src_accepts <= src_accepts + 32'd1;
            if (t_src_acc) t_accepts <= t_accepts + 32'd1;
            if (win) begin
                wcyc <= wcyc + 32'd1;
                if (u_busy) wbusy <= wbusy + 32'd1; else widle <= widle + 32'd1;
                if (src_acc) wacc <= wacc + 32'd1;
            end
        end

    // ---- 端到端帧周期监视 (tx_arb -> mac_tx 的 TLAST 间隔; 单位: 拍) ----------
    reg  [31:0] egap, emin, emax;
    reg         eseen;
    wire        etl = tx_tlast && tx_tvalid && tx_tready;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            egap <= 32'd0; emin <= 32'hFFFFFFFF; emax <= 32'd0; eseen <= 1'b0;
        end else if (etl) begin
            if (eseen) begin
                if (egap < emin) emin <= egap;
                if (egap > emax) emax <= egap;
            end
            egap <= 32'd0; eseen <= 1'b1;
        end else egap <= egap + 32'd1;

    initial begin
        clk = 0; rst_n = 0; src_en = 0; tsrc_en = 0; peer_wr = 0;
        nw_i = 184; run_cycles = 200000; lastk_i = 8;
        if (!$value$plusargs("NW=%d", nw_i)) nw_i = 184;
        if (!$value$plusargs("LASTK=%d", lastk_i)) lastk_i = 8;
        tnw_i = 183; tlastk_i = 4;
        if (!$value$plusargs("TNW=%d", tnw_i)) tnw_i = 183;
        if (!$value$plusargs("TLASTK=%d", tlastk_i)) tlastk_i = 4;
        if (!$value$plusargs("CYCLES=%d", run_cycles)) run_cycles = 200000;
        $display("RATE NW=%0d LASTK=%0d CYCLES=%0d", nw_i, lastk_i, run_cycles);
        repeat (20) @(posedge clk);
        rst_n = 1;
        // 写 peer 表 (learn-on-RX 的等价注入) 后开门
        repeat (4) @(posedge clk);
        @(posedge clk); peer_wr <= 1'b1;
        @(posedge clk); peer_wr <= 1'b0;
        repeat (8) @(posedge clk);
        src_en <= 1'b1;
        if (tnw_i > 0) tsrc_en <= 1'b1;   // TNW=0 => 只跑 UDP 单流
        // 预热: 让流水填满/丢开启动瞬态
        repeat (2000) @(posedge clk);
        c0_macf = mac_frames; c0_txw = mac_tx_words;
        c0_utxf = utx_frames; c0_acc = src_accepts; c0_tacc = t_accepts;
        win <= 1'b1; wcyc = 0; wbusy = 0; widle = 0; wacc = 0;
        repeat (run_cycles) @(posedge clk);
        win <= 1'b0;
        $display("RATE CYCLES=%0d", run_cycles);
        $display("RATE UDP_FRAMES=%0d", utx_frames - c0_utxf);
        $display("RATE MAC_FRAMES=%0d", mac_frames - c0_macf);
        $display("RATE SRC_ACCEPTS=%0d", src_accepts - c0_acc);
        // 载荷比特率 = bytes * 8 * 156.25e6 / cycles bps = bytes * 1250e6 / cycles
        //   => Gbps 的千分之一 = bytes * 1250 / cycles
        $display("RATE PAY_BYTES=%0d", (src_accepts - c0_acc) * 8 - (src_accepts - c0_acc) * (8 - lastk_i) / nw_i);
        $display("RATE GBPS_X1000=%0d", (((src_accepts - c0_acc) * 8 - (src_accepts - c0_acc) * (8 - lastk_i) / nw_i) * 1250) / run_cycles);
        $display("RATE BYTES_PER_CYCLE_X1000=%0d",
                 ((src_accepts - c0_acc) * 8 * 1000) / run_cycles);
        t_acc_w = (t_accepts - c0_tacc) * 8
                  - ((ttx_frames) * (8 - tlastk_i)) / (tnw_i? tnw_i : 1);
        $display("RATE AGG_PAY_BYTES=%0d",
                 ((src_accepts - c0_acc) * 8 - (src_accepts - c0_acc) * (8 - lastk_i) / nw_i)
                 + t_acc_w);
        $display("RATE AGG_GBPS_X1000=%0d",
                 ((((src_accepts - c0_acc) * 8 - (src_accepts - c0_acc) * (8 - lastk_i) / nw_i)
                   + t_acc_w) * 1250) / run_cycles);
        if ((mac_frames - c0_macf) != 0)
            $display("RATE CYCLES_PER_FRAME=%0d",
                     run_cycles / (mac_frames - c0_macf));
        if ((mac_frames - c0_macf) != 0)
            $display("RATE CYCLES_PER_FRAME_X1000=%0d",
                     (run_cycles * 1000) / (mac_frames - c0_macf));
        if ((mac_frames - c0_macf) != 0)
            $display("RATE XGMII_WORDS_PER_FRAME=%0d",
                     (mac_tx_words - c0_txw) / (mac_frames - c0_macf));
        $display("RATE E2E_PERIOD_MIN=%0d E2E_PERIOD_MAX=%0d", emin, emax);
        $display("RATE FRAMER_PERIOD_MIN=%0d FRAMER_PERIOD_MAX=%0d", pmin, pmax);
        $display("RATE TLAST_PULSES=%0d CYCLES_SEEN=%0d", tpuls, cyc);
        $display("RATE WIN_CYC=%0d WIN_FRM=%0d WIN_BUSY=%0d WIN_IDLE=%0d WIN_ACC=%0d",
                 wcyc, utx_frames - c0_utxf, wbusy, widle, wacc);
        $display("RATE PER_FRM_X1000 CYC=%0d BUSY=%0d IDLE=%0d ACC=%0d",
                 (wcyc*1000)/((utx_frames-c0_utxf)?(utx_frames-c0_utxf):1),
                 (wbusy*1000)/((utx_frames-c0_utxf)?(utx_frames-c0_utxf):1),
                 (widle*1000)/((utx_frames-c0_utxf)?(utx_frames-c0_utxf):1),
                 (wacc*1000)/((utx_frames-c0_utxf)?(utx_frames-c0_utxf):1));
        $display("RATE AVG_PERIOD_X1000=%0d", (cyc * 1000) / (tpuls ? tpuls : 1));
        $display("RATE MAC_ABORT=%0d FLUSH_W=%0d FLUSH_D=%0d SHORT=%0d",
                 mac_abort, mac_flush_w, mac_flush_d, mac_tx_short);
        $display("RATE DENY=%0d DROP_LEN=%0d LAST_CLEN=%0d",
                 cfg_stat_deny, utx_drop_len, mac_last_clen);
        $finish;
    end

endmodule
