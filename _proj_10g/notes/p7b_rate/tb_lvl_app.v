`timescale 1ns/1ps
// ===========================================================================
// 逐级速率测量 #1 —— rtl/app_udp_pattern.v 的 **TX 图案发生器单独**
// ---------------------------------------------------------------------------
// 配置刻意与板级同构: i_en=1 / i_tx_ready=1 (peer 表已学习) / i_paylen=1472 /
//   TX_BYTES=0 (连续) / TX_GAP=0 (全速)。
// 下游 m_tready **恒 1** ⇒ 生成器的 256x73 字 FIFO 永不满 ⇒ 本 TB 测到的
//   就是**发生器自身的天花板**(只受 "每拍产 1 字节" 的限制)。
// 判据: stat_tx_frames 每 +1 的**拍间差** = 生成一帧所占拍数 (纯本地口径)。
// 时钟 6.4ns = 156.25 MHz —— **与板级 dp_clk 同频**。
// ===========================================================================
module tb_lvl_app;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    wire [63:0] a_td;  wire [7:0] a_tk;
    wire        a_tv, a_tl;
    wire [31:0] a_txb, a_txf, a_rxb, a_rxf, a_rxn, a_mm;
    wire        a_act, a_done;  wire [3:0] a_led;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b1), .i_paylen(12'd1472),
        .m_tdata(a_td), .m_tkeep(a_tk), .m_tvalid(a_tv), .m_tready(1'b1),
        .m_tlast(a_tl),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_txb), .stat_tx_frames(a_txf),
        .stat_rx_bytes(a_rxb), .stat_rx_frames(a_rxf), .stat_rx_null(a_rxn),
        .stat_mismatch(a_mm), .active(a_act), .done(a_done), .led(a_led)
    );

    // ---- 测量 (声明先于 always: xvlog 先声明后用) ----
    integer cyc, nfr, n, last_cyc;
    integer sum_p;
    reg [31:0] prev_f;

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; nfr <= 0; n <= 0; last_cyc <= 0; sum_p <= 0;
            prev_f <= 32'd0;
        end else begin
            cyc <= cyc + 1;
            if (a_txf != prev_f) begin
                prev_f <= a_txf;
                nfr    <= nfr + 1;
                if (nfr >= 4) begin           // 跳过前 4 帧热机
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
        while ((n < 20) && (cyc < 200000)) @(posedge clk);
        $display("--- tb_lvl_app: app_udp_pattern TX generator ONLY ---");
        $display("  clk period          = 6.400 ns (156.25 MHz)");
        $display("  frames measured     = %0d", n);
        if (n > 0) begin
            $display("  MEAN FRAME PERIOD   = %0d cycles", sum_p / n);
            $display("  CYCLES PER PAYLOAD B= %0.4f  (1472 B/frame)",
                      (sum_p * 1.0 / n) / 1472.0);
            $display("  PAYLOAD RATE        = %0.1f Mbps",
                      (1472.0 * 8.0) / ((sum_p * 1.0 / n) * 6.4e-9) / 1e6);
        end
        $display("  app stat_tx_frames=%0d stat_tx_bytes=%0d", a_txf, a_txb);
        $display("LVLAPP DONE");
        $finish;
    end
endmodule
