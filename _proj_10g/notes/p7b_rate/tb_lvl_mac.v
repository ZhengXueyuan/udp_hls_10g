`timescale 1ns/1ps
// ===========================================================================
// 逐级速率测量 #3 —— _proj_10g/p7b_mac/rtl/mac_tx_10g.v **单独**
// ---------------------------------------------------------------------------
// 上游 = **无限就绪字源**: 190 字/帧 (1514 内容字节 = 42 头 + 1472 载荷),
//   末字 2 字节 (tkeep=8'hC0) —— 与 udp_tx_frame 的实际输出合同逐位同构。
// 本 TB 测的就是 PCS 之前那一级的 XGMII 天花板。
// 判据: Δ(stat_tx_words) / Δ(stat_frames) = **每帧 XGMII 字数** (含前导/尾/IFG)。
// 时钟 6.4ns = 156.25 MHz (XGMII 线时钟)。
// ⚠️ 本 TB 不含 PCS/PCS 的 RX→TX 反馈, 也不含官方核 (那在闸 1/闸 2 已单独验过)。
// ===========================================================================
module tb_lvl_mac;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns

    localparam integer NW = 190;            // 189 满字 + 1 个 2 字节尾字
    reg  [63:0] s_d;
    reg  [7:0]  s_k;
    reg         s_v, s_l;
    wire        s_r;
    integer     wi;

    wire [63:0] x_d;  wire [7:0] x_c;
    wire [31:0] m_frames, m_abort, m_flw, m_fld, m_words, m_ctrl, m_short;
    wire [15:0] m_clen;  wire [1:0] m_state;

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_d), .s_axis_tkeep(s_k), .s_axis_tvalid(s_v),
        .s_axis_tready(s_r), .s_axis_tlast(s_l),
        .xgmii_txd(x_d), .xgmii_txc(x_c),
        .stat_frames(m_frames), .stat_abort(m_abort),
        .stat_flush_words(m_flw), .stat_flush_done(m_fld),
        .stat_tx_words(m_words), .stat_tx_ctrl_char(m_ctrl), .stat_tx_short(m_short),
        .dbg_tx_last_clen(m_clen), .dbg_tx_state(m_state)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            wi <= 0; s_v <= 1'b0; s_l <= 1'b0; s_k <= 8'hFF; s_d <= 64'd0;
        end else begin
            s_v <= 1'b1;
            s_l <= (wi == NW-1);
            s_k <= (wi == NW-1) ? 8'hC0 : 8'hFF;      // 末字 2 字节
            s_d <= {56'd0, wi[7:0]};
            if (s_v && s_r) wi <= (wi == NW-1) ? 0 : (wi + 1);
        end
    end

    integer cyc;
    reg [31:0] w0, f0;

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (200) @(posedge clk);            // 热机
        w0 = m_words; f0 = m_frames;
        repeat (40000) @(posedge clk);
        $display("--- tb_lvl_mac: mac_tx_10g ONLY (infinite-ready source) ---");
        $display("  clk period          = 6.400 ns (156.25 MHz)");
        $display("  delta frames        = %0d", m_frames - f0);
        $display("  delta tx_words      = %0d", m_words - w0);
        if (m_frames != f0) begin
            $display("  XGMII WORDS PER FRAME = %0.3f",
                     (m_words - w0) * 1.0 / (m_frames - f0));
            $display("  XGMII WIRE RATE       = %0.3f Gbps",
                     ((m_words - w0) * 1.0 / (m_frames - f0)) * 64.0
                     * 156.25e6 / 1e9);
            $display("  PAYLOAD RATE          = %0.1f Mbps",
                     1472.0 * 8.0 * 156.25e6
                     / ((m_words - w0) * 1.0 / (m_frames - f0)) / 1e6);
        end
        $display("  dbg_tx_last_clen=%0d abort=%0d short=%0d flush_w=%0d flush_done=%0d",
                 m_clen, m_abort, m_short, m_flw, m_fld);
        $display("LVLMAC DONE");
        $finish;
    end
endmodule
