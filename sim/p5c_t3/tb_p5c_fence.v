`timescale 1ns/1ps
//=============================================================================
// tb_p5c_fence — P5c-T3 G3 定向门: abort 之后的 TX fence (tcp_tx_frame 侧)
//
// 缺陷 (G3): `rst_sent_r` 原先不进任何 TX 门 ⇒ RST 发出之后 app 继续推帧照样
// 能组帧发出 (数据/PSH 发给一个已被 RST 中止的连接 = 协议违规)。修法: 把
// `!rst_sent_r[start_id]` 同时加进 start_data **与** s_axis_tready (坑 10: 接受门
// 与启动门必须同门 — 否则字被吞进载荷 FIFO 却组不了帧 ⇒ FIFO 满 + FSM 卡 S_IDLE
// 死锁), 并给出 o_rst_sent 线束。
//
// 门判据 (只看 DUT 的 AXIS 帧流, 不依赖内部信号):
//   F1 基线: abort 之前数据帧可发 (帧数/载荷逐字节)
//   F2 abort: rst_req ⇒ RST 帧 (flags=0x14, plen=0) 且 o_rst_sent[0]=1
//   F3 fence: RST 之后推同连接数据帧 ⇒ s_axis_tready 全程 0 且无新帧
//   F4 旁路对照: 栏位来自 fence 而非其他因素 ⇒ 同窗口推**另一个**连接 (tid=1)
//      的帧照常被接受 (per-slot 黑名单)
//   F5 释放: cfg_up 脉冲清 rst_sent_r (同槽重连路径) ⇒ 帧恢复可发, 且载荷
//      **逐字节**正确 (= 接受门与启动门同门: 若接受门更宽, 之前展示期被吞掉的
//      字会让帧错位/截断 —— 坑 10 的判据)
//
// 自检: 打印 tready 高拍数 (F3 窗口内必须为 0) 与每帧 flags/载荷对账。
// 判据行: "GATE tb_p5c_fence: PASS" / "... FAIL" — bat 用 findstr 映射退出码。
//=============================================================================
module tb_p5c_fence;

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

    // ---------------- DUT 端口激励 (常量 TCB/CAM: 本门只测 TX fence) --------
    // 连接 0: snd_nxt == snd_una (无在飞 ⇒ 不会触发 RTO/FIN 路径), state=ESTAB
    // 连接 1: 同 (per-slot 对照)
    reg  [31:0] rb_snd_nxt = 32'h0000_1000;
    reg  [31:0] rb_snd_una = 32'h0000_1000;
    reg  [31:0] rb_rcv_nxt = 32'h0000_2000;
    reg  [15:0] rb_rcv_wnd = 16'hC000;
    reg  [15:0] rb_snd_wnd = 16'h4000;
    reg  [3:0]  rb_state   = 4'd1;
    wire [3:0]  rb_id;

    reg  [15:0] rst_req, fin_req;
    reg         cfg_up;
    reg  [3:0]  cfg_up_id;
    wire [15:0] o_fin_sent, o_rst_sent;

    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid, s_tlast;
    reg  [3:0]  s_tid;
    wire        s_tready;

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire        m_tready = 1'b1;         // 消费端永远就绪 (只看帧流)

    wire [3:0]  cam_rd_id;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    wire [31:0] tx_stat_eend, tx_stat_drop_len, tx_stat_fin, tx_stat_rst;
    wire [31:0] tx_stat_retx;
    wire [31:0] tx_retx_hi;
    wire        tx_retx_active, tx_retx_gnt;
    wire [3:0]  tx_retx_id;

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
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    // ---------------- 帧流监视 (从 AXIS 字流重建帧级事实) ----------------
    // 头 = 54 字节: b0..b5 (48B) + b6 的 6 字节; 载荷从 b6 的低 2 字节开始。
    // 8 字节载荷 ⇒ 帧 62 字节 ⇒ 8 拍, 末拍 tkeep=FC (6 字节有效)。
    reg [3:0]  beat;
    reg [7:0]  cur_flags;
    reg [63:0] cur_b6, cur_b7;
    reg [7:0]  l_flags;      // 最近一帧: flags
    reg [63:0] l_b6, l_b7;   // 最近一帧: b6/b7 (载荷来源, 8 字节载荷时)
    reg [15:0] l_beats;      // 最近一帧拍数
    reg [15:0] n_frm;        // 帧数 (与 stat_frames 对账)
    reg [15:0] n_rst;        // flags==0x14 的帧数
    reg [31:0] tready_hi;    // s_axis_tready 为高的拍数 (F3 窗口内的自检)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat <= 4'd0; cur_flags <= 8'd0; cur_b6 <= 64'd0; cur_b7 <= 64'd0;
            l_flags <= 8'd0; l_b6 <= 64'd0; l_b7 <= 64'd0; l_beats <= 16'd0;
            n_frm <= 16'd0; n_rst <= 16'd0; tready_hi <= 32'd0;
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
                    l_flags <= (beat == 4'd5) ? m_tdata[7:0] :
                               (beat == 4'd6) ? cur_flags : cur_flags;
                    beat    <= 4'd0;
                    n_frm   <= n_frm + 16'd1;
                    if (((beat == 4'd5) ? m_tdata[7:0] : cur_flags) == 8'h14)
                        n_rst <= n_rst + 16'd1;
                end
            end
            if (s_tready) tready_hi <= tready_hi + 32'd1;
        end
    end

    // ---------------- 载荷图案 (8 字节) ----------------
    localparam [63:0] PAT = 64'hA1A2A3A4A5A6A7A8;

    // 呈交一帧 (presenting 契约: tready=0 时保持稳定; 最多等 maxc 拍)
    task present;
        input [3:0] id;
        input integer maxc;
        integer g;
        begin
            s_tdata <= PAT; s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tid <= id;
            s_tvalid <= 1'b1;
            g = 0;
            while (!s_tready && (g < maxc)) begin @(posedge clk); g = g + 1; end
            if (s_tready) begin @(posedge clk); end   // 消费拍
            s_tvalid <= 1'b0;
            @(posedge clk);
        end
    endtask

    // 等一帧发出 (最多 maxc 拍); 返回是否等到
    task wait_frame;
        input [15:0] target;
        input integer maxc;
        integer g;
        begin
            g = 0;
            while ((n_frm < target) && (g < maxc)) begin @(posedge clk); g = g + 1; end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        s_tdata = 64'd0; s_tkeep = 8'd0; s_tvalid = 1'b0; s_tlast = 1'b0;
        s_tid = 4'd0; rst_req = 16'd0; fin_req = 16'd0;
        cfg_up = 1'b0; cfg_up_id = 4'd0;
        #100; rst_n = 1;
        repeat (20) @(posedge clk);

        // ============ F1: 基线 — abort 之前数据帧可发 (逐字节) ============
        $display("F1: 基线数据帧 (abort 之前)");
        present(4'd0, 200);
        wait_frame(16'd1, 400);
        chk(n_frm == 16'd1, "F1a 数据帧发出 (帧数=1)");
        chk(l_flags == 8'h18, "F1b flags=0x18 (PSH+ACK)");
        chk(tx_stat_frames == 32'd1, "F1c stat_frames=1");
        chk(tx_stat_bytes == 32'd8, "F1d stat_bytes=8 (plen 正确)");
        chk((l_b6[15:0] == PAT[63:48]), "F1e 载荷[0..1] 落在 b6 低 2 字节");
        chk((l_b7[63:16] == PAT[47:0]), "F1f 载荷[2..7] 逐字节正确 (b7 高 6 字节)");
        $display("DBG F1: frames=%0d bytes=%0d flags=%02x b6=%016x b7=%016x beats=%0d",
                 tx_stat_frames, tx_stat_bytes, l_flags, l_b6, l_b7, l_beats);

        // ============ F2: abort ⇒ RST 帧 ============
        $display("F2: rst_req[0]=1 ⇒ RST 帧 (flags=0x14, plen=0)");
        rst_req <= 16'h0001;
        wait_frame(16'd2, 1200);              // 扫描 (256 拍) + 帧组装
        chk(n_frm == 16'd2, "F2a RST 帧发出 (帧数=2)");
        chk(l_flags == 8'h14, "F2b RST flags=0x14");
        chk(l_beats == 16'd7, "F2c RST 帧 7 拍 (= 54 字节头, 零载荷)");
        chk(tx_stat_rst == 32'd1, "F2d stat_rst=1");
        chk(o_rst_sent[0] == 1'b1, "F2e o_rst_sent[0]=1 (fence 已武装)");
        chk(o_rst_sent[1] == 1'b0, "F2f o_rst_sent[1]=0 (per-slot)");
        $display("DBG F2: frames=%0d rst=%0d flags=%02x beats=%0d rst_sent=%04x",
                 tx_stat_frames, tx_stat_rst, l_flags, l_beats, o_rst_sent);

        // ============ F3: fence — RST 后同连接数据帧起不来 ============
        // 展示 (presenting): tvalid 拉高保持 400 拍 (远长于一次扫描), 全程
        // s_axis_tready 必须为 0 (接受门), 且不得发出任何帧 (启动门)。
        $display("F3: RST 之后 app 推帧 (tid=0) — tready 必须全程 0");
        tready_hi = 32'd0;                    // 窗口内计数清零
        s_tdata <= PAT; s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tid <= 4'd0;
        s_tvalid <= 1'b1;
        repeat (400) @(posedge clk);
        chk(tready_hi == 32'd0, "F3a s_axis_tready 400 拍内恒 0 (接受门 = fence)");
        chk(n_frm == 16'd2, "F3b 无新帧发出 (启动门同门 ⇒ 无字被吞)");
        chk(tx_stat_frames == 32'd2, "F3c stat_frames 不变");
        chk(o_rst_sent[0] == 1'b1, "F3d 展示期间 o_rst_sent[0] 保持 1");
        $display("DBG F3: tready_hi=%0d frames=%0d rst_sent=%04x",
                 tready_hi, tx_stat_frames, o_rst_sent);

        // ============ F4: 旁路对照 — 另一个连接照常可发 ============
        // 同窗口内改推 tid=1: fence 只黑名单被 abort 的槽 ⇒ tid=1 必须照常成帧。
        // (若 F4 也起不来, 说明 F3 的"挡住"来自别的因素而非本 fence)
        $display("F4: 旁路对照 — 同窗口 tid=1 的帧照常被接受");
        s_tid <= 4'd1;
        @(posedge clk);   // tid 是注册激励: 下一拍才可见 (同沿读是旧值)
        chk(s_tready == 1'b1, "F4a tid=1 展示时 tready=1 (未被 fence 波及)");
        @(posedge clk);
        s_tvalid <= 1'b0;
        wait_frame(16'd3, 400);
        chk(n_frm == 16'd3, "F4b tid=1 帧发出 (帧数=3)");
        chk(l_flags == 8'h18, "F4c tid=1 帧 flags=0x18");
        chk((l_b6[15:0] == PAT[63:48]) && (l_b7[63:16] == PAT[47:0]),
            "F4d tid=1 帧载荷逐字节正确");

        // ============ F5: 释放 (cfg_up 收尾脉冲) ⇒ 帧恢复且逐字节正确 ======
        // cfg_up 清 rst_sent_r (同槽重连路径, P5a D1)。释放后再推 tid=0 的帧:
        // 必须成帧, 且载荷逐字节正确 —— 这是"接受门与启动门同门"(坑 10)的判据:
        // 若展示期接受门更宽, 之前的字会被吞进载荷 FIFO ⇒ 本帧错位/截断。
        $display("F5: cfg_up 清 rst_sent_r ⇒ tid=0 帧恢复 (逐字节)");
        // P5d-D2 (激励修正, 判据文本一字未改): 原激励在 F2 挂上 rst_req[0]=1 之后
        // **从不撤**, 一直挂到 F5 —— 那与真链路不符: app_ctrl 的 rst_req 是
        // 成对释放的电平 (app_ctrl.v:834-835 ev_up / :876-877 ev_down /
        // :938-939 state != ESTAB), 与 cfg_up 清 rst_sent_r 出自同一批事件。
        // 挂着 abort 请求却要求"帧恢复可发", 等于要求"abort 请求还挂着也允许发
        // 数据" —— 那正是 D1 修复 (tx_blk 加 rst_req, rtl/tcp_tx_frame.v:361)
        // 要禁的行为。此处按真链路时序补一次释放, 使 F5 测的是它真正要测的东西
        // (cfg_up 清 rst_sent_r 的释放路径 + 接受门/启动门同门), 不是新判据。
        rst_req <= 16'd0;
        cfg_up <= 1'b1; cfg_up_id <= 4'd0;
        @(posedge clk); cfg_up <= 1'b0;
        @(posedge clk);
        chk(o_rst_sent[0] == 1'b0, "F5a cfg_up 清 o_rst_sent[0]");
        present(4'd0, 200);
        wait_frame(16'd4, 400);
        chk(n_frm == 16'd4, "F5b fence 释放后 tid=0 帧发出 (帧数=4)");
        chk(l_flags == 8'h18, "F5c flags=0x18");
        // 载荷字节累计: F1(8) + RST(0) + F4 tid=1(8) + 本帧(8) = 24
        chk(tx_stat_bytes == 32'd24, "F5d stat_bytes=24 (仅数据帧计载荷)");
        chk((l_b6[15:0] == PAT[63:48]), "F5e b6 载荷[0..1] 正确 (无错位)");
        chk((l_b7[63:16] == PAT[47:0]), "F5f b7 载荷[2..7] 逐字节正确 (无吞字)");
        chk(tx_stat_eend == 32'd0, "F5g stat_eend=0 (无欠载/截断帧)");
        chk(tx_stat_frames == 32'd4, "F5h stat_frames=4 (帧数与 AXIS 一致)");
        $display("DBG F5: frames=%0d bytes=%0d flags=%02x rst=%0d eend=%0d",
                 tx_stat_frames, tx_stat_bytes, l_flags, tx_stat_rst, tx_stat_eend);

        repeat (20) @(posedge clk);
        $display("GATE tb_p5c_fence: %0s", (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
