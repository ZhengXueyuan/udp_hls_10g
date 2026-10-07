`timescale 1ns/1ps
// ===========================================================================
// tb_rx8_evphase_review.v -- 对抗审查用**反例 TB** (Stage B/R1, RX 8 路)
// ---------------------------------------------------------------------------
// 目的: 作者的门只覆盖 "ev_up 落在**握手拍**" 这一格 (tb_app_rx8_equiv 的 u_ev)。
//   本 TB 加一格作者没测的相位: **ev_up 落在握手之后的比较窗内** (只在默认
//   (逐字节) 构建里存在这个窗) —— 判据是 A(默认) vs B(P7B_10G) 的 dump/stats
//   是否**逐字节相同** (与作者门的判据形态一致)。
//
// 两个实例 (同一条队列内容, 字间 12 拍间隙 ⇒ 两构建的握手时刻逐拍相同):
//   u_ctrl = ev_up 压在**握手拍** (控制组; 作者门已覆盖 ⇒ 期望 A≡B)
//   u_mid  = ev_up 压在握手后 **3 拍** (默认构建此刻 rxs==1 正在逐字节比
//            ⇒ 撞车; P7B_10G 构建此刻空闲 ⇒ 复位照常生效)
// 队列: word0..1 = 旧流(SEED 连续), word2..5 = 从 SEED **重开**的新流
//   (模型: 新连接 = 图案流从起点重开 —— 与作者 u_ev 的语义相同)。
//
// 输出: acc_ctrl.txt / acc_mid.txt (被接受字流) + stats.txt (计数) + 一行
//   MID-TREADY 证据 (ev_up 那一拍两个实例的 rx_tready: 0 = 正在比较态)。
// ===========================================================================
module tb_rx8_evphase_review;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    localparam [63:0] SEED = 64'h9E3779B97F4A7C15;
    localparam integer NW   = 6;            // 每实例字数
    localparam integer GAP  = 12;           // 字间间隙 (拍)
    localparam integer CY   = 4000;

    function [63:0] xs_next;
        input [63:0] s;  reg [63:0] t;
        begin t = s ^ (s << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next = t; end
    endfunction

    // ---- 队列内容 (纯组合的常量表, 由顺序模型在 time 0 造好) ----
    reg [63:0] qd [0:NW-1];
    reg [7:0]  qk [0:NW-1];
    integer k;
    reg [63:0] m;
    integer i;
    initial begin
        m = SEED;
        for (k = 0; k < NW; k = k + 1) begin
            if (k == 2) m = SEED;                 // word2 起 = 新流重开
            qd[k] = 64'd0;
            for (i = 0; i < 8; i = i + 1) begin
                qd[k] = {qd[k][55:0], m[31:24]};
                m = xs_next(m);
            end
            qk[k] = 8'hFF;
        end
    end

    // ---- 实例 3 (构造性覆盖探针): 跨字边界注入 ----
    //   word1 的 lane7 (bit0) 与 word2 的 lane0 (bit56) 各翻 1 位
    //   ⇒ 期望 mm == 2 (每个字内部"末 lane / 首 lane"都真的被比到)。
    reg [63:0] xd [0:3];
    reg [7:0]  xk [0:3];
    initial begin
        m = SEED;
        for (k = 0; k < 4; k = k + 1) begin
            xd[k] = 64'd0;
            for (i = 0; i < 8; i = i + 1) begin
                xd[k] = {xd[k][55:0], m[31:24]};
                m = xs_next(m);
            end
            xk[k] = 8'hFF;
        end
        xd[1] = xd[1] ^ 64'h0000_0000_0000_0001;   // word1 lane7
        xd[2] = xd[2] ^ 64'h0100_0000_0000_0000;   // word2 lane0
    end

    // ---- 实例 1: 控制组 (ev_up 压在**握手拍**) ----
    //   word2 = 新流 (SEED 重开) 首字 ⇒ ev_up 与它同拍 (作者 u_ev 同款布局)。
    reg  c_dr;  integer c_p, c_g;  reg [3:0] c_n;
    wire [31:0] c_rxb, c_mm, m_rxb, m_mm;
    wire c_tr_w, m_tr_w;
    wire c_hs = c_dr & c_tr_w;
    wire c_ev = (c_n == 4'd2) && c_hs;

    // ---- 实例 2: 相位组 (ev_up 在 word2 握手后**第 4 拍**) ----
    //   默认 (逐字节) 构建: 该拍 rxs==1 (正在比 word2) ⇒ 撞车;
    //   P7B_10G 构建:      该拍空闲 (12 拍字间隙) ⇒ 复位照常生效。
    reg  m_dr;  integer m_p, m_g;  reg [2:0] m_arm;
    reg  m_fired;
    wire m_hs = m_dr & m_tr_w;
    wire m_ev = (m_arm == 3'd1);

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_ctrl (.clk(clk), .rst_n(rst_n), .ev_up(c_ev), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(qd[c_p]), .rx_tkeep(qk[c_p]), .rx_tvalid(c_dr), .rx_tready(c_tr_w),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(c_rxb), .stat_mismatch(c_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_mid (.clk(clk), .rst_n(rst_n), .ev_up(m_ev), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(qd[m_p]), .rx_tkeep(qk[m_p]), .rx_tvalid(m_dr), .rx_tready(m_tr_w),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(m_rxb), .stat_mismatch(m_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    reg x_dr;  integer x_p;  wire x_tr_w;
    wire [31:0] x_rxb, x_mm;
    wire x_hs = x_dr & x_tr_w;
    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_cross (.clk(clk), .rst_n(rst_n), .ev_up(1'b0), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(xd[x_p]), .rx_tkeep(xk[x_p]), .rx_tvalid(x_dr), .rx_tready(x_tr_w),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(x_rxb), .stat_mismatch(x_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    // ---- 驱动 (只有真握手才推进; 全部 NBA) ----
    always @(posedge clk) begin
        if (!rst_n) begin c_dr <= 1'b0; c_g <= 0; c_p <= 0; c_n <= 4'd0; end
        else if (c_p < NW) begin
            if (c_dr) begin
                if (c_tr_w) begin c_p <= c_p + 1; c_dr <= 1'b0; c_g <= GAP;
                              if (c_n < 4'd15) c_n <= c_n + 4'd1; end
            end else if (c_g != 0) c_g <= c_g - 1;
            else c_dr <= 1'b1;
        end else c_dr <= 1'b0;
    end
    always @(posedge clk) begin
        if (!rst_n) begin m_dr <= 1'b0; m_g <= 0; m_p <= 0; m_arm <= 3'd0; m_fired <= 1'b0; end
        else begin
            // word2 的握手 (m_p==2 且握手) 后**第 4 拍**单发一个 ev_up 脉冲:
            //   握手拍 T ⇒ 装 m_arm=4 ⇒ 递减 ⇒ 第 4 拍 (T+4) 时 m_arm==1 ⇒ m_ev=1。
            if (m_hs && (m_p == 2) && !m_fired) begin
                m_arm   <= 3'd4;  m_fired <= 1'b1;
            end else if (m_arm != 3'd0) begin
                m_arm <= m_arm - 3'd1;
            end
            if (m_p < NW) begin
                if (m_dr) begin
                    if (m_tr_w) begin m_p <= m_p + 1; m_dr <= 1'b0; m_g <= GAP; end
                end else if (m_g != 0) m_g <= m_g - 1;
                else m_dr <= 1'b1;
            end else m_dr <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin x_dr <= 1'b0; x_p <= 0; end
        else if (x_p < 4) begin
            if (x_dr) begin if (x_tr_w) begin x_p <= x_p + 1;
                x_dr <= ((x_p + 1) < 4); end end
            else x_dr <= 1'b1;
        end else x_dr <= 1'b0;
    end

    // ---- 证据: ev_up 那一拍两个实例的 rx_tready (0 = 该构建此刻在比较态) ----
    //   c_ev: 与握手同拍 ⇒ 两构建都应看到 tready=1 (握手拍);
    //   m_ev: 默认构建应看到 tready=0 (正在逐字节比 ⇒ 撞车), P7B_10G 应看到 1。
    reg done_ev_print;
    always @(posedge clk) begin
        if (rst_n && c_ev && !done_ev_print) begin
            $display("EVID ctrl ev_cycle: tready_ctrl=%b (expect 1 = 握手拍)", c_tr_w);
        end
        if (rst_n && m_ev && !done_ev_print) begin
            done_ev_print <= 1'b1;
            $display("EVID mid  ev_cycle: tready_mid=%b (default=0 撞车 / P7B10G=1 空闲)", m_tr_w);
        end
    end

    // ---- dump ----
    integer f_c, f_m, f_s;
    integer cn, mn;
    initial begin
        rst_n = 1'b0; c_dr = 0; m_dr = 0; c_g = 0; m_g = 0; c_p = 0; m_p = 0;
        c_n = 0; m_arm = 0; m_fired = 0; done_ev_print = 0; cn = 0; mn = 0;
        f_c = $fopen("acc_ctrl.txt", "w"); f_m = $fopen("acc_mid.txt", "w");
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (CY) @(posedge clk);
        $fclose(f_c); $fclose(f_m);
        f_s = $fopen("stats.txt", "w");
        $fwrite(f_s, "CTRL rxb=%0d mm=%0d acc=%0d ev=%0d\n", c_rxb, c_mm, cn, c_n);
        $fwrite(f_s, "MID  rxb=%0d mm=%0d acc=%0d\n", m_rxb, m_mm, mn);
        $fwrite(f_s, "CROSS rxb=%0d mm=%0d (expect 32 / 2)\n", x_rxb, x_mm);
        $fclose(f_s);
        $display("CTRL rxb=%0d mm=%0d acc=%0d", c_rxb, c_mm, cn);
        $display("MID  rxb=%0d mm=%0d acc=%0d", m_rxb, m_mm, mn);
        $display("CROSS rxb=%0d mm=%0d (expect 32 / 2)", x_rxb, x_mm);
        $display("EVPHRASE DONE");
        $finish;
    end
    always @(posedge clk) if (rst_n) begin
        if (c_hs) begin $fwrite(f_c, "%08x_%08x %02x\n", qd[c_p][63:32], qd[c_p][31:0], qk[c_p]); cn = cn + 1; end
        if (m_hs) begin $fwrite(f_m, "%08x_%08x %02x\n", qd[m_p][63:32], qd[m_p][31:0], qk[m_p]); mn = mn + 1; end
    end
endmodule
