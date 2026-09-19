`timescale 1ns/1ps
//=============================================================================
// tb_p5_pattern: app_pattern TX 侧 AXIS 合同单元门 (P5a 复核 W3)
//
// 验什么: 对端关闭 (ev_down) 落在"帧中途"时, app 必须**收尾当前帧**再停:
//   - 若正有字在呈交 (pw_valid): 该字带 tlast 被消费后 tvalid 才落 (AXIS 不违约)
//   - 若正装配中 (无字): 合成一个 keep=0 + tlast 的收尾字 (帧器按 0 字节收帧)
//   - 无论哪条路径: **绝不能出现"tvalid 落而最后消费的 beat 无 tlast"**
//     (原实现 ev_down 直接撤 pw_valid => tcp_tx_frame 卡 S_RECV, 下一帧首字
//      被当续载荷吞掉)
// 两个子例: ① m_tready 常 1 (关闭落在呈交拍) ② 关闭时 m_tready=0 压住再放开
//=============================================================================
module tb_p5_pattern;
    reg clk, rst_n;
    reg        ev_up, ev_down;
    reg [3:0]  ev_slot;
    reg [15:0] app_tx_ready;
    reg        m_tready;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [3:0]  m_tid;
    wire        rx_tready;

    app_pattern #(.TX_BYTES(32'd20000), .TX_SEGSZ(12'd1460)) u_app (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast), .m_tid(m_tid),
        .app_tx_ready(app_tx_ready),
        .close_req(), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0),
        .rx_tready(rx_tready), .rx_tlast(1'b0), .rx_tid(4'd0),
        .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(), .stat_mismatch(),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led()
    );

    always #4 clk = ~clk;

    // AXIS 合同监视:
    //   viol    = tvalid 在**未被消费**的情况下撤除 (真正的 AXIS 违约 —
    //             注意"被消费后撤 valid 去装配下一个字"是合法的, 不记)
    //   last_beats = 带 tlast 的消费拍数 (= 收尾帧数)
    integer beats, last_beats, viol;
    reg     tv_d, acc_d;
    always @(posedge clk) begin
        if (!rst_n) begin
            beats <= 0; last_beats <= 0; viol <= 0; tv_d <= 1'b0; acc_d <= 1'b0;
        end else begin
            tv_d  <= m_tvalid;
            acc_d <= m_tvalid && m_tready;         // 上一拍是否被消费
            if (m_tvalid && m_tready) begin
                beats <= beats + 1;
                if (m_tlast) last_beats <= last_beats + 1;
            end
            if (tv_d && !m_tvalid && !acc_d) viol <= viol + 1;
        end
    end

    integer k;
    reg [7:0] keep_bad;
    always @(posedge clk) begin
        if (rst_n && m_tvalid && (m_tkeep == 8'h00) && !m_tlast)
            keep_bad <= keep_bad + 1;      // keep=0 只允许出现在收尾字 (带 tlast)
    end

    task frame_beats;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) @(posedge clk);
        end
    endtask

    integer b0, b1;
    initial begin
        clk = 0; rst_n = 0; ev_up = 0; ev_down = 0; ev_slot = 4'd0;
        app_tx_ready = 16'h0001; m_tready = 1'b1; keep_bad = 0;
        #200; rst_n = 1;
        repeat (20) @(posedge clk);

        // ============ 子例 ①: m_tready 常 1, 关闭落在呈交中 ============
        @(posedge clk); ev_up <= 1'b1;
        @(posedge clk); ev_up <= 1'b0;
        frame_beats(400);                       // 让它发几十拍
        b0 = beats;
        @(posedge clk); ev_down <= 1'b1; ev_slot <= 4'd0;
        @(posedge clk); ev_down <= 1'b0;
        frame_beats(200);
        $display("W3 case1: beats %0d -> %0d, last_beats=%0d, viol=%0d keep_bad=%0d active=%b",
                 b0, beats, last_beats, viol, keep_bad, u_app.active);

        // ============ 子例 ②: 关闭时 m_tready=0 压住 (装配中) ============
        keep_bad = 0;
        @(posedge clk); ev_up <= 1'b1;
        @(posedge clk); ev_up <= 1'b0;
        frame_beats(200);
        // 压住 tready (帧中途), 再关
        @(posedge clk); m_tready <= 1'b0;
        frame_beats(50);
        @(posedge clk); ev_down <= 1'b1; ev_slot <= 4'd0;
        @(posedge clk); ev_down <= 1'b0;
        frame_beats(50);
        @(posedge clk); m_tready <= 1'b1;       // 放开: 收尾字应被消费
        frame_beats(200);
        $display("W3 case2: beats=%0d last_beats=%0d viol=%0d keep_bad=%0d active=%b",
                 beats, last_beats, viol, keep_bad, u_app.active);
        frame_beats(100);

        if (viol == 0 && last_beats >= 2 && keep_bad == 0 && !u_app.active)
            $display("P5 PATTERN OK (ev_down 收尾: 无 AXIS 违约, 无 keep=0 非收尾字)");
        else
            $display("P5 PATTERN FAIL viol=%0d last_beats=%0d keep_bad=%0d active=%b",
                     viol, last_beats, keep_bad, u_app.active);
        $finish;
    end
endmodule
