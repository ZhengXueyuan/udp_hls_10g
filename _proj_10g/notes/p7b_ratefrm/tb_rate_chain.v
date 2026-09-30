`timescale 1ns/1ps
// ===========================================================================
// tb_rate_chain -- 组帧器 → tx_arb → mac_tx_10g 的**真实链路**帧周期 (10G 时钟 6.4ns)
// ---------------------------------------------------------------------------
// 与 p7b_rate/tb_lvl_frame.v 的区别: 那里测的是帧器**单独** (下游恒 ready);
// 这里把真实的下游 (tx_arb + mac_tx_10g, 均为真 RTL) 接上, 测**整条 TX 数据面**
// 每帧占用多少拍 ⇒ 这才是"组帧器改完之后, 全链的天花板在哪一级"的读数。
// 上游 = 无限就绪字源 (每拍 1 字, 184 字/帧 = 1472B 载荷), 刻意比 app 快 8 倍。
// 判据: XGMII 上 /S/ 起始字的**拍间差** (tyc[0]=1 且 txd[7:0]=0xFB)。
// ===========================================================================
module tb_rate_chain;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    localparam integer NW = 184;            // 1472B = 184 字
    reg  [63:0] s_d;
    reg  [7:0]  s_k;
    reg         s_v, s_l;
    wire        s_r;
    integer     wi;

    wire [63:0] f_td;  wire [7:0] f_tk;
    wire        f_tv, f_tl, f_tr;
    wire [31:0] f_frames, f_bytes, f_drop;
    wire        f_busy;

    udp_tx_frame u_utx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_d), .s_axis_tkeep(s_k), .s_axis_tvalid(s_v),
        .s_axis_tready(s_r), .s_axis_tlast(s_l),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_dst_mac(48'h112233445566),
        .cfg_src_ip(32'hC0A86402),      .cfg_dst_ip(32'hC0A86401),
        .cfg_src_port(16'h1F91),        .cfg_dst_port(16'h1F91),
        .cfg_csum_en(1'b1),
        .m_axis_tdata(f_td), .m_axis_tkeep(f_tk), .m_axis_tvalid(f_tv),
        .m_axis_tready(f_tr), .m_axis_tlast(f_tl),
        .stat_frames(f_frames), .stat_bytes(f_bytes),
        .stat_drop_len(f_drop), .o_busy(f_busy)
    );

    wire [63:0] a_td;  wire [7:0] a_tk;
    wire        a_tv, a_tr, a_tl;
    wire        slow_r;

    tx_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(f_td), .s_fast_tkeep(f_tk), .s_fast_tvalid(f_tv),
        .s_fast_tready(f_tr), .s_fast_tlast(f_tl),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'h00), .s_slow_tvalid(1'b0),
        .s_slow_tready(slow_r), .s_slow_tlast(1'b0),
        .m_axis_tdata(a_td), .m_axis_tkeep(a_tk), .m_axis_tvalid(a_tv),
        .m_axis_tready(a_tr), .m_axis_tlast(a_tl)
    );

    wire [63:0] x_txd; wire [7:0] x_txc;
    wire [31:0] m_frames, m_abort, m_flw, m_fld, m_words, m_ctrl, m_short;
    wire [15:0] m_clen; wire [1:0] m_state;

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(a_td), .s_axis_tkeep(a_tk), .s_axis_tvalid(a_tv),
        .s_axis_tready(a_tr), .s_axis_tlast(a_tl),
        .xgmii_txd(x_txd), .xgmii_txc(x_txc),
        .stat_frames(m_frames), .stat_abort(m_abort),
        .stat_flush_words(m_flw), .stat_flush_done(m_fld),
        .stat_tx_words(m_words), .stat_tx_ctrl_char(m_ctrl),
        .stat_tx_short(m_short), .dbg_tx_last_clen(m_clen),
        .dbg_tx_state(m_state)
    );

    // ---- 源 (寄存器化, 与 tb_lvl_frame 同款) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            wi <= 0; s_v <= 1'b0; s_l <= 1'b0; s_k <= 8'hFF; s_d <= 64'd0;
        end else begin
            s_v <= 1'b1;
            s_k <= 8'hFF;
            s_l <= (wi == NW-1);
            s_d <= {56'd0, wi[7:0]};
            if (s_v && s_r) wi <= (wi == NW-1) ? 0 : (wi + 1);
        end
    end

    // ---- SOP 检测 (XGMII 首字: lane0 = /S/ = 0xFB, txc[0]=1) ----
    wire sop = x_txc[0] && (x_txd[7:0] == 8'hFB);

    integer cyc, n, last_cyc, sum_p, nfr;
    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; last_cyc <= 0; sum_p <= 0; nfr <= 0;
        end else begin
            cyc <= cyc + 1;
            if (sop) begin
                nfr <= nfr + 1;
                if (nfr >= 4) begin
                    sum_p <= sum_p + (cyc - last_cyc);
                    n     <= n + 1;
                end
                last_cyc <= cyc;
            end
        end
    end

    integer i;
    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        for (i = 0; i < 200000; i = i + 1) begin
            if (n >= 40) i = 200000;
            else @(posedge clk);
        end
        $display("--- tb_rate_chain: udp_tx_frame -> tx_arb -> mac_tx_10g ---");
        $display("  clk period          = 6.400 ns (156.25 MHz)");
        $display("  XGMII frames(sop)   = %0d  mac stat_frames=%0d  utx stat_frames=%0d drop=%0d abort=%0d",
                 nfr, m_frames, f_frames, f_drop, m_abort);
        $display("  mac tx_words=%0d ctrl=%0d short=%0d flush_w=%0d flush_done=%0d",
                 m_words, m_ctrl, m_short, m_flw, m_fld);
        if (n > 0) begin
            $display("  MEAN FRAME PERIOD   = %0d cycles (SOP-to-SOP)", sum_p / n);
            $display("  PAYLOAD RATE        = %0.1f Mbps",
                      (1472.0 * 8.0) / ((sum_p * 1.0 / n) * 6.4e-9) / 1e6);
            $display("  WIRE-CONTENT RATE   = %0.1f Mbps (1514 B content)",
                      (1514.0 * 8.0) / ((sum_p * 1.0 / n) * 6.4e-9) / 1e6);
        end
        $display("CHAINRATE DONE");
        $finish;
    end
endmodule
