`timescale 1ns/1ps
// ===========================================================================
// tb_ovl_flood_probe.v -- adversarial review (C): production-legal reproduction of
//   "trivial retx session (rewind=0, retx_hi := snd_nxt) + control-frame reservation
//    (+1) landing while the session is still alive"  => delta = retx_hi - snd_nxt
//    underflows => G9-class replay flood (stale ring bytes sent at ever-advancing seq)
// ---------------------------------------------------------------------------
// Every ingredient is a real production path (see review report):
//   data frames via s_axis (app), ACK via rx_upd (tcp_rx level), retx_req level
//   (dup-ACK triggered, gnt-cleared like tcp_rx), FIN via fin_req -> scan fin_push
//   -> ackq (production close path; ack_fin is tied 0 in the real wrapper),
//   session kept alive by bank_rdy[rx_bank]==1 (ping-pong steady state, TX held by
//   m_tready=0), reservation = FIX-2' frame-start +1.
// ARM_SERIAL (default RTL): m_tready=1 from t0, single data frame (the serial FSM
//   cannot hold two banks); everything else identical.
// ===========================================================================
// ⚠️ 本文件 = 对抗审查提供的 `sim/p7b_stagec_tx_review/tb_ovl_flood_probe.v`
//    **逐字照抄** (只加下面两处判据行; 用 diff 可复核):
//      ① 模块改名 `tb_ovl_flood_probe` -> `tb_flood_probe`;
//      ② 结尾的 `FLOODPROBE: FLOOD|NOFLOOD` 判决行 (门需要机器可判的出口, 2 处);
//      ③ 顶部这段出处说明。
//    它在本门里当 **F1 负对照**: 同一激励跑 现役 OVL 必须 NOFLOOD,
//    跑 `mut_f1` (撤 !retx_ovf) 必须 FLOOD —— 判据有牙的证明。
module tb_flood_probe;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;

    localparam [31:0] SEQ_F   = 32'h0000_F000;
    localparam [31:0] RCV_NXT = 32'h0000_4000;
    localparam [15:0] RCV_WND = 16'h4000;
    localparam [15:0] SND_WND = 16'hC000;
    localparam integer CY_MAX = 60000;

    reg         scfg_upd_wr; reg [3:0] scfg_upd_id; reg [2:0] scfg_upd_sel;
    reg  [31:0] scfg_upd_val;
    reg         rx_upd_wr;   reg [3:0] rx_upd_id;   reg [2:0] rx_upd_sel;
    reg  [31:0] rx_upd_val;

    wire [3:0]  rb_id, cam_rd_id;
    wire [31:0] rb_snd_nxt, rb_rcv_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        tx_upd_wr; wire [3:0] tx_upd_id; wire [2:0] tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    wire        rx_upd_gnt = sel_rx;
    wire        scfg_gnt = !sel_tx && !sel_rx;
    wire        tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt);
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : scfg_upd_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : scfg_upd_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : scfg_upd_val);

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

    // ---------------- wire-frame capture ----------------
    reg [7:0] fr [0:1663];
    reg [11:0] fpos;
    integer n_frames, n_data, n_ctrl, n_fin_wire, n_replay_frames;
    integer cyc;
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        fr[0] = 8'h0; fpos = 0;
        n_frames = 0; n_data = 0; n_ctrl = 0; n_replay_frames = 0;
        n_fin_wire = 0; cyc = 0;
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
                if (fr[47][0]) n_fin_wire = n_fin_wire + 1;
                if (fr[47][3]) begin
                    n_data = n_data + 1;
                    $display("[FRAME] @%0d DATA seq=%h plen=%0d",
                             cyc, {fr[38],fr[39],fr[40],fr[41]}, fpos - 12'd54);
                    if (n_data > 2) n_replay_frames = n_replay_frames + 1;
                end else begin
                    n_ctrl = n_ctrl + 1;
                    $display("[FRAME] @%0d CTRL flags=%h", cyc, fr[47]);
                end
                fpos = 12'd0;
            end
        end
    end

    // ---------------- internal observers (read-only) ----------------
    always @(posedge clk) begin
        if (rst_n) begin
            if (u_dut.svc)
                $display("[SVC] @%0d rew=%b snd_nxt=%h una=%h retx_hi=%h act=%b busy=%b",
                    cyc, u_dut.svc_rewind, rb_snd_nxt, rb_snd_una, u_dut.retx_hi,
                    u_dut.retx_active,
`ifdef TCP_TX_OVL
                    u_dut.ctrl_slot_busy
`else
                    1'b0
`endif
                );
            if (u_dut.ring_start)
                $display("[RING] @%0d delta=%h preset=%0d snd_nxt=%h retx_hi=%h",
                    cyc, u_dut.ring_delta, u_dut.plen_preset, rb_snd_nxt, u_dut.retx_hi);
            if (u_dut.upd_wr && u_dut.upd_sel == 3'd1)
                $display("[TCBW] @%0d id=%0d val=%h", cyc, u_dut.upd_id, u_dut.upd_val);
        end
    end

    // ---------------- stimulus FSM ----------------
    reg [4:0]  st;
    reg [15:0] dly;
    reg [31:0] una_target;
    integer    t_wait;
    initial begin
        rst_n = 0; s_tdata = 0; s_tkeep = 0; s_tvalid = 0; s_tlast = 0; s_tid = 0;
        ack_req = 0; ack_id = 0; ack_val = RCV_NXT; ack_syn = 0; ack_fin = 0; ack_rst = 0;
        fin_req = 0; rst_req = 0; cfg_up = 0; cfg_up_id = 0;
        wu_req = 0; wu_id = 0; wu_val = 0; retx_req = 0; retx_id = 0;
        scfg_upd_wr = 0; scfg_upd_id = 0; scfg_upd_sel = 0; scfg_upd_val = 0;
        rx_upd_wr = 0; rx_upd_id = 0; rx_upd_sel = 0; rx_upd_val = 0;
        st = 0; dly = 0; una_target = 0; t_wait = 0;
`ifdef ARM_SERIAL
        m_tready = 1;
`else
        m_tready = 0;
`endif
        #200 rst_n = 1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 5'd0;
        end else begin
            case (st)
            5'd0: begin scfg_upd_wr <= 1; scfg_upd_id <= 0; scfg_upd_sel <= 3'd2;
                        scfg_upd_val <= SEQ_F; st <= 5'd1; end
            5'd1: if (tcb_wr && (tcb_sel==3'd2) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd1; scfg_upd_val <= SEQ_F; st <= 5'd2; end
            5'd2: if (tcb_wr && (tcb_sel==3'd1) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd0; scfg_upd_val <= RCV_NXT; st <= 5'd3; end
            5'd3: if (tcb_wr && (tcb_sel==3'd0) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd3; scfg_upd_val <= {16'b0, RCV_WND}; st <= 5'd4; end
            5'd4: if (tcb_wr && (tcb_sel==3'd3) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND}; st <= 5'd5; end
            5'd5: if (tcb_wr && (tcb_sel==3'd4) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd5; scfg_upd_val <= 32'd1; st <= 5'd6; end
            5'd6: if (tcb_wr && (tcb_sel==3'd5) && (tcb_id==0))
                      begin scfg_upd_wr <= 1'b0; cfg_up <= 1'b1; cfg_up_id <= 0; st <= 5'd7; end
            5'd7: begin cfg_up <= 1'b0; dly <= 16'd4; st <= 5'd8; end
            // frame A: 8B @ SEQ_F
            5'd8: if (dly != 0) dly <= dly - 16'd1;
                  else begin s_tid <= 0; s_tdata <= 64'hA1A2A3A4A5A6A7A8;
                             s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tvalid <= 1'b1;
                             st <= 5'd9; end
            5'd9: if (s_tready) begin s_tvalid <= 1'b0; s_tlast <= 1'b0;
                                     dly <= 16'd120; st <= 5'd10; end
            5'd10: if (dly != 0) dly <= dly - 16'd1;
                   else begin
`ifdef FINPUSH_SYNC
                        st <= 5'd13;                     // 串行 + fin_push 同步相位 (先 ACK)
`else
`ifdef ARM_SERIAL
                        st <= 5'd13;                     // 串行分支: 只喂 1 帧
`else
                        st <= 5'd11;
`endif
`endif
                   end
            // frame B: 8B (基址 = 实时 snd_nxt)
            5'd11: begin s_tid <= 0; s_tdata <= 64'hB1B2B3B4B5B6B7B8;
                         s_tkeep <= 8'hFF; s_tlast <= 1'b1; s_tvalid <= 1'b1;
                         st <= 5'd12; end
            5'd12: if (s_tready) begin s_tvalid <= 1'b0; s_tlast <= 1'b0;
                                     dly <= 16'd20; st <= 5'd13; end
            5'd13: if (dly != 0) dly <= dly - 16'd1;
                   else begin una_target <= u_tcb.snd_nxt_r[0]; st <= 5'd14; end
            // peer ACK: snd_una := snd_nxt
            5'd14: begin rx_upd_wr <= 1; rx_upd_id <= 0; rx_upd_sel <= 3'd2;
                         rx_upd_val <= una_target; st <= 5'd15; end
            5'd15: if (rx_upd_gnt) begin rx_upd_wr <= 1'b0; dly <= 16'd4;
`ifdef FINPUSH_SYNC
                        st <= 5'd23;
`else
                        st <= 5'd16;
`endif
                   end
            5'd16: if (dly != 0) dly <= dly - 16'd1;
                   else begin retx_req <= 1'b1; retx_id <= 4'd0; st <= 5'd17; end
            5'd17: if (retx_gnt) begin retx_req <= 1'b0; dly <= 16'd4; st <= 5'd18; end
            5'd18: if (dly != 0) dly <= dly - 16'd1;
                   else begin fin_req[0] <= 1'b1; t_wait <= 0; st <= 5'd19; end
            // wait for the FIN entry to be popped (start_ack) == reservation +1 landed
            5'd19: begin
                t_wait <= t_wait + 1;
                if (fin_req[0] && o_fin_sent[0]) fin_req[0] <= 1'b0;
                if (u_dut.start_ack && u_dut.aq_fin) begin
                    $display("[PROBE] start_ack(FIN) @%0d snd_nxt=%h una=%h retxact=%b",
                             cyc, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                             o_retx_active);
                    dly <= 16'd6; st <= 5'd20;
                end else if (t_wait > 5000) begin
                    $display("[PROBE] TIMEOUT waiting for FIN pop (snd_nxt=%h una=%h finreq=%b)",
                             u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0], fin_req[0]);
                    st <= 5'd21;
                end
            end
            5'd20: if (dly != 0) dly <= dly - 16'd1;
                   else begin
                       $display("[PROBE] release m_tready @%0d snd_nxt=%h una=%h retxact=%b",
                                cyc, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                                o_retx_active);
                       m_tready <= 1'b1; t_wait <= 0; st <= 5'd21;
                   end
            5'd21: begin
                t_wait <= t_wait + 1;
                if (t_wait > 12000) begin
                    $display("FLOODPROBE frames=%0d data=%0d replay_after_2=%0d ctrl=%0d fin_wire=%0d snd_nxt=%h una=%h statframes=%0d",
                             n_frames, n_data, n_replay_frames, n_ctrl, n_fin_wire,
                             u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0], stat_frames);
                    if (n_replay_frames > 0) $display("FLOODPROBE: FLOOD");
                    else                     $display("FLOODPROBE: NOFLOOD");
                    $display("FLOODPROBE_DONE");
                    $finish;
                end
            end
            5'd23: begin
                t_wait <= t_wait + 1;
                if (t_wait == 1) fin_req[0] <= 1'b1;
                if (u_dut.fin_push) begin
                    $display("[PROBE] fin_push @%0d snd_nxt=%h una=%h", cyc,
                             u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0]);
                    st <= 5'd24;
                end else if (t_wait > 20000) begin
                    $display("[PROBE] TIMEOUT waiting fin_push"); st <= 5'd21;
                end
            end
            5'd24: begin
                retx_req <= 1'b1; retx_id <= 4'd0;
                $display("[PROBE] retx_req pulse (T+1) @%0d", cyc);
                t_wait <= 0; st <= 5'd21;
            end
            default: ;
            endcase
            if (cyc > CY_MAX) begin
                $display("FLOODPROBE frames=%0d data=%0d replay_after_2=%0d ctrl=%0d fin_wire=%0d snd_nxt=%h una=%h statframes=%0d",
                         n_frames, n_data, n_replay_frames, n_ctrl, n_fin_wire,
                         u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0], stat_frames);
                if (n_replay_frames > 0) $display("FLOODPROBE: FLOOD");
                else                     $display("FLOODPROBE: NOFLOOD");
                $display("FLOODPROBE_DONE");
                $finish;
            end
        end
    end
endmodule
