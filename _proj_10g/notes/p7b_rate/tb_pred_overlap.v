`timescale 1ns/1ps
// ===========================================================================
// 预测链 #2 —— "**app 改宽 + 组帧器收发重叠**之后，全链能跑多快"
// ---------------------------------------------------------------------------
// 与 tb_pred_full 唯一的差别: 把真实 udp_tx_frame (帧级 store-and-forward,
//   收 184 拍 / 发 190 拍**串行**) 换成一个**行为级收发重叠模型** (乒乓双 bank:
//   收帧 N+1 与发帧 N 并行 ⇒ 帧周期 = max(184, 190) = 190 拍)。
// 其余全部是真实 RTL: udp_tx_cfg / tx_arb x2 / mac_tx_10g (以及 app 侧的
//   256x73 fifo_sync)。
// ⚠️ 这是**改动前的量化预测** (重叠版帧器尚不存在); 用来回答"第二步改完后
//   哪一级接棒当瓶颈"。
// 时钟 6.4ns = 156.25 MHz。
// ===========================================================================
module tb_pred_overlap;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns

    // ==== 行为级宽发生器 (8 B/cycle), 同 tb_pred_full ====
    localparam integer NFW = 184;
    reg  [63:0] b_d;  reg [7:0] b_k;  reg b_v, b_l;
    integer     g_i, g_gap;
    wire [63:0] f_d;  wire [7:0] f_k;
    wire        f_v, f_r, f_l;
    wire        f_empty, f_full;
    // ⚠️ u_* (u_cfg 的输出 = 帧器的输入) 必须在写侧 always **之前**声明 ——
    //    否则 always 里的引用会造出隐式 1 位网 (本工程坑 24)
    wire [63:0] u_td;  wire [7:0] u_tk;
    wire        u_tv, u_tr, u_tl;
    wire        u_ready;
    assign u_tr = 1'b1;      // 重叠帧器的写侧每拍都收 (bank 交替, 结构性不反压)

    fifo_sync #(.W(73), .D(256), .AW(8)) u_gfifo (
        .clk(clk), .rst_n(rst_n),
        .wr(b_v && !f_full), .din({b_l, b_k, b_d}),
        .rd(f_r), .dout({f_l, f_k, f_d}),
        .empty(f_empty), .full(f_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(),
        .full_next(), .ovf_pulse()
    );
    assign f_v = !f_empty;
    // ⚠️ f_r 是 u_cfg.s_axis_tready 的输出 (u_cfg 在链内 ⇒ 单驱动);
    //    FIFO 的 rd 用同一根 f_r (u_cfg 组合直通 ⇒ 语义 = "帧器可收")

    always @(posedge clk) begin
        if (!rst_n) begin
            g_i <= 0; g_gap <= 0; b_v <= 1'b0; b_l <= 1'b0;
            b_k <= 8'hFF; b_d <= 64'd0;
        end else begin
            b_v <= 1'b0;
            if (g_gap != 0) begin
                g_gap <= g_gap - 1;
            end else begin
                b_v <= 1'b1;
                b_k <= 8'hFF;
                b_l <= (g_i == NFW-1);
                b_d <= {56'd0, g_i[7:0]};
                if (b_v && !f_full) begin
                    if (g_i == NFW-1) begin g_i <= 0; g_gap <= 2; end
                    else             g_i <= g_i + 1;
                end
            end
        end
    end

    // ==== 行为级**收发重叠**组帧器 (乒乓, 2 x 190 字) ====
    // 输入: 184 字/帧 (末字 tlast); 输出: 190 字/帧 (末字 2 字节 tkeep=0xC0)
    localparam integer NOW = 190;           // 每帧输出字数 (与真实帧器一致)
    reg [63:0] bnk_d [0:1][0:NOW-1];
    reg [7:0]  bnk_k [0:1][0:NOW-1];
    reg [1:0]  bnk_ok;                      // bank 已收完整帧
    integer    wi, wj, ci, cj;              // 写/读 bank 与帧内计数
    integer    ii;
    reg o_v;
    wire o_r;                               // 下游 ready (arb)
    wire [63:0] o_d = bnk_d[wj][cj];        // 组合读出 (FWFT 风格)
    wire [7:0]  o_k = (cj == NOW-1) ? 8'hC0 : 8'hFF;
    wire        o_l = (cj == NOW-1);

    always @(posedge clk) begin
        if (!rst_n) begin
            wi <= 0; wj <= 0; ci <= 0; cj <= 0; bnk_ok <= 2'b00;
            o_v <= 1'b0;
        end else begin
            // ---- 写侧: 收当前帧进 bank wi (上游 = u_cfg 的组合直通输出) ----
            if (u_tv) begin
                bnk_d[wi][ci] <= u_td;
                bnk_k[wi][ci] <= u_tk;
                if (ci == NFW-1) begin
                    ci <= 0;
                    bnk_ok[wi] <= 1'b1;
                    wi <= wi ^ 1;
                end else begin
                    ci <= ci + 1;
                end
            end
            // ---- 读侧: 发 bank wj 的 190 字 ----
            if (!o_v) begin
                if (bnk_ok[wj]) o_v <= 1'b1;
            end else if (o_r) begin
                if (cj == NOW-1) begin
                    cj <= 0;
                    bnk_ok[wj] <= 1'b0;
                    wj <= wj ^ 1;
                    o_v <= 1'b0;              // 下一拍再看新 bank
                end else begin
                    cj <= cj + 1;
                end
            end
        end
    end
    // ⚠️ o_v 的置位晚一拍会在稳态下损失 1 拍/帧 —— 刻意保留 (等价于真实帧器的
    //    S_WAIT/S_DONE 固定开销, 见报告的"每帧固定开销"一节)。

    // ==== 真实下游 ====
    wire [47:0] c_dmac, c_smac;  wire [31:0] c_dip, c_sip;
    wire [15:0] c_dport, c_sport;  wire c_csen;
    wire [63:0] m_td;  wire [7:0] m_tk;
    wire        m_tv, m_tr, m_tl;
    wire [63:0] h_td;  wire [7:0] h_tk;  wire h_tv, h_tr, h_tl;
    wire [63:0] x_td;  wire [7:0] x_tk;  wire x_tv, x_tr, x_tl;
    wire [63:0] xgm_d; wire [7:0] xgm_c;
    wire [31:0] mac_frames, mac_abort, mac_words, mac_ctrl, mac_short;
    wire [15:0] mac_clen; wire [1:0] mac_state;

    reg peer_wr;  reg [47:0] peer_mac;  reg [31:0] peer_ip;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(1'b0),                    // 重叠帧器不再有"整帧独占"窗口
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
    // ⚠️ udp_tx_cfg 是纯组合直通门 ⇒ 它的 m_* 输出 = u_cfg 的输入 = 上游 FIFO
    //    输出 (f_*); 本 TB 把 cfg 例化**在链外**仅作对照 (o_ready 供观察),
    //    重叠帧器直接接 f_* —— 与"cfg 在链内"的时序逐拍等价 (零延迟直通)。

    tx_arb u_arb_udp (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(o_d), .s_fast_tkeep(o_k), .s_fast_tvalid(o_v),
        .s_fast_tready(o_r), .s_fast_tlast(o_l),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'h00), .s_slow_tvalid(1'b0),
        .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(m_td), .m_axis_tkeep(m_tk), .m_axis_tvalid(m_tv),
        .m_axis_tready(m_tr), .m_axis_tlast(m_tl)
    );

    tx_arb u_arb_tcp (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(64'd0), .s_fast_tkeep(8'h00), .s_fast_tvalid(1'b0),
        .s_fast_tready(), .s_fast_tlast(1'b0),
        .s_slow_tdata(m_td), .s_slow_tkeep(m_tk), .s_slow_tvalid(m_tv),
        .s_slow_tready(m_tr), .s_slow_tlast(m_tl),
        .m_axis_tdata(h_td), .m_axis_tkeep(h_tk), .m_axis_tvalid(h_tv),
        .m_axis_tready(h_tr), .m_axis_tlast(h_tl)
    );
    assign x_td = h_td;  assign x_tk = h_tk;
    assign x_tv = h_tv;  assign h_tr = x_tr;  assign x_tl = h_tl;

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

    reg [31:0] w0, f0;

    initial begin
        rst_n = 1'b0; peer_wr = 1'b0;
        peer_mac = 48'h112233445566; peer_ip = 32'hC0A86401;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        peer_wr = 1'b1; @(posedge clk); peer_wr = 1'b0;
        repeat (2000) @(posedge clk);
        w0 = mac_words; f0 = mac_frames;
        repeat (300000) @(posedge clk);
        $display("--- tb_pred_overlap: WIDE app + OVERLAPPED framer -> arb x2 -> mac ---");
        $display("  clk period            = 6.400 ns (156.25 MHz)");
        $display("  delta mac frames      = %0d", mac_frames - f0);
        $display("  delta mac tx_words    = %0d", mac_words - w0);
        if (mac_frames != f0) begin
            $display("  FRAME PERIOD          = %0.3f cycles",
                     (mac_words - w0) * 1.0 / (mac_frames - f0));
            $display("  FRAME RATE            = %0.1f fps",
                     156.25e6 / ((mac_words - w0) * 1.0 / (mac_frames - f0)));
            $display("  PAYLOAD RATE          = %0.1f Mbps",
                     1472.0 * 8.0 * 156.25e6
                     / ((mac_words - w0) * 1.0 / (mac_frames - f0)) / 1e6);
        end
        $display("  mac abort=%0d short=%0d clen=%0d", mac_abort, mac_short, mac_clen);
        $display("PREDOVER DONE");
        $finish;
    end
endmodule
