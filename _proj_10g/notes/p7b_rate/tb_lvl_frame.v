`timescale 1ns/1ps
// ===========================================================================
// 逐级速率测量 #2 —— rtl/udp_tx_frame.v **单独** (帧级 store-and-forward 组帧器)
// ---------------------------------------------------------------------------
// 上游 = **无限就绪字源** (每拍 1 个字, 零空隙, 184 字/帧, 末字带 tlast)
//   —— 刻意比 app 发生器快 8 倍, 用来测"帧器自身的天花板"。
// 下游 m_axis_tready **恒 1**。
// 判据: m_axis_tlast 消费拍的**拍间差** = 帧器一帧占用的拍数。
// 时钟 6.4ns = 156.25 MHz (与板级 dp_clk 同频)。
// ===========================================================================
module tb_lvl_frame;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns

    // ---- 无限就绪的上游 (184 字/帧 @1472B) ----
    localparam integer NW = 184;
    reg  [63:0] s_d;
    reg  [7:0]  s_k;
    reg         s_v, s_l;
    wire        s_r;
    integer     wi;
    // ⚠️ 这些声明必须在实例化**之前** —— 否则端口连接会造出隐式 1 位网 (本工程坑 24)
    wire [63:0] m_td;  wire [7:0] m_tk;
    wire        m_tv, m_tl;
    wire [31:0] u_frames, u_bytes, u_drop;
    wire        u_busy;

    udp_tx_frame u_utx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_d), .s_axis_tkeep(s_k), .s_axis_tvalid(s_v),
        .s_axis_tready(s_r), .s_axis_tlast(s_l),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_dst_mac(48'h112233445566),
        .cfg_src_ip(32'hC0A86402),      .cfg_dst_ip(32'hC0A86401),
        .cfg_src_port(16'h1F91),        .cfg_dst_port(16'h1F91),
        .cfg_csum_en(1'b1),
        .m_axis_tdata(m_td), .m_axis_tkeep(m_tk), .m_axis_tvalid(m_tv),
        .m_axis_tready(1'b1), .m_axis_tlast(m_tl),
        .stat_frames(u_frames), .stat_bytes(u_bytes),
        .stat_drop_len(u_drop), .o_busy(u_busy)
    );

    // ---- 源驱动 (寄存器化: 与 DUT 同沿对齐, 坑 3/17) ----
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

    // ---- 测量: m_tlast 被消费的拍间差 = 帧器周期 ----
    integer cyc, n, last_cyc, sum_p, nfr;
    reg prev_last;

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; n <= 0; last_cyc <= 0; sum_p <= 0; nfr <= 0;
            prev_last <= 1'b0;
        end else begin
            cyc <= cyc + 1;
            prev_last <= (m_tv && m_tl);            // m_axis_tready 恒 1
            if (m_tv && m_tl) begin
                nfr <= nfr + 1;
                if (nfr >= 4) begin
                    sum_p <= sum_p + (cyc - last_cyc);
                    n     <= n + 1;
                end
                last_cyc <= cyc;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        while ((n < 20) && (cyc < 60000)) @(posedge clk);
        $display("--- tb_lvl_frame: udp_tx_frame ONLY (infinite-ready source) ---");
        $display("  clk period          = 6.400 ns (156.25 MHz)");
        $display("  frames measured     = %0d (utx stat_frames=%0d drop=%0d)",
                 n, u_frames, u_drop);
        if (n > 0) begin
            $display("  MEAN FRAME PERIOD   = %0d cycles", sum_p / n);
            $display("  PAYLOAD RATE        = %0.1f Mbps",
                      (1472.0 * 8.0) / ((sum_p * 1.0 / n) * 6.4e-9) / 1e6);
            $display("  WIRE-CONTENT RATE   = %0.1f Mbps (1514 B content)",
                      (1514.0 * 8.0) / ((sum_p * 1.0 / n) * 6.4e-9) / 1e6);
        end
        $display("LVLFRAME DONE");
        $finish;
    end
endmodule
