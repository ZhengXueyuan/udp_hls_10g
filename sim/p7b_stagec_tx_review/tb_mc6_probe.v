`timescale 1ns/1ps
// ===========================================================================
// tb_mc6_probe.v -- 对抗审查(C) 定向激励: M-C6 判据 (回卷门 !ctrl_adv_inflight)
// ---------------------------------------------------------------------------
// 目的: 作者报告 "该窗口整轮只命中 2 次" ⇒ M-C6 未证. 本 TB 构造**相位对齐的
//   定向激励**, 让"FIN 已预留未发" 窗口与"回卷请求"必然重叠:
//
//   1. 装 1 条 ESTAB 连接 (conn0), snd_nxt = snd_una = F (无在飞);
//   2. ack_req(ack_fin=1) => FIN 条目入 ackq => start_ack 弹条目 =>
//      **帧首原子预留** (snd_nxt := F+1) + 槽 busy=1 + ctrl_tx_pend=1;
//   3. 全程保持 retx_req=1 (level; conn0) —— 它在 gnt 之前不撤 (与真协议同:
//      tcp_rx 电平请求, 见 rtl/tcp_rx.v 的 retx_req/retx_gnt 握手);
//   4. 控制帧 8 拍 (T_HDR..T_DONE) 期间 busy 恒 1 => 若"回卷门"生效, 回卷被推迟
//      到 FIN 落地之后 (retx_hi = fin_seq => delta=0, **无字节重放**);
//      若门被撤 (M-C6), 回卷落在 FIN 在飞期: retx_hi = rb_snd_nxt = F+1
//      => ring_delta = 1 => **线上出现 1 字节数据帧 @seq=F** (C6: 在 FIN 的 seq
//      上重放 1 字节).
//
// 判据 (唯一): data_seqF_1B = 线上 "数据帧(PSH) && seq==F && 载荷==1B" 的条数.
//   期望: 修复版 = 0; M-C6 = >=1.   (负对照 = 同一 TB, 只换 RTL 源)
// ===========================================================================
module tb_mc6_probe;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;

    localparam [31:0] SEQ_F   = 32'h0000_F100;   // FIN 的 seq (= 建连时 snd_nxt)
    localparam [31:0] RCV_NXT = 32'h0000_4000;
    localparam [15:0] RCV_WND = 16'h4000;
    localparam [15:0] SND_WND = 16'hC000;
    localparam integer CY_MAX = 4000;

    // ---------------- TCB 写口仲裁 (与 tb_tcp_tx_ovl 同款: tx > rx > cfg) ----
    reg         scfg_upd_wr; reg [3:0] scfg_upd_id; reg [2:0] scfg_upd_sel;
    reg  [31:0] scfg_upd_val;
    wire [3:0]  rb_id, cam_rd_id;
    wire [31:0] rb_snd_nxt, rb_rcv_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        tx_upd_wr; wire [3:0] tx_upd_id; wire [2:0] tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire        sel_tx = tx_upd_wr;
    wire        scfg_gnt = !sel_tx;
    wire        tcb_wr  = sel_tx || scfg_upd_wr;
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : scfg_upd_sel;
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : scfg_upd_id;
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : scfg_upd_val;

    tcb #(.N(16), .WIN_CAP(16'hBFFE)) u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(4'd0), .ra_rcv_nxt(), .ra_snd_nxt(), .ra_snd_una(),
        .ra_rcv_wnd(), .ra_snd_wnd(), .ra_state(), .ra_wscale(),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_id(rb_id), .win_open(win_open), .win_inflight(win_inflight),
        .win_wnd_eff(win_wnd_eff),
        .rc_id(4'd0), .rc_rcv_nxt(), .rc_snd_nxt(), .rc_snd_una(), .rc_rcv_wnd(),
        .rc_snd_wnd(), .rc_state(),
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    reg  [47:0] cam_dmac [0:15];
    reg  [31:0] cam_sip  [0:15];
    reg  [15:0] cam_sport[0:15];
    reg  [15:0] cam_dport[0:15];
    wire [47:0] cam_rd_dmac  = cam_dmac [cam_rd_id];
    wire [31:0] cam_rd_sip   = cam_sip  [cam_rd_id];
    wire [15:0] cam_rd_sport = cam_sport[cam_rd_id];
    wire [15:0] cam_rd_dport = cam_dport[cam_rd_id];
    integer i;
    initial for (i = 0; i < 16; i = i + 1) begin
        cam_dmac[i]  = 48'hAA_BB_CC_DD_EE_00 + i;
        cam_sip[i]   = 32'hC0A8_6400 + (i + 10);
        cam_sport[i] = 16'd40000 + i;
        cam_dport[i] = 16'd8080;
    end

    // ---------------- DUT ----------------
    reg  [63:0] s_tdata; reg [7:0] s_tkeep; reg s_tvalid, s_tlast; reg [3:0] s_tid;
    wire s_tready;
    reg         ack_req; reg [3:0] ack_id; reg [31:0] ack_val;
    reg         ack_syn, ack_fin, ack_rst;
    reg  [15:0] fin_req, rst_req;
    reg         cfg_up; reg [3:0] cfg_up_id;
    wire [15:0] o_fin_sent, o_rst_sent;
    reg         wu_req; reg [3:0] wu_id; reg [31:0] wu_val; wire wu_gnt;
    reg         retx_req; reg [3:0] retx_id; wire retx_gnt;
    reg         m_tready;
    wire [63:0] m_tdata; wire [7:0] m_tkeep; wire m_tvalid, m_tlast;
    wire [31:0] stat_retx;
    wire [31:0] o_retx_hi; wire o_retx_active; wire [3:0] o_retx_id;
    wire [31:0] stat_frames, stat_bytes, stat_ack, stat_ack_drop, stat_eend,
                stat_drop_len, stat_fin, stat_rst, stat_tlast_in;

    tcp_tx_frame u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tid(s_tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val), .ack_syn(ack_syn),
        .ack_fin(ack_fin), .ack_rst(ack_rst),
        .fin_req(fin_req), .rst_req(rst_req),
        .cfg_up(cfg_up), .cfg_up_id(cfg_up_id),
        .o_fin_sent(o_fin_sent), .o_rst_sent(o_rst_sent),
        .wu_req(wu_req), .wu_id(wu_id), .wu_val(wu_val), .wu_gnt(wu_gnt),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(retx_gnt),
        .stat_retx(stat_retx),
        .o_retx_hi(o_retx_hi), .o_retx_active(o_retx_active), .o_retx_id(o_retx_id),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel),
        .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h02_00_00_00_00_01), .cfg_src_ip(32'hC0A8_6402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_bytes(stat_bytes), .stat_ack(stat_ack),
        .stat_ack_drop(stat_ack_drop), .stat_eend(stat_eend),
        .stat_drop_len(stat_drop_len), .stat_fin(stat_fin), .stat_rst(stat_rst),
        .stat_tlast_in(stat_tlast_in),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    // ---------------- 线上帧接收/分类 ----------------
    reg [7:0] fr [0:1663];
    reg [11:0] fpos;
    integer n_frames, n_data, n_ctrl, n_data_seqF_1B, n_fin_wire, n_rewinds;
    integer cyc;
    reg oa_p;
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        fr[0] = 8'h0; fpos = 0;
        n_frames = 0; n_data = 0; n_ctrl = 0; n_data_seqF_1B = 0;
        n_fin_wire = 0; n_rewinds = 0; cyc = 0; oa_p = 0;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (o_retx_active && !oa_p) n_rewinds = n_rewinds + 1;
            oa_p <= o_retx_active;
        end
    end

    // ---- 内部探针 (只读) ----
    always @(posedge clk) begin
        if (rst_n) begin
            if (u_dut.svc)
                $display("[SVC] @%0d rew=%b snd_nxt=%h snd_una=%h seqwnd fin_sent=%h fin_seq0=%h busy=%b cid=%0d cis=%b act=%b",
                    cyc, u_dut.svc_rewind, rb_snd_nxt, rb_snd_una, o_fin_sent[0],
                    u_dut.fin_seq_r[0], u_dut.ctrl_slot_busy, u_dut.ctrl_id,
                    u_dut.ctrl_is, u_dut.retx_active);
            if (u_dut.ring_start)
                $display("[RING] @%0d delta=%h preset=%0d snd_nxt=%h retx_hi=%h rxbank=%b",
                    cyc, u_dut.ring_delta, u_dut.plen_preset, rb_snd_nxt,
                    u_dut.retx_hi, u_dut.rx_bank);
            if (u_dut.upd_wr)
                $display("[TCBW] @%0d data=%b ctrl=%b rew=%b id=%0d val=%h",
                    cyc, u_dut.upd_wr_data, u_dut.upd_wr_ctrl, u_dut.upd_wr_rew,
                    u_dut.upd_id, u_dut.upd_val);
            if (u_dut.start_ack)
                $display("[STACK] @%0d id=%0d is=%b busy=%b snd_nxt=%h",
                    cyc, u_dut.ctrl_id, u_dut.ctrl_is, u_dut.ctrl_slot_busy, rb_snd_nxt);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fpos <= 0;
        else if (m_tvalid && m_tready) begin
            if (m_tkeep[7]) begin fr[fpos] = m_tdata[63:56]; fpos = fpos + 1; end
            if (m_tkeep[6]) begin fr[fpos] = m_tdata[55:48]; fpos = fpos + 1; end
            if (m_tkeep[5]) begin fr[fpos] = m_tdata[47:40]; fpos = fpos + 1; end
            if (m_tkeep[4]) begin fr[fpos] = m_tdata[39:32]; fpos = fpos + 1; end
            if (m_tkeep[3]) begin fr[fpos] = m_tdata[31:24]; fpos = fpos + 1; end
            if (m_tkeep[2]) begin fr[fpos] = m_tdata[23:16]; fpos = fpos + 1; end
            if (m_tkeep[1]) begin fr[fpos] = m_tdata[15:8];  fpos = fpos + 1; end
            if (m_tkeep[0]) begin fr[fpos] = m_tdata[7:0];   fpos = fpos + 1; end
            if (m_tlast) begin
                n_frames = n_frames + 1;
                $display("[FRAME] @%0d fpos=%0d flags=%h seq=%h ack=%h dmac=%h",
                         cyc, fpos, fr[47], {fr[38],fr[40]}, {fr[42],fr[44]},
                         {fr[0],fr[1],fr[2],fr[3],fr[4],fr[5]});
                if (fr[47][0]) n_fin_wire = n_fin_wire + 1;
                if (fr[47][3]) begin
                    n_data = n_data + 1;
                    if (({fr[38],fr[40]} == SEQ_F) && (fpos == 12'd55)) begin
                        n_data_seqF_1B = n_data_seqF_1B + 1;
                        $display("[PROBE] 1-byte DATA frame @seq=F seen @%0d (flags=%h plen=%0d)",
                                 cyc, fr[47], fpos - 12'd54);
                    end
                end else n_ctrl = n_ctrl + 1;
                fpos = 12'd0;
            end
        end
    end

    // ---------------- 激励 ----------------
    reg [3:0] st;         // 装配 FSM
    initial begin
        rst_n = 0; s_tdata = 0; s_tkeep = 0; s_tvalid = 0; s_tlast = 0; s_tid = 0;
        ack_req = 0; ack_id = 0; ack_val = RCV_NXT; ack_syn = 0; ack_fin = 0; ack_rst = 0;
        fin_req = 0; rst_req = 0; cfg_up = 0; cfg_up_id = 0;
        wu_req = 0; wu_id = 0; wu_val = 0; retx_req = 0; retx_id = 0;
        m_tready = 1; scfg_upd_wr = 0; scfg_upd_id = 0; scfg_upd_sel = 0; scfg_upd_val = 0;
        st = 0;
        #200 rst_n = 1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 4'd0; scfg_upd_wr <= 0; ack_req <= 0; retx_req <= 0;
        end else begin
            ack_req <= 1'b0;
            case (st)
            // ---- conn0 装配: snd_una=F, snd_nxt=F, rcv_nxt, rcv_wnd, snd_wnd, ESTAB
            4'd0: begin scfg_upd_wr <= 1; scfg_upd_id <= 0; scfg_upd_sel <= 3'd2;
                        scfg_upd_val <= SEQ_F; st <= 4'd1; end
            4'd1: if (tcb_wr && (tcb_sel==3'd2) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd1; scfg_upd_val <= SEQ_F; st <= 4'd2; end
            4'd2: if (tcb_wr && (tcb_sel==3'd1) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd0; scfg_upd_val <= RCV_NXT; st <= 4'd3; end
            4'd3: if (tcb_wr && (tcb_sel==3'd0) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd3; scfg_upd_val <= {16'b0, RCV_WND}; st <= 4'd4; end
            4'd4: if (tcb_wr && (tcb_sel==3'd3) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND}; st <= 4'd5; end
            4'd5: if (tcb_wr && (tcb_sel==3'd4) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd5; scfg_upd_val <= 32'd1; st <= 4'd6; end
            4'd6: if (tcb_wr && (tcb_sel==3'd5) && (tcb_id==0))
                      begin scfg_upd_wr <= 1'b0; cfg_up <= 1'b1; cfg_up_id <= 0; st <= 4'd7; end
            4'd7: begin cfg_up <= 1'b0; st <= 4'd8; end
            // ---- 相位对齐的定向激励: retx_req 先拉高 (level, 直到 gnt), 再压 FIN 条目
            4'd8: begin retx_req <= 1'b1; retx_id <= 4'd0; st <= 4'd9; end
            4'd9: begin ack_req <= 1'b1; ack_id <= 4'd0; ack_fin <= 1'b1;
                        ack_syn <= 1'b0; ack_rst <= 1'b0; ack_val <= RCV_NXT; st <= 4'd10; end
            4'd10: begin ack_fin <= 1'b0; st <= 4'd11; end
            default: begin
                if (retx_req && retx_gnt) retx_req <= 1'b0;   // 与真协议相同: gnt 撤请求
            end
            endcase
            if (cyc > CY_MAX) begin
                $display("MC6PROBE frames=%0d data=%0d ctrl=%0d fin_wire=%0d rewinds=%0d data_seqF_1B=%0d stat_fin=%0d",
                         n_frames, n_data, n_ctrl, n_fin_wire, n_rewinds,
                         n_data_seqF_1B, stat_fin);
                $display("MC6PROBE_DONE");
                $finish;
            end
        end
    end
endmodule
