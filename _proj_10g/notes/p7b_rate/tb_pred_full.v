`timescale 1ns/1ps
// ===========================================================================
// 预测链 —— "**把 app 发生器改成 8 字节/拍之后**，全链能跑多快"
// ---------------------------------------------------------------------------
// 做法: 用一个**行为级宽发生器** (每拍 1 个字 = 8 字节, 184 字/帧, 帧间 2 拍
//   对应 app FSM 的 T_GAP+T_IDLE) 替换 app_udp_pattern, 后接**真实的**
//   udp_tx_cfg -> udp_tx_frame -> tx_arb x2 -> mac_tx_10g。
//   发生器自带 256x73 字 FIFO —— 与 app_udp_pattern 内部同深同构 (真 app 的
//   生成/传输重叠正是靠它), 故本模型与"8 路并行版 app"的**时序行为**同构。
// ⚠️ 这不是对已存在 RTL 的验证 (宽版 app 尚不存在), 而是**改动前的量化预测**:
//   它回答"app 不再是瓶颈时, 下游哪一级接棒"。
// 时钟 6.4ns = 156.25 MHz。
// ===========================================================================
module tb_pred_full;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns

    // ==== 行为级宽发生器 (8 B/cycle) ====
    localparam integer NFW = 184;           // 1472 B / 8
    reg  [63:0] g_d;
    reg  [7:0]  g_k;
    reg         g_v, g_l;
    wire        g_r;                        // FIFO 不满
    integer     g_i;                        // 帧内字序号
    integer     g_gap;                      // 帧间剩余拍

    wire [63:0] f_d;  wire [7:0] f_k;
    wire        f_v, f_r, f_l;
    wire        f_empty, f_full;

    reg [63:0] b_d;  reg [7:0] b_k;  reg b_v, b_l;   // 推入 FIFO 的请求

    fifo_sync #(.W(73), .D(256), .AW(8)) u_gfifo (
        .clk(clk), .rst_n(rst_n),
        .wr(b_v && !f_full), .din({b_l, b_k, b_d}),
        .rd(g_r), .dout({f_l, f_k, f_d}),
        .empty(f_empty), .full(f_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(),
        .full_next(), .ovf_pulse()
    );
    assign f_v = !f_empty;
    assign g_r = f_v;                        // 下游随时可读 (udp_tx_cfg 组合直通)

    // 发生器: 每拍产 1 字 (只要 FIFO 收), 184 字一帧, 帧间 g_gap=2 拍
    always @(posedge clk) begin
        if (!rst_n) begin
            g_i <= 0; g_gap <= 0; b_v <= 1'b0; b_l <= 1'b0;
            b_k <= 8'hFF; b_d <= 64'd0; g_d <= 64'd0; g_k <= 8'hFF;
        end else begin
            b_v <= 1'b0;
            if (g_gap != 0) begin
                g_gap <= g_gap - 1;          // 帧间空闲 (app 的 T_GAP+T_IDLE)
            end else begin
                b_v <= 1'b1;
                b_k <= 8'hFF;
                b_l <= (g_i == NFW-1);
                b_d <= {56'd0, g_i[7:0]};
                if (b_v && !f_full) begin
                    if (g_i == NFW-1) begin
                        g_i   <= 0;
                        g_gap <= 2;
                    end else begin
                        g_i <= g_i + 1;
                    end
                end
            end
        end
    end

    // ==== 真实下游链 ====
    wire [63:0] u_td;  wire [7:0] u_tk;
    wire        u_tv, u_tr, u_tl;
    wire        u_ready;
    wire [47:0] c_dmac, c_smac;  wire [31:0] c_dip, c_sip;
    wire [15:0] c_dport, c_sport;  wire c_csen;
    wire [63:0] m_td;  wire [7:0] m_tk;
    wire        m_tv, m_tr, m_tl;
    wire [31:0] utx_frames, utx_bytes, utx_drop;
    wire        utx_busy;
    wire [63:0] h_td;  wire [7:0] h_tk;  wire h_tv, h_tr, h_tl;
    wire [63:0] x_td;  wire [7:0] x_tk;  wire x_tv, x_tr, x_tl;
    wire [63:0] xgm_d; wire [7:0] xgm_c;
    wire [31:0] mac_frames, mac_abort, mac_words, mac_ctrl, mac_short;
    wire [15:0] mac_clen; wire [1:0] mac_state;

    reg peer_wr;  reg [47:0] peer_mac;  reg [31:0] peer_ip;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(utx_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'h1F91), .cfg_dst_port(16'h1F91), .cfg_csum_en(1'b1),
        .s_axis_tdata(f_d), .s_axis_tkeep(f_k), .s_axis_tvalid(f_v),
        .s_axis_tready(f_r), .s_axis_tlast(f_l),
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

    tx_arb u_arb_udp (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(m_td), .s_fast_tkeep(m_tk), .s_fast_tvalid(m_tv),
        .s_fast_tready(m_tr), .s_fast_tlast(m_tl),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'h00), .s_slow_tvalid(1'b0),
        .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(h_td), .m_axis_tkeep(h_tk), .m_axis_tvalid(h_tv),
        .m_axis_tready(h_tr), .m_axis_tlast(h_tl)
    );

    tx_arb u_arb_tcp (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(64'd0), .s_fast_tkeep(8'h00), .s_fast_tvalid(1'b0),
        .s_fast_tready(), .s_fast_tlast(1'b0),
        .s_slow_tdata(h_td), .s_slow_tkeep(h_tk), .s_slow_tvalid(h_tv),
        .s_slow_tready(h_tr), .s_slow_tlast(h_tl),
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
        .stat_tx_words(mac_words), .stat_tx_ctrl_char(mac_ctrl),
        .stat_tx_short(mac_short),
        .dbg_tx_last_clen(mac_clen), .dbg_tx_state(mac_state)
    );

    integer cyc;
    reg [31:0] w0, f0, u0;

    initial begin
        rst_n = 1'b0; peer_wr = 1'b0;
        peer_mac = 48'h112233445566; peer_ip = 32'hC0A86401;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        peer_wr = 1'b1; @(posedge clk); peer_wr = 1'b0;
        repeat (2000) @(posedge clk);            // 热机
        w0 = mac_words; f0 = mac_frames; u0 = utx_frames;
        repeat (300000) @(posedge clk);
        $display("--- tb_pred_full: WIDE app (8 B/cyc) -> real cfg/frame/arb/arb/mac ---");
        $display("  clk period            = 6.400 ns (156.25 MHz)");
        $display("  delta utx frames      = %0d", utx_frames - u0);
        $display("  delta mac frames      = %0d", mac_frames - f0);
        $display("  delta mac tx_words    = %0d", mac_words - w0);
        if ((mac_frames != f0) && (utx_frames != u0)) begin
            $display("  UTX  FRAME PERIOD     = %0.3f cycles",
                     300000.0 / (utx_frames - u0));
            $display("  MAC  FRAME PERIOD     = %0.3f cycles",
                     (mac_words - w0) * 1.0 / (mac_frames - f0));
            $display("  XGMII WORDS PER FRAME = %0.3f",
                     (mac_words - w0) * 1.0 / (mac_frames - f0));
            $display("  PAYLOAD RATE          = %0.1f Mbps",
                     1472.0 * 8.0 * 156.25e6
                     / ((mac_words - w0) * 1.0 / (mac_frames - f0)) / 1e6);
            $display("  FRAME RATE            = %0.1f fps",
                     156.25e6 / ((mac_words - w0) * 1.0 / (mac_frames - f0)));
            $display("  LINE BYTES PER FRAME  = %0.1f B (content 1514 + pre 8 + FCS 4 + IFG)",
                     (mac_words - w0) * 8.0 / (mac_frames - f0));
        end
        $display("  utx bytes=%0d drop=%0d | mac abort=%0d short=%0d clen=%0d",
                 utx_bytes, utx_drop, mac_abort, mac_short, mac_clen);
        $display("PREDFULL DONE");
        $finish;
    end
endmodule
