`timescale 1ns/1ps
// ===========================================================================
// 逐级速率测量 #4 —— **板级 TX 全链** (10G 构建的实际拓扑, 单域简化)
// ---------------------------------------------------------------------------
// 拓扑 (与 board/wrapper_p4.v 的 APP_MODE + P7B_10G 分支逐级同构):
//   app_udp_pattern -> udp_tx_cfg (peer 门) -> udp_tx_frame ->
//   tx_arb (UDP 压 HLS; HLS 侧不驱动) -> tx_arb (TCP 优先; TCP 侧不驱动) ->
//   mac_tx_10g -> XGMII
// 省略的只有 P6b 的 u_txcdc 异步 FIFO (它在 DP_156MHZ 构建里是**纯过路**,
//   同频同深 256, 不构成速率项; 且本 TB 是单域, 无法建模其跨域延迟)。
// 本 TB 回答: "把 app 发生器改成 8 字节/拍之后, 这一级级的下游还能跑多快"。
// 时钟 6.4ns = 156.25 MHz。
// ===========================================================================
module tb_lvl_full;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns

    wire [63:0] a_td;  wire [7:0] a_tk;
    wire        a_tv, a_tr, a_tl;
    wire [31:0] a_txb, a_txf, a_rxb, a_rxf, a_rxn, a_mm;
    wire        a_act, a_done;  wire [3:0] a_led;

    reg         peer_wr;
    reg  [47:0] peer_mac;
    reg  [31:0] peer_ip;

    wire        u_ready;
    wire [63:0] u_td;  wire [7:0] u_tk;
    wire        u_tv, u_tr, u_tl;
    wire [47:0] c_dmac, c_smac;  wire [31:0] c_dip, c_sip;
    wire [15:0] c_dport, c_sport;  wire c_csen;

    wire [63:0] m_td;  wire [7:0] m_tk;
    wire        m_tv, m_tr, m_tl;
    wire [31:0] utx_frames, utx_bytes, utx_drop;
    wire        utx_busy;

    wire [63:0] g_td;  wire [7:0] g_tk;
    wire        g_tv, g_tr, g_tl;           // u_tx_udp_arb 输出

    wire [63:0] x_td;  wire [7:0] x_tk;
    wire        x_tv, x_tr, x_tl;           // u_tx_arb 输出 -> mac

    wire [63:0] xgm_d;  wire [7:0] xgm_c;
    wire [31:0] mac_frames, mac_abort, mac_words;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(u_ready), .i_paylen(12'd1472),
        .m_tdata(a_td), .m_tkeep(a_tk), .m_tvalid(a_tv), .m_tready(a_tr),
        .m_tlast(a_tl),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_txb), .stat_tx_frames(a_txf),
        .stat_rx_bytes(a_rxb), .stat_rx_frames(a_rxf), .stat_rx_null(a_rxn),
        .stat_mismatch(a_mm), .active(a_act), .done(a_done), .led(a_led)
    );

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(utx_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'h1F91), .cfg_dst_port(16'h1F91), .cfg_csum_en(1'b1),
        .s_axis_tdata(a_td), .s_axis_tkeep(a_tk), .s_axis_tvalid(a_tv),
        .s_axis_tready(a_tr), .s_axis_tlast(a_tl),
        .m_axis_tdata(u_td), .m_axis_tkeep(u_tk), .m_axis_tvalid(u_tv),
        .m_axis_tready(u_tr), .m_axis_tlast(u_tl),
        .o_dst_mac(c_dmac), .o_dst_ip(c_dip), .o_dst_port(c_dport),
        .o_src_mac(c_smac), .o_src_ip(c_sip), .o_src_port(c_sport),
        .o_csum_en(c_csen), .o_ready(u_ready),
        .stat_frames(), .stat_deny()
    );

    udp_tx_frame u_utx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(u_td), .s_axis_tkeep(u_tk), .s_axis_tvalid(u_tv),
        .s_axis_tready(u_tr), .s_axis_tlast(u_tl),
        .cfg_src_mac(c_smac), .cfg_dst_mac(c_dmac),
        .cfg_src_ip(c_sip),   .cfg_dst_ip(c_dip),
        .cfg_src_port(c_sport), .cfg_dst_port(c_dport), .cfg_csum_en(c_csen),
        .m_axis_tdata(m_td), .m_axis_tkeep(m_tk), .m_axis_tvalid(m_tv),
        .m_axis_tready(m_tr), .m_axis_tlast(m_tl),
        .stat_frames(utx_frames), .stat_bytes(utx_bytes),
        .stat_drop_len(utx_drop), .o_busy(utx_busy)
    );

    // UDP app 压 HLS (HLS 侧恒空)
    tx_arb u_arb_udp (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(m_td), .s_fast_tkeep(m_tk), .s_fast_tvalid(m_tv),
        .s_fast_tready(m_tr), .s_fast_tlast(m_tl),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'h00), .s_slow_tvalid(1'b0),
        .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(g_td), .m_axis_tkeep(g_tk), .m_axis_tvalid(g_tv),
        .m_axis_tready(g_tr), .m_axis_tlast(g_tl)
    );

    // TCP 严格优先 (TCP 侧恒空)
    tx_arb u_arb_tcp (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(64'd0), .s_fast_tkeep(8'h00), .s_fast_tvalid(1'b0),
        .s_fast_tready(), .s_fast_tlast(1'b0),
        .s_slow_tdata(g_td), .s_slow_tkeep(g_tk), .s_slow_tvalid(g_tv),
        .s_slow_tready(g_tr), .s_slow_tlast(g_tl),
        .m_axis_tdata(x_td), .m_axis_tkeep(x_tk), .m_axis_tvalid(x_tv),
        .m_axis_tready(x_tr), .m_axis_tlast(x_tl)
    );

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(x_td), .s_axis_tkeep(x_tk), .s_axis_tvalid(x_tv),
        .s_axis_tready(x_tr), .s_axis_tlast(x_tl),
        .xgmii_txd(xgm_d), .xgmii_txc(xgm_c),
        .stat_frames(mac_frames), .stat_abort(mac_abort),
        .stat_flush_words(), .stat_flush_done(),
        .stat_tx_words(mac_words), .stat_tx_ctrl_char(), .stat_tx_short(),
        .dbg_tx_last_clen(), .dbg_tx_state()
    );

    integer cyc;
    reg [31:0] w0, f0, af0;

    initial begin
        rst_n = 1'b0; peer_wr = 1'b0;
        peer_mac = 48'h112233445566; peer_ip = 32'hC0A86401;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        peer_wr = 1'b1; @(posedge clk); peer_wr = 1'b0;
        repeat (3000) @(posedge clk);            // 热机
        w0 = mac_words; f0 = mac_frames; af0 = a_txf;
        repeat (300000) @(posedge clk);           // 窗口必须够长: 40 帧时量化误差 40x
        $display("--- tb_lvl_full: app -> cfg -> frame -> arb -> arb -> mac_tx_10g ---");
        $display("  clk period            = 6.400 ns (156.25 MHz)");
        $display("  delta app frames      = %0d", a_txf - af0);
        $display("  delta mac frames      = %0d", mac_frames - f0);
        $display("  delta mac tx_words    = %0d", mac_words - w0);
        if (mac_frames != f0 && a_txf != af0) begin
            $display("  FRAME PERIOD (mac)    = %0.3f cycles",
                     (mac_words - w0) * 1.0 / (mac_frames - f0));
            $display("  APP FRAME PERIOD      = %0.3f cycles",
                     300000.0 / (a_txf - af0));
            $display("  PAYLOAD RATE (mac)    = %0.1f Mbps",
                     1472.0 * 8.0 * 156.25e6
                     / ((mac_words - w0) * 1.0 / (mac_frames - f0)) / 1e6);
            $display("  PAYLOAD RATE (app)    = %0.1f Mbps",
                     1472.0 * 8.0 * 156.25e6 / (300000.0 / (a_txf - af0)) / 1e6);
        end
        $display("  utx frames=%0d bytes=%0d drop=%0d | mac abort=%0d",
                 utx_frames, utx_bytes, utx_drop, mac_abort);
        $display("LVLFULL DONE");
        $finish;
    end
endmodule
