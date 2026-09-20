`timescale 1ns/1ps
//=============================================================================
// tb_p5d_d1 — P5d-D1 定向门: TX 启动/接受门的两个缺口 (tcp_tx_frame 单元级)
//
// 缺陷① (abort 请求窗): P5c-T3 G3 的 fence 只覆盖 rst_sent_r = "RST 已发出"。
//   RST 要等一次扫描 (256 拍) + 组装才上线 ⇒ [rst_req 挂起, RST 上线] 期间该连接
//   的数据帧照样能起、字照样被接受 ⇒ 给一个已被 app 中止的连接发数据帧。
//   修法: tx_blk 加 rst_req (与 s_axis_tready 共享同一表达式 ⇒ 同门, 坑 10)。
//
// 缺陷② (残余 F 项, 需 APP_MODE): fin_push 在扫描拍 T 把 FIN 条目写进 ackq;
//   T+1 拍 ack_pend_r 仍是旧值 0 (寄存器陈旧性 + fifo_sync 的 empty 由寄存器指针
//   算) ⇒ 若此刻 fin_req 已被 app 清掉而 fin_sent_r 仍 0, 数据帧能起。
//   修法: 启动/接受门再要求该连接 ESTAB (只对 start_id 那一位, 见 RTL 注释)。
//
// 门判据 (只看 DUT 的 AXIS 帧流 + 少量端口; 内部信号仅用于 D2 的激励对齐):
//   D1a 正对照: 无请求 ⇒ 数据帧 1 个, 载荷逐字节正确
//   D1b abort 窗: rst_req[0]=1 后 400 拍内 tready 恒 0、无新数据帧; RST 帧照样上线
//   D1c 释放: 清 rst_req + cfg_up ⇒ 数据帧恢复且逐字节正确 (同门判据)
//   D2  残余窗: fin_push 拍清 fin_req[1]/拉低 rb_state ⇒ FIN 之前不得有数据帧
//   D2b 释放: rb_state 回 1 + cfg_up ⇒ 数据帧恢复且逐字节正确
// 判据行: "GATE tb_p5d_d1: PASS" / "... FAIL" — bat 用 findstr 映射退出码。
// 编译: 必须 -d APP_MODE (板级 P5 构建; 缺陷② 的门只在该构建存在)。
//=============================================================================
module tb_p5d_d1;

    reg clk, rst_n;
    integer errs;
    integer i;
    reg [255:0] cname;

    // ---------------- 时钟 ----------------
    always #4 clk = ~clk;

    // ---------------- 工具 ----------------
    task chk;
        input        cond;
        input [255:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin
                errs = errs + 1;
                $display("  FAIL %0s", name);
            end
        end
    endtask

    // ---------------- DUT 激励 (常量 TCB/CAM: 本门只测 TX 门) ----------------
    // conn0/conn1: snd_nxt == snd_una (无在飞 ⇒ 不触发 RTO/svc), snd_wnd != 0
    reg  [31:0] rb_snd_nxt = 32'h0000_1000;
    reg  [31:0] rb_snd_una = 32'h0000_1000;
    reg  [31:0] rb_rcv_nxt = 32'h0000_2000;
    reg  [15:0] rb_rcv_wnd = 16'hC000;
    reg  [15:0] rb_snd_wnd = 16'h4000;
    reg  [3:0]  rb_state   = 4'd1;        // ESTAB (D2 在 fin_push 拍才拉低)
    wire [3:0]  rb_id;

    reg  [15:0] rst_req, fin_req;
    reg         cfg_up;
    reg  [3:0]  cfg_up_id;
    wire [15:0] o_fin_sent, o_rst_sent;

    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid, s_tlast;
    reg  [3:0]  s_tid;
    wire        s_tready;                 // 注意: tready 是 wire, 监视用

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire        m_tready = 1'b1;          // 消费端永远就绪 (只看帧流)

    wire [3:0]  cam_rd_id;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    wire [31:0] tx_stat_eend, tx_stat_drop_len, tx_stat_fin, tx_stat_rst;
    wire [31:0] tx_stat_retx;
    wire [31:0] tx_retx_hi;
    wire        tx_retx_active, tx_retx_gnt;
    wire [3:0]  tx_retx_id;
    wire        dbg_pay_empty;

    tcp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tid(s_tid),
        .ack_req(1'b0), .ack_id(4'd0), .ack_val(32'd0), .ack_syn(1'b0),
        .ack_fin(1'b0), .ack_rst(1'b0),
        .fin_req(fin_req), .rst_req(rst_req),
        .cfg_up(cfg_up), .cfg_up_id(cfg_up_id),
        .o_fin_sent(o_fin_sent), .o_rst_sent(o_rst_sent),
        .wu_req(1'b0), .wu_id(4'd0), .wu_val(32'd0), .wu_gnt(),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una),
        .rb_snd_wnd(rb_snd_wnd), .rb_state(rb_state),
        .win_open(1'b1), .win_inflight(16'd0), .win_wnd_eff(16'd0),
        .retx_req(1'b0), .retx_id(4'd0), .retx_gnt(tx_retx_gnt),
        .stat_retx(tx_stat_retx),
        .o_retx_hi(tx_retx_hi), .o_retx_active(tx_retx_active),
        .o_retx_id(tx_retx_id),
        .upd_wr(), .upd_id(), .upd_sel(), .upd_val(),
        .cam_rd_id(cam_rd_id),
        .cam_rd_dmac(48'h112233445566), .cam_rd_sip(32'h0A000001),
        .cam_rd_sport(16'h1234), .cam_rd_dport(16'h5678),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop),
        .stat_eend(tx_stat_eend),
        .stat_drop_len(tx_stat_drop_len), .stat_fin(tx_stat_fin),
        .stat_rst(tx_stat_rst), .stat_tlast_in(),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(dbg_pay_empty), .dbg_plen()
    );

    // ---------------- 帧流监视 (从 AXIS 字流重建帧级事实) ----------------
    // 头 = 54 字节: b0..b5 (48B) + b6 高 6 字节; 载荷从 b6 低 2 字节开始。
    // 8 字节载荷 ⇒ 62 字节帧 ⇒ 8 拍, 末拍 tkeep=FC。
    reg [3:0]  beat;
    reg [7:0]  cur_flags;
    reg [63:0] cur_b6, cur_b7;
    reg [7:0]  l_flags;      // 最近一帧: flags
    reg [63:0] l_b6, l_b7;   // 最近一帧: b6/b7
    reg [15:0] l_beats;
    reg [15:0] n_frm, n_data, n_fin, n_rst;
    reg [31:0] tready_hi;    // s_axis_tready 高的拍数 (窗口自检)

    // D2 探针: "FIN 之前出现了数据帧"
    reg        d2_armed;
    reg [15:0] d2_nd0, d2_nf0;
    reg        d2_bad;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat <= 4'd0; cur_flags <= 8'd0; cur_b6 <= 64'd0; cur_b7 <= 64'd0;
            l_flags <= 8'd0; l_b6 <= 64'd0; l_b7 <= 64'd0; l_beats <= 16'd0;
            n_frm <= 16'd0; n_data <= 16'd0; n_fin <= 16'd0; n_rst <= 16'd0;
            tready_hi <= 32'd0; d2_bad <= 1'b0;
        end else begin
            if (m_tvalid && m_tready) begin
                if (beat == 4'd5) cur_flags <= m_tdata[7:0];
                if (beat == 4'd6) cur_b6 <= m_tdata;
                if (beat == 4'd7) cur_b7 <= m_tdata;
                beat <= beat + 4'd1;
                if (m_tlast) begin
                    l_beats <= {12'b0, beat} + 16'd1;
                    l_b6    <= (beat == 4'd6) ? m_tdata : cur_b6;
                    l_b7    <= (beat == 4'd7) ? m_tdata : cur_b7;
                    l_flags <= (beat == 4'd5) ? m_tdata[7:0] : cur_flags;
                    beat    <= 4'd0;
                    n_frm   <= n_frm + 16'd1;
                    if (((beat == 4'd5) ? m_tdata[7:0] : cur_flags) == 8'h18)
                        n_data <= n_data + 16'd1;
                    if (((beat == 4'd5) ? m_tdata[7:0] : cur_flags) == 8'h11)
                        n_fin <= n_fin + 16'd1;
                    if (((beat == 4'd5) ? m_tdata[7:0] : cur_flags) == 8'h14)
                        n_rst <= n_rst + 16'd1;
                    // D2 判据: 本帧在 FIN 之前落地 ⇒ 残余窗被利用
                    if (d2_armed && (n_fin == d2_nf0) &&
                        (((beat == 4'd5) ? m_tdata[7:0] : cur_flags) == 8'h18))
                        d2_bad <= 1'b1;
                end
            end
            // 只统计"展示期 (tvalid=1) tready 为高"的拍 = 字被吃掉的拍。
            // (tvalid=0 时 DUT 的 tready 本来就是 1 = 空闲就绪, 不是接受事件)
            if (s_tvalid && s_tready) tready_hi <= tready_hi + 32'd1;
        end
    end

    // ---------------- D2 激励对齐 (只看内部 fin_push 一拍) ----------------
    // fin_push = "FIN 条目**确实写进 ackq**" 的拍。残余窗要在这里清 fin_req +
    // 拉低 rb_state (app_ctrl 清 fin_req 是与扫描无关的异步事件, 这里对齐到最坏
    // 位置 = 恰好 T, 即 T+1 的空档被完全暴露)。判据本身不依赖内部信号。
    reg d2_wait;
    always @(posedge clk) begin
        if (d2_wait && u_tx.fin_push) begin
            d2_wait   <= 1'b0;
            d2_armed  <= 1'b1;
            d2_nd0    <= n_data;
            d2_nf0    <= n_fin;
            fin_req[1] <= 1'b0;        // app 侧清请求 (app_ctrl.v:937 语义)
            rb_state   <= 4'd0;        // 连接已拆 (DEL 写 state=0)
        end
    end

    // ---------------- 载荷图案 (8 字节) ----------------
    localparam [63:0] PAT = 64'hA1A2A3A4A5A6A7A8;

    // 呈交一帧并等消费 (presenting 契约: tready=0 时保持稳定)
    task present;
        input [3:0] id;
        input integer maxc;
        integer g;
        begin
            s_tdata <= PAT; s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tid <= id;
            s_tvalid <= 1'b1;
            @(posedge clk);              // 让 tvalid/tid 生效一拍再判 tready
                                         // (tready 是组合输出, 与 tvalid 无关 —
                                         //  不先等一拍会在陈旧 tready 上假通过)
            g = 0;
            while (!s_tready && (g < maxc)) begin @(posedge clk); g = g + 1; end
            if (s_tready) begin @(posedge clk); end   // 消费拍
            s_tvalid <= 1'b0;
            @(posedge clk);
        end
    endtask

    task wait_frame;
        input [15:0] target;
        input integer maxc;
        integer g;
        begin
            g = 0;
            while ((n_frm < target) && (g < maxc)) begin @(posedge clk); g = g + 1; end
        end
    endtask

    task wait_nfin;
        input [15:0] target;
        input integer maxc;
        integer g;
        begin
            g = 0;
            while ((n_fin < target) && (g < maxc)) begin @(posedge clk); g = g + 1; end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        s_tdata = 64'd0; s_tkeep = 8'd0; s_tvalid = 1'b0; s_tlast = 1'b0;
        s_tid = 4'd0; rst_req = 16'd0; fin_req = 16'd0;
        cfg_up = 1'b0; cfg_up_id = 4'd0; d2_wait = 1'b0; d2_armed = 1'b0;
        #100; rst_n = 1;
        repeat (20) @(posedge clk);

        // ============ D1a: 正对照 — 无请求时数据帧可发 (逐字节) ============
        $display("D1a: baseline (rst_req=0) -- tid=0 data frame");
        present(4'd0, 200);
        wait_frame(16'd1, 400);
        chk(n_frm == 16'd1, "D1a-1 data frame sent (nfrm=1)");
        chk(l_flags == 8'h18, "D1a-2 flags=0x18 (PSH+ACK)");
        chk(tx_stat_bytes == 32'd8, "D1a-3 stat_bytes=8 (plen ok)");
        chk((l_b6[15:0] == PAT[63:48]) && (l_b7[63:16] == PAT[47:0]),
            "D1a-4 payload byte exact");

        // ============ D1b: abort 请求窗 — RST 上线前不得起数据帧 ============
        // rst_req[0] 与 tvalid 同拍挂起, 持续 400 拍 (远长于一次扫描 + RST 组装)。
        // 修复前: T+1 拍 (ack_pend_r 还陈旧) 数据帧就能起 ⇒ 本项 FAIL。
        $display("D1b: rst_req[0]=1 and keep pushing tid=0 -- tready must stay 0, no new data frame");
        tready_hi = 32'd0;
        rst_req <= 16'h0001;
        s_tdata <= PAT; s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tid <= 4'd0;
        s_tvalid <= 1'b1;
        repeat (400) @(posedge clk);
        chk(tready_hi == 32'd0, "D1b-1 s_axis_tready==0 over the whole abort window (accept gate = fence)");
        chk(n_data == 16'd1, "D1b-2 zero new data frames (start gate is the same gate)");
        chk(n_rst == 16'd1, "D1b-3 RST frame still on the wire (fence does not block the ACK/RST path)");
        chk(o_rst_sent[0] == 1'b1, "D1b-4 o_rst_sent[0]=1 (RST sent)");
        chk(tx_stat_frames == 32'd2, "D1b-5 stat_frames=2 (1 data + 1 RST)");
        chk(dbg_pay_empty == 1'b1, "D1b-6 payload FIFO empty (no word swallowed while presenting)");
        $display("DBG D1b: tready_hi=%0d n_data=%0d n_rst=%0d frames=%0d rst_sent=%04x",
                 tready_hi, n_data, n_rst, tx_stat_frames, o_rst_sent);
        s_tvalid <= 1'b0;
        @(posedge clk);

        // ============ D1c: 释放 — 清请求 + cfg_up ⇒ 帧恢复且逐字节正确 ========
        // 同门判据 (坑 10): 若展示期接受门比启动门宽, 被吞的字会让本帧错位/截断。
        $display("D1c: clear rst_req + cfg_up -- tid=0 frame resumes");
        rst_req <= 16'd0;
        cfg_up <= 1'b1; cfg_up_id <= 4'd0;
        @(posedge clk); cfg_up <= 1'b0;
        @(posedge clk);
        chk(o_rst_sent[0] == 1'b0, "D1c-1 cfg_up clears o_rst_sent[0]");
        present(4'd0, 200);
        wait_frame(16'd3, 400);
        chk(n_frm == 16'd3, "D1c-2 frame resumes (nfrm=3)");
        chk(l_flags == 8'h18, "D1c-3 flags=0x18");
        chk((l_b6[15:0] == PAT[63:48]) && (l_b7[63:16] == PAT[47:0]),
            "D1c-4 payload byte exact (no shift, no swallowed word)");
        chk(tx_stat_bytes == 32'd16, "D1c-5 stat_bytes=16 (two data frames)");
        chk(tx_stat_eend == 32'd0, "D1c-6 stat_eend=0 (no underrun/truncated frame)");

        // ============ D2: 残余窗 — fin_push 拍清 fin_req + 拆连 ============
        // 修法② (APP_MODE 状态门) 的判据: 窗口里不得起数据帧, 且 FIN 必须照常上线。
        $display("D2: clear fin_req[1] AT the fin_push beat + rb_state=0 -- no data frame before the FIN");
        fin_req <= 16'h0002;              // tid=1 的 FIN 请求 (snd_nxt==snd_una ⇒ 排队)
        s_tdata <= PAT; s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tid <= 4'd1;
        s_tvalid <= 1'b1;
        @(posedge clk);
        d2_wait <= 1'b1;                  // 武装: 下一个 fin_push 拍触发
        // 等到 FIN 上线 (最多 2000 拍 = 数次扫描)
        wait_nfin(16'd1, 2000);
        repeat (60) @(posedge clk);       // 观察窗: FIN 之后也不得冒出数据帧
        chk(n_fin == 16'd1, "D2-1 FIN frame on the wire (fence does not block FIN)");
        chk(d2_bad == 1'b0, "D2-2 no data frame before the FIN (residual window closed)");
        chk(n_data == 16'd2, "D2-3 zero new data frames (only the D1a/D1c ones)");
        chk(tx_stat_fin == 32'd1, "D2-4 stat_fin=1");
        chk(dbg_pay_empty == 1'b1, "D2-5 payload FIFO empty");
        $display("DBG D2: n_data=%0d n_fin=%0d d2_bad=%0b frames=%0d",
                 n_data, n_fin, d2_bad, tx_stat_frames);
        s_tvalid <= 1'b0;
        @(posedge clk);

        // ============ D2b: 释放 — rb_state 回 1 + cfg_up ⇒ 帧恢复 ============
        $display("D2b: rb_state back to 1 + cfg_up -- tid=1 frame resumes (byte exact)");
        rb_state <= 4'd1;
        cfg_up <= 1'b1; cfg_up_id <= 4'd1;
        @(posedge clk); cfg_up <= 1'b0;
        @(posedge clk);
        chk(o_fin_sent[1] == 1'b0, "D2b-1 cfg_up clears o_fin_sent[1]");
        present(4'd1, 200);
        wait_frame(16'd5, 400);
        chk(n_frm == 16'd5, "D2b-2 frame resumes (nfrm=5)");
        chk(l_flags == 8'h18, "D2b-3 flags=0x18");
        chk((l_b6[15:0] == PAT[63:48]) && (l_b7[63:16] == PAT[47:0]),
            "D2b-4 payload byte exact");
        chk(tx_stat_eend == 32'd0, "D2b-5 stat_eend=0");
        $display("DBG D2b: frames=%0d bytes=%0d flags=%02x",
                 tx_stat_frames, tx_stat_bytes, l_flags);

        repeat (20) @(posedge clk);
        $display("GATE tb_p5d_d1: %0s", (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
