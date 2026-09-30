`timescale 1ns/1ps
//=============================================================================
// tb_rev_g2g3 -- P5c-T3 INDEPENDENT REVIEW TB (adversarial)  [rev2]
//
// Topology: real `tcb` + real `app_ctrl` + real `tcp_tx_frame`, TCB write port
// arbitrated exactly like board/wrapper_p4.v APP_MODE (tx > rx > cfg > fc).
// Slow-path cfg (ADD/DEL) emulated by TB writes on the cfg level + ev_up /
// ev_down pulses (same shape as slow_cfg_adp S_TCB / S_TCB_LAST).
// Peer side: no ACK injection by default (tb_ack_req controlled per case).
//
// rev2 tests the FIXED behaviour (F1..F4 by the implementation agent):
//  R1 timeout with a natural fc grant: RST must now REACH THE WIRE (sticky
//     counters), then state=0; ordering RST-before-state=0.
//  R6 (F1 regression) timeout must RETURN the slot quota; a new connection on
//     a fresh slot must then advertise a NON-ZERO receive window.
//  R2 (F3 regression) fc stalled with an in-flight rcv_wnd write for the SAME
//     slot: the window write's gnt must NOT swallow st_pend; state=0 must land.
//  R3/R4 (F4) consecutive CONN_DOWN deliveries must be isolated 1-cycle pulses
//     (no "hidden edge"), external ev_down must still win its slot.
//  R5 same-slot reconnect after a timeout: no stale one-shot state.
//  R7 (F2 grace) RST unsendable (scan_now blocked) => grace fallback must still
//     write state=0 (slot released) with NO RST.
//  R8 (pool accounting, PRE-EXISTING P5b hole) ev_up for slot A landing on the
//     T+2 (C15) cycle of slot B => both write `pool`; C15 wins (later in
//     program order) => C18 accounting lost => Σwinq+pool > WIN_POOL.
//     Reported as INFO (not counted in errs): pre-dates T3.
//
// Summary line: "GATE tb_rev_g2g3: PASS|FAIL".
//=============================================================================
module tb_rev_g2g3;

    localparam [17:0] TO_LIM = 18'd4;   // small timeout (production 195313)

    reg clk, rst_n;
    integer errs;

    always #4 clk = ~clk;

    task chk;
        input        cond;
        input [255:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin errs = errs + 1; $display("  FAIL %0s", name); end
        end
    endtask

    // ---------------- TCB ----------------
    wire [3:0]  rc_id;
    wire [31:0] rc_snd_nxt, rc_snd_una, rc_rcv_nxt;
    wire [15:0] rc_rcv_wnd, rc_snd_wnd;
    wire [3:0]  rc_state;
    wire [3:0]  rb_id;
    wire [31:0] rb_snd_nxt, rb_rcv_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;

    // TCB write port + arbiter (mirrors wrapper_p4 APP_MODE)
    wire        tx_upd_wr;  wire [3:0] tx_upd_id;  wire [2:0] tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire        fc_upd_wr;  wire [3:0] fc_upd_id;  wire [2:0] fc_upd_sel;
    wire [31:0] fc_upd_val;
    reg         scfg_upd_wr;  reg [3:0] scfg_upd_id;  reg [2:0] scfg_upd_sel;
    reg  [31:0] scfg_upd_val;
    reg         fc_hold;                       // stall the fc level's grant
    wire        sel_tx = tx_upd_wr;
    wire        scfg_gnt = !sel_tx && scfg_upd_wr;
    wire        sel_fc = !sel_tx && !scfg_upd_wr && fc_upd_wr;
    wire        fc_gnt = sel_fc && !fc_hold;   // held => request stays pending
    wire        tcb_wr = sel_tx || (scfg_upd_wr && scfg_gnt) || (sel_fc && !fc_hold);
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (scfg_upd_wr ? scfg_upd_sel : fc_upd_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (scfg_upd_wr ? scfg_upd_id  : fc_upd_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (scfg_upd_wr ? scfg_upd_val : fc_upd_val);

    tcb #(.WIN_CAP(16'hBFFE)) u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(4'd0), .ra_rcv_nxt(), .ra_snd_nxt(), .ra_snd_una(),
        .ra_rcv_wnd(), .ra_snd_wnd(), .ra_state(), .ra_wscale(),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd),
        .rb_snd_wnd(rb_snd_wnd), .rb_state(rb_state),
        .win_id(rb_id), .win_open(win_open),
        .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .rc_id(rc_id), .rc_rcv_nxt(rc_rcv_nxt), .rc_snd_nxt(rc_snd_nxt),
        .rc_snd_una(rc_snd_una), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    // ---------------- event source (emulated slow_cfg_adp) ----------------
    reg        ev_up, ev_down;
    reg [3:0]  ev_slot;

    // ---------------- app_ctrl ----------------
    reg  [16:0] rx_occ;
    wire [15:0] ac_fin_sent, ac_rst_sent;
    wire        ac_ev_up, ac_ev_down;
    wire [3:0]  ac_ev_slot;
    wire [15:0] ac_fin_req, ac_rst_req;
    wire        wu_req, wu_gnt;
    wire [3:0]  wu_id;
    wire [31:0] wu_val;
    wire [15:0] app_tx_ready;
    reg         close_req;
    reg  [3:0]  close_id;
    wire [31:0] ac_stat_down, ac_stat_fc, ac_stat_wu, ac_stat_reuse;
    wire [31:0] ac_stat_px, ac_stat_wa, ac_stat_evup, ac_stat_evdrop;
    wire [31:0] ac_stat_cmdcls, ac_stat_cmdabt;
    wire [16:0] ac_pool;
    wire [31:0] ac_redge0;
    wire [15:0] ac_winq0, ac_wumark0;
    wire [3:0]  ac_c0_state;
    wire [15:0] ac_estab_cnt, ac_ev_cnt;

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(TO_LIM), .FIN_GRACE(18'd4)) u_ac (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0A000001), .ev_peer_port(16'h1234),
        .ev_peer_mac(48'h112233445566),
        .rc_id(rc_id), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(rx_occ), .fin_sent(ac_fin_sent), .rst_sent(ac_rst_sent),
        .o_ev_up(ac_ev_up), .o_ev_down(ac_ev_down), .o_ev_slot(ac_ev_slot),
        .fin_req(ac_fin_req), .rst_req(ac_rst_req),
        .close_req(close_req), .close_id(close_id),
        .fc_upd_wr(fc_upd_wr), .fc_upd_id(fc_upd_id), .fc_upd_sel(fc_upd_sel),
        .fc_upd_val(fc_upd_val), .fc_gnt(fc_gnt),
        .wu_req(wu_req), .wu_id(wu_id), .wu_val(wu_val), .wu_gnt(wu_gnt),
        .reg_addr(8'h00), .reg_wr(1'b0), .reg_wdata(32'd0), .reg_rdata(),
        .app_tx_ready(app_tx_ready),
        .dbg_c0_state(ac_c0_state), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(),
        .dbg_c0_rcv_nxt(), .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(),
        .dbg_estab_cnt(ac_estab_cnt), .dbg_ev_cnt(ac_ev_cnt),
        .dbg_redge0(ac_redge0), .dbg_winq0(ac_winq0), .dbg_wu_mark0(ac_wumark0),
        .dbg_pool(ac_pool),
        .stat_ev_up(ac_stat_evup), .stat_ev_down(ac_stat_down),
        .stat_ev_drop(ac_stat_evdrop), .stat_cmd_close(ac_stat_cmdcls),
        .stat_cmd_abort(ac_stat_cmdabt), .stat_wu(ac_stat_wu),
        .stat_pool_exhaust(ac_stat_px), .stat_fc_upd(ac_stat_fc),
        .stat_slot_reuse(ac_stat_reuse), .stat_fc_wait_max(ac_stat_wa)
    );

    // ---------------- tcp_tx_frame ----------------
    reg         tb_ack_req;               // R7: hold high to block scan_now (=> no RST)
    // R9: app AXIS presentation (drives start_data / s_axis_tready => tx_blk)
    reg  [63:0] r9_tdata;  reg [7:0] r9_tkeep;
    reg         r9_tvalid, r9_tlast;  reg [3:0] r9_tid;
    wire        r9_tready;
    localparam [63:0] R9PAT = 64'hB1B2B3B4B5B6B7B8;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    wire [31:0] tx_stat_eend, tx_stat_drop_len, tx_stat_fin, tx_stat_rst;
    wire [31:0] tx_stat_tlast, tx_stat_retx;
    wire        tx_retx_active, tx_retx_gnt;
    wire [3:0]  tx_retx_id;
    wire [31:0] tx_retx_hi;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire        m_tready = 1'b1;

    tcp_tx_frame #(.RING_CAP(16'hBFFE)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(r9_tdata), .s_axis_tkeep(r9_tkeep), .s_axis_tvalid(r9_tvalid),
        .s_axis_tready(r9_tready), .s_axis_tlast(r9_tlast), .s_axis_tid(r9_tid),
        .ack_req(tb_ack_req), .ack_id(4'd0), .ack_val(32'd0), .ack_syn(1'b0),
        .ack_fin(1'b0), .ack_rst(1'b0),
        .fin_req(ac_fin_req), .rst_req(ac_rst_req),
        .cfg_up(ev_up), .cfg_up_id(ev_slot),
        .o_fin_sent(ac_fin_sent), .o_rst_sent(ac_rst_sent),
        .wu_req(wu_req), .wu_id(wu_id), .wu_val(wu_val), .wu_gnt(wu_gnt),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una),
        .rb_snd_wnd(rb_snd_wnd), .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight),
        .win_wnd_eff(win_wnd_eff),
        .retx_req(1'b0), .retx_id(4'd0), .retx_gnt(tx_retx_gnt),
        .stat_retx(tx_stat_retx),
        .o_retx_hi(tx_retx_hi), .o_retx_active(tx_retx_active),
        .o_retx_id(tx_retx_id),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel),
        .upd_val(tx_upd_val),
        .cam_rd_id(),
        .cam_rd_dmac(48'h112233445566), .cam_rd_sip(32'h0A000001),
        .cam_rd_sport(16'h1234), .cam_rd_dport(16'h5678),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop),
        .stat_eend(tx_stat_eend), .stat_drop_len(tx_stat_drop_len),
        .stat_fin(tx_stat_fin), .stat_rst(tx_stat_rst),
        .stat_tlast_in(tx_stat_tlast),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    // ---------------- event pulse monitor (app_ctrl outputs) ----------------
    // o_ev_down contract = isolated 1-cycle pulse with o_ev_slot valid on that
    // beat. Classify: EDGE (level was low) vs HIDDEN (slot changed while the
    // level stayed high => a rising-edge consumer would miss it).
    reg [15:0] down_seen, up_seen;
    reg [3:0]  last_down_slot, prev_slot;
    reg        prev_down;
    integer    edges, hidden;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            down_seen <= 16'd0; up_seen <= 16'd0; last_down_slot <= 4'd0;
            prev_down <= 1'b0; prev_slot <= 4'd0; edges <= 0; hidden <= 0;
        end else begin
            if (ac_ev_down) down_seen[ac_ev_slot] <= 1'b1;
            if (ac_ev_down && !prev_down) begin
                edges <= edges + 1;
                last_down_slot <= ac_ev_slot;
                $display("    [%0t] o_ev_down EDGE   slot=%0d", $time, ac_ev_slot);
            end
            if (ac_ev_down && prev_down && (ac_ev_slot != prev_slot)) begin
                hidden <= hidden + 1;
                last_down_slot <= ac_ev_slot;
                $display("    [%0t] o_ev_down HIDDEN (still high) slot=%0d", $time,
                         ac_ev_slot);
            end
            prev_down <= ac_ev_down;
            prev_slot <= ac_ev_slot;
            if (ac_ev_up) up_seen[ac_ev_slot] <= 1'b1;
        end
    end

    // ---------------- frame-level probe of the m_axis stream ----------------
    reg [3:0]  beat;
    reg [7:0]  cur_flags;
    reg [63:0] cur_b6, cur_b7, l_b6, l_b7;   // R9: payload words of the last frame
    integer    rst_frames, fin_frames, data_frames;
    real       t_rst_first;              // $time of the first RST frame
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat <= 4'd0; cur_flags <= 8'd0; cur_b6 <= 64'd0; cur_b7 <= 64'd0;
            l_b6 <= 64'd0; l_b7 <= 64'd0;
            rst_frames <= 0; fin_frames <= 0; data_frames <= 0;
            t_rst_first <= 0.0;
        end else if (m_tvalid && m_tready) begin
            if (beat == 4'd5) cur_flags <= m_tdata[7:0];  // w5 low byte = flags
            if (beat == 4'd6) cur_b6 <= m_tdata;
            if (beat == 4'd7) cur_b7 <= m_tdata;
            beat <= beat + 4'd1;
            if (m_tlast) begin
                beat <= 4'd0;
                l_b6 <= (beat == 4'd6) ? m_tdata : cur_b6;
                l_b7 <= (beat == 4'd7) ? m_tdata : cur_b7;
                if (cur_flags == 8'h14) begin
                    rst_frames <= rst_frames + 1;
                    if (t_rst_first == 0.0) t_rst_first <= $realtime;
                end
                if (cur_flags == 8'h11) fin_frames <= fin_frames + 1;
                if (cur_flags == 8'h18) data_frames <= data_frames + 1;
            end
        end
    end

    // sticky "state[c] first went 0" timestamp (for the RST-before-state check)
    reg        armed;
    real       t_st0 [0:15];
    integer    si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (si = 0; si < 16; si = si + 1) t_st0[si] <= 0.0;
        end else if (armed) begin
            for (si = 0; si < 16; si = si + 1)
                if ((u_tcb.state_r[si] == 4'd0) && (t_st0[si] == 0.0))
                    t_st0[si] <= $realtime;
        end
    end

    // ---------------- slow-path cfg emulation ----------------
    task tcb_write;
        input [3:0]  id;
        input [2:0]  sel;
        input [31:0] val;
        begin
            @(posedge clk);
            scfg_upd_wr <= 1'b1; scfg_upd_id <= id; scfg_upd_sel <= sel;
            scfg_upd_val <= val;
            @(posedge clk);
            while (!(scfg_upd_wr && scfg_gnt)) @(posedge clk);
            @(posedge clk);
            scfg_upd_wr <= 1'b0;
            @(posedge clk);
        end
    endtask

    task ev_pulse;
        input        is_up;
        input [3:0]  s;
        begin
            @(posedge clk);
            if (is_up) ev_up <= 1'b1; else ev_down <= 1'b1;
            ev_slot <= s;
            @(posedge clk);
            ev_up <= 1'b0; ev_down <= 1'b0;
            @(posedge clk);
        end
    endtask

    task cfg_add;                       // emulate ADD (7 TCB fields) + ev_up
        input [3:0]  s;
        input [31:0] rn;
        input [31:0] nx;
        input [31:0] una;
        input [15:0] rw;                // advertised rcv_wnd written by the HLS
        begin
            tcb_write(s, 3'd0, rn);        // rcv_nxt
            tcb_write(s, 3'd1, nx);        // snd_nxt
            tcb_write(s, 3'd2, una);       // snd_una
            tcb_write(s, 3'd3, {16'b0, rw});// rcv_wnd
            tcb_write(s, 3'd4, 16'h4000);  // snd_wnd
            tcb_write(s, 3'd5, 32'd1);     // state = ESTAB
            tcb_write(s, 3'd6, 32'd0);     // wscale
            ev_pulse(1'b1, s);
        end
    endtask

    task cfg_del;                       // emulate DEL (state=0) + ev_down
        input [3:0] s;
        begin
            tcb_write(s, 3'd5, 32'd0);
            ev_pulse(1'b0, s);
        end
    endtask

    task close_cmd;                     // CMD close: fin_req[s] via close_req
        input [3:0] s;
        begin
            @(posedge clk); close_req <= 1'b1; close_id <= s;
            @(posedge clk); close_req <= 1'b0;
            @(posedge clk);
        end
    endtask

    integer g;
    integer winq_sum, occ_sum;
    integer rst_base_r;

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        ev_up = 0; ev_down = 0; ev_slot = 0; rx_occ = 0;
        fc_hold = 0; close_req = 0; close_id = 0; tb_ack_req = 0;
        armed = 0; rst_base_r = 0;
        r9_tdata = 64'd0; r9_tkeep = 8'd0; r9_tvalid = 1'b0; r9_tlast = 1'b0;
        r9_tid = 4'd0;
        scfg_upd_wr = 0; scfg_upd_id = 0; scfg_upd_sel = 0; scfg_upd_val = 0;
        #100; rst_n = 1;
        repeat (40) @(posedge clk);

        //=====================================================================
        // R1: G2 timeout, natural fc grant (slot 1). F2 fix => the RST must
        //     now reach the wire, and state=0 must come AFTER it.
        //=====================================================================
        $display("R1: G2 timeout, natural fc grant (slot 1) - RST expected now");
        cfg_add(4'd1, 32'h2000_0100, 32'h0000_1000, 32'h0000_1000, 16'hC000);
        repeat (20) @(posedge clk);
        armed <= 1'b1;
        rst_base_r = rst_frames;
        close_cmd(4'd1);
        g = 0;
        while (!u_tx.fin_sent_r[1] && (g < 4000)) begin @(posedge clk); g = g + 1; end
        chk(u_tx.fin_sent_r[1] == 1'b1, "R1a FIN sent (o_fin_sent[1]=1)");
        g = 0;
        while (!u_ac.to_fired[1] && (g < 40000)) begin @(posedge clk); g = g + 1; end
        chk(u_ac.to_fired[1] == 1'b1, "R1b timeout fired (to_fired[1]=1)");
        chk(u_ac.rst_req[1] == 1'b1, "R1c rst_req[1]=1 raised by the timeout");
        $display("DBG R1: cycles-to-timeout=%0d fin_to=%0d pool=%0d winq1=%04x",
                 g, u_ac.fin_to[1], ac_pool, u_ac.winq[1]);
        repeat (1500) @(posedge clk);
        chk((rst_frames - rst_base_r) >= 1,
            "R1d ** RST reached the wire (rst_frames delta >= 1) **");
        chk(tx_stat_rst >= 1, "R1e stat_rst >= 1");
        chk(u_tcb.state_r[1] == 4'd0, "R1f state[1] written 0 afterwards");
        chk((t_st0[1] > 0.0) && (t_rst_first > 0.0) && (t_rst_first < t_st0[1]),
            "R1g ordering: RST frame BEFORE state=0 landed");
        chk(down_seen[1] == 1'b1, "R1h CONN_DOWN pulse delivered for slot 1");
        chk(u_ac.rst_req[1] == 1'b0, "R1i rst_req self-cleared after non-ESTAB");
        $display("DBG R1: rst_frames=%0d stat_rst=%0d t_rst=%0t t_state0=%0t",
                 rst_frames, tx_stat_rst, t_rst_first, t_st0[1]);

        //=====================================================================
        // R6 (F1 regression): the timeout must RETURN the slot quota, and a new
        //     connection on a fresh slot must advertise a NON-ZERO window.
        //=====================================================================
        $display("R6: F1 regression - quota returned + fresh slot gets a window");
        chk(u_ac.winq[1] == 16'd0, "R6a winq[1] released to 0 by the timeout");
        chk(ac_pool == 17'hC000, "R6b pool back to WIN_POOL (quota returned)");
        cfg_add(4'd7, 32'h5000_0100, 32'h0000_4000, 32'h0000_4000, 16'h1234);
        repeat (40) @(posedge clk);
        chk(u_ac.winq[7] == 16'hC000, "R6c new slot got winq[7]=C000");
        chk(u_tcb.rcv_wnd_r[7] == 16'hC000,
            "R6d ** advertised rcv_wnd[7]=C000 (init correction), not 0 **");
        $display("DBG R6: winq[7]=%04x rcv_wnd[7]=%04x pool=%0d (cfg wrote 1234)",
                 u_ac.winq[7], u_tcb.rcv_wnd_r[7], ac_pool);

        //=====================================================================
        // R2 (F3 regression): fc stalled with an in-flight rcv_wnd write for the
        //     SAME slot; the window write's gnt must NOT swallow st_pend.
        //=====================================================================
        $display("R2: F3 regression - window-write gnt must not eat st_pend (slot 0)");
        cfg_del(4'd7);                   // free the pool for slot 0
        repeat (10) @(posedge clk);
        fc_hold <= 1'b1;                 // stall the fc level BEFORE the ADD
        cfg_add(4'd0, 32'h3000_0100, 32'h0000_2000, 32'h0000_2000, 16'hC000);
        repeat (20) @(posedge clk);
        chk(u_ac.fc_v == 1'b1 && u_ac.fc_sel_r == 3'd3 && u_ac.fc_id_r == 4'd0,
            "R2a init window write (sel=3,id=0) loaded and STALLED");
        rst_base_r = rst_frames;
        close_cmd(4'd0);
        g = 0;
        while (!u_tx.fin_sent_r[0] && (g < 4000)) begin @(posedge clk); g = g + 1; end
        chk(u_tx.fin_sent_r[0] == 1'b1, "R2b FIN sent (o_fin_sent[0]=1)");
        g = 0;
        while (!u_ac.to_fired[0] && (g < 40000)) begin @(posedge clk); g = g + 1; end
        chk(u_ac.to_fired[0] == 1'b1, "R2c timeout fired (to_fired[0]=1)");
        g = 0;
        while (!u_ac.st_pend[0] && (g < 4000)) begin @(posedge clk); g = g + 1; end
        chk(u_ac.st_pend[0] == 1'b1, "R2d st_pend[0]=1 (abort completion armed)");
        chk(u_ac.st_done[0] == 1'b1, "R2e st_done[0] latched (one-shot)");
        chk(u_ac.fc_v == 1'b1 && u_ac.fc_sel_r == 3'd3,
            "R2f in-flight fc request is still the window write (sel=3)");
        fc_hold <= 1'b0;                 // release: window write is granted
        @(posedge clk); @(posedge clk); #1;
        $display("DBG R2: after window gnt: st_pend=%04x fc_v=%0d sel=%0d id=%0d",
                 u_ac.st_pend, u_ac.fc_v, u_ac.fc_sel_r, u_ac.fc_id_r);
        chk(u_ac.st_pend[0] == 1'b1,
            "R2g ** st_pend[0] SURVIVES the window-write gnt (F3 fixed) **");
        repeat (200) @(posedge clk);
        chk(u_tcb.state_r[0] == 4'd0,
            "R2h state[0] written 0 by the retried state write");
        chk(u_ac.st_pend[0] == 1'b0, "R2i st_pend[0] cleared by its own gnt");
        chk(u_ac.st_done[0] == 1'b1, "R2j st_done[0] stays latched");
        $display("DBG R2: state0=%0d st_pend=%04x st_done=%04x rst_frames=%0d",
                 u_tcb.state_r[0], u_ac.st_pend, u_ac.st_done, rst_frames);

        //=====================================================================
        // R3 (F4): two simultaneous pending timeout CONN_DOWN events (forced).
        //     Deliveries must be ISOLATED 1-cycle pulses (no hidden edge).
        //=====================================================================
        $display("R3: two simultaneous to_pend bits (forced) - isolated pulses");
        edges = 0; hidden = 0;
        force u_ac.to_pend = 16'h000C;   // slots 2 and 3
        @(posedge clk);
        @(posedge clk);
        release u_ac.to_pend;
        repeat (8) @(posedge clk);
        chk(hidden == 0, "R3a no hidden edge (o_ev_down always 1-cycle isolated)");
        chk((edges + hidden) >= 2, "R3b at least two timeout events delivered");
        chk(down_seen[2] == 1'b1 && down_seen[3] == 1'b1,
            "R3c both slots delivered (2 and 3)");
        $display("DBG R3: to_pend=%04x edges=%0d hidden=%0d", u_ac.to_pend, edges,
                 hidden);

        //=====================================================================
        // R4 (F4): external ev_down must win its slot; the pending timeout event
        //     is deferred and also isolated.
        //=====================================================================
        $display("R4: external ev_down vs pending timeout delivery");
        edges = 0; hidden = 0;
        force u_ac.to_pend = 16'h0010;   // slot 4 pending
        ev_down <= 1'b1; ev_slot <= 4'd5;
        @(posedge clk); #1;
        chk(ac_ev_down == 1'b1 && ac_ev_slot == 4'd5,
            "R4a external ev_down wins (slot 5 on the pulse)");
        ev_down <= 1'b0;
        g = 0;
        while (!(ac_ev_down && ac_ev_slot == 4'd4) && (g < 8)) begin
            @(posedge clk); #1; g = g + 1;
        end
        chk(ac_ev_down == 1'b1 && ac_ev_slot == 4'd4,
            "R4b timeout event deferred by 1 beat then delivered (slot 4)");
        release u_ac.to_pend;
        repeat (8) @(posedge clk);
        chk(hidden == 0, "R4c no hidden edge");
        chk(down_seen[4] == 1'b1 && down_seen[5] == 1'b1,
            "R4d both events seen, no slot mix-up");
        $display("DBG R4: last_down_slot=%0d edges=%0d hidden=%0d", last_down_slot,
                 edges, hidden);

        //=====================================================================
        // R5: same-slot ev_down + ev_up right after a timeout => the new session
        //     must not inherit the count / one-shot flags.
        //=====================================================================
        $display("R5: same-slot reconnect (ev_down+ev_up) after a timeout");
        cfg_del(4'd0);
        repeat (10) @(posedge clk);
        cfg_add(4'd6, 32'h4000_0100, 32'h0000_3000, 32'h0000_3000, 16'hC000);
        repeat (10) @(posedge clk);
        chk(u_ac.st_done[6] == 1'b0, "R5a st_done[6]=0");
        chk(u_ac.to_fired[6] == 1'b0, "R5b to_fired[6]=0");
        chk(u_ac.fin_to[6] == 18'd0, "R5c fin_to[6]=0");
        chk(u_ac.to_pend[6] == 1'b0, "R5d to_pend[6]=0");
        chk(u_tcb.state_r[6] == 4'd1, "R5e new session is ESTAB");
        chk(u_ac.winq[6] != 16'd0, "R5f new session got a non-zero quota");
        g = 0;
        while ((u_ac.c_state[6] != 4'd1) && (g < 600)) begin @(posedge clk); g = g + 1; end
        chk(app_tx_ready[6] == 1'b1, "R5g app_tx_ready[6]=1 (no stale fence)");

        //=====================================================================
        // R7 (F2 grace): make the RST unsendable (block tcp_tx_frame.scan_now by
        //     keeping the ackq non-empty) => the FIN_GRACE fallback must still
        //     write state=0 so the slot is released - and no RST is emitted.
        //=====================================================================
        $display("R7: F2 grace fallback - RST blocked by a full/held ackq (slot 8)");
        cfg_del(4'd6);                   // free the pool
        repeat (10) @(posedge clk);
        cfg_add(4'd8, 32'h6000_0100, 32'h0000_5000, 32'h0000_5000, 16'hC000);
        repeat (20) @(posedge clk);
        rst_base_r = rst_frames;
        close_cmd(4'd8);
        g = 0;
        while (!u_tx.fin_sent_r[8] && (g < 4000)) begin @(posedge clk); g = g + 1; end
        chk(u_tx.fin_sent_r[8] == 1'b1, "R7pre FIN sent for slot 8");
        // NOW block the RST path: sustained ack_req keeps ack_pend_r=1 =>
        // tcp_tx_frame.scan_now=0 => rst_push can never fire (ackq also full).
        tb_ack_req <= 1'b1;
        repeat (20) @(posedge clk);
        g = 0;
        while (!u_ac.to_fired[8] && (g < 40000)) begin @(posedge clk); g = g + 1; end
        chk(u_ac.to_fired[8] == 1'b1, "R7a timeout fired (to_fired[8]=1)");
        g = 0;
        while ((u_ac.fin_to[8] < 18'd8) && (g < 20000)) begin @(posedge clk); g = g + 1; end
        chk(u_ac.fin_to[8] >= 18'd8, "R7b fin_to[8] saturated at LIM+GRACE (>=8)");
        repeat (600) @(posedge clk);
        chk(u_tcb.state_r[8] == 4'd0,
            "R7c ** grace fallback wrote state=0 (slot released) **");
        chk((rst_frames - rst_base_r) == 0,
            "R7d no RST frame was emitted (RST path was blocked)");
        chk(u_ac.winq[8] == 16'd0, "R7e quota of slot 8 returned");
        $display("DBG R7: state8=%0d fin_to8=%0d rst_delta=%0d pool=%0d",
                 u_tcb.state_r[8], u_ac.fin_to[8], rst_frames - rst_base_r, ac_pool);
        tb_ack_req <= 1'b0;
        repeat (400) @(posedge clk);
        chk((rst_frames - rst_base_r) == 0, "R7f still no RST after release");

        //=====================================================================
        // R8: pool accounting collision (PRE-EXISTING P5b hole, not T3).
        //     ev_up for slot A landing on the T+2 (C15) cycle of slot B =>
        //     both write `pool` in the same cycle; C15 is later in program order
        //     => the C18 accounting for slot A is lost => sum(winq)+pool > WIN_POOL.
        //     Reported as INFO (not counted in errs) - pre-dates T3.
        //=====================================================================
        $display("R8: pool accounting collision probe (pre-existing P5b)");
        cfg_del(4'd8);
        repeat (10) @(posedge clk);
        // holder first (takes the whole pool), then slot 9 while pool==0 => winq[9]=0
        cfg_add(4'd10, 32'h7000_0100, 32'h0000_6000, 32'h0000_6000, 16'hC000);
        repeat (10) @(posedge clk);
        cfg_add(4'd9, 32'h7100_0100, 32'h0000_6100, 32'h0000_6100, 16'hC000);
        repeat (10) @(posedge clk);
        chk(u_ac.winq[9] == 16'd0, "R8a setup: slot 9 ESTAB with winq=0");
        // free the pool: now pool=WIN_POOL and slot 9 is C15-eligible
        tcb_write(4'd10, 3'd5, 32'd0);        // (DEL without the ev_down pulse yet)
        ev_pulse(1'b0, 4'd10);
        // Arm the collision: fire ev_up for slot 11 one beat BEFORE the T+2 block
        // of slot 9 executes. Timing (verified against the RTL/XSim semantics):
        // scan edge S sets pa_v (valid [S,S+1)); edge S+1 sets pb_v (valid
        // [S+1,S+2)); the T+2 block runs at edge S+2. A TB always/@ block reads
        // the pre-edge value, so watching pa_v && pa_sid==9 exits at S+1, and an
        // NBA there drives ev_up over [S+1,S+2) => sampled at S+2 together with
        // the T+2 block.
        g = 0;
        while (!(u_ac.pa_v && (u_ac.pa_sid == 4'd9)) && (g < 4000)) begin
            @(posedge clk); g = g + 1;
        end
        chk(g < 4000, "R8b caught slot 9 pipeline beat");
        ev_up <= 1'b1; ev_slot <= 4'd11;   // sampled at the SAME edge as the T+2 block
        @(posedge clk);
        ev_up <= 1'b0;
        repeat (40) @(posedge clk);
        winq_sum = 0;
        for (si = 0; si < 16; si = si + 1) winq_sum = winq_sum + u_ac.winq[si];
        occ_sum = winq_sum + ac_pool;
        $display("DBG R8: sum(winq)=%0d (%08x) pool=%0d total=%0d WIN_POOL=%0d winq9=%04x winq11=%04x",
                 winq_sum, winq_sum, ac_pool, occ_sum, 16'hC000, u_ac.winq[9],
                 u_ac.winq[11]);
        // R8 regression (C15 !ev_blk): the same-cycle double-spend must be gone =>
        // sum(winq)+pool == WIN_POOL (was 2xWIN_POOL before the fix).
        chk(occ_sum == 16'hC000,
            "R8c ** conservation: sum(winq)+pool == WIN_POOL (R8 fixed) **");
        chk(u_ac.winq[9] == 16'd0,
            "R8d C15 was suppressed on the ev_up beat (no same-cycle grant)");
        chk(u_ac.winq[11] == 16'hC000, "R8e ev_up (C18) grant landed for slot 11");
        // ---- deferral, NOT starvation: free the pool again and let C15 grant on
        //      the next (event-free) scan visit of slot 9.
        cfg_del(4'd11);
        g = 0;
        while ((u_ac.winq[9] == 16'd0) && (g < 3000)) begin @(posedge clk); g = g + 1; end
        chk(u_ac.winq[9] == 16'hC000,
            "R8f C15 grant only DEFERRED to the next scan visit (winq[9]=C000)");
        winq_sum = 0;
        for (si = 0; si < 16; si = si + 1) winq_sum = winq_sum + u_ac.winq[si];
        chk((winq_sum + ac_pool) == 16'hC000, "R8g conservation after the delayed grant");
        $display("DBG R8: deferral=%0d cycles; final winq[9]=%04x pool=%0d sum=%0d",
                 g, u_ac.winq[9], ac_pool, winq_sum + ac_pool);

        //=====================================================================
        // R9: tx_blk rewrite (fin_req|fin_sent_r|rst_sent_r shared 16:1 mux)
        //     must be behaviourally identical on start_data / s_axis_tready:
        //     (a) clear slot  -> frame accepted, flags 0x18, payload byte exact
        //     (b) after close -> same frame refused (tready stays 0, no frame)
        //=====================================================================
        $display("R9: tx_blk rewrite sanity on start_data / s_axis_tready (slot 12)");
        cfg_add(4'd12, 32'h9000_0100, 32'h0000_7000, 32'h0000_7000, 16'hC000);
        repeat (20) @(posedge clk);
        g = 0;
        while ((u_ac.c_state[12] != 4'd1) && (g < 600)) begin @(posedge clk); g = g + 1; end
        data_frames = 0;
        r9_tdata <= R9PAT; r9_tkeep <= 8'hFF; r9_tlast <= 1'b1; r9_tid <= 4'd12;
        r9_tvalid <= 1'b1;
        g = 0;
        while (!r9_tready && (g < 400)) begin @(posedge clk); g = g + 1; end
        chk(r9_tready == 1'b1, "R9a clear slot: frame accepted (tready=1)");
        @(posedge clk);
        r9_tvalid <= 1'b0;
        repeat (20) @(posedge clk);
        chk(data_frames == 1, "R9b data frame emitted (flags 0x18)");
        chk((l_b6[15:0] == R9PAT[63:48]) && (l_b7[63:16] == R9PAT[47:0]),
            "R9c payload byte-exact (tx_blk did not alter framing)");
        $display("DBG R9: data frame l_b6=%016x l_b7=%016x (payload %016x)",
                 l_b6, l_b7, R9PAT);
        // (b) after CMD close the same slot must be refused (fin_req term)
        close_cmd(4'd12);
        repeat (20) @(posedge clk);
        chk(u_ac.fin_req[12] == 1'b1, "R9d fin_req[12]=1 (close pending)");
        r9_tdata <= R9PAT; r9_tkeep <= 8'hFF; r9_tlast <= 1'b1; r9_tid <= 4'd12;
        r9_tvalid <= 1'b1;
        g = 0;
        while (!r9_tready && (g < 300)) begin @(posedge clk); g = g + 1; end
        chk(g >= 300, "R9e ** refused for 300 beats: tready stayed 0 (fin_req term) **");
        r9_tvalid <= 1'b0;
        repeat (40) @(posedge clk);
        chk(data_frames == 1, "R9f no extra data frame");
        // D4: my own data frame left snd_nxt != snd_una (no ACK is injected in this
        // TB) => the FIN is correctly WITHHELD, so the refusal above is attributable
        // to the fin_req term (the fin_sent_r / rst_sent_r terms are covered by the
        // fence gate F3/F5 where they are the only active terms).
        chk((u_tx.fin_sent_r[12] == 1'b0) && (u_ac.fin_req[12] == 1'b1),
            "R9g FIN withheld while data unACKed (D4) - refusal = fin_req term");
        $display("DBG R9: data_frames=%0d tready_wait=%0d fin_sent=%04x fin_req=%04x",
                 data_frames, g, ac_fin_sent, ac_fin_req);

        repeat (20) @(posedge clk);
        $display("GATE tb_rev_g2g3: %0s (errs=%0d)",
                 (errs == 0) ? "PASS" : "FAIL", errs);
        $display("SUMMARY rst_frames=%0d fin_frames=%0d data_frames=%0d stat_rst=%0d",
                 rst_frames, fin_frames, data_frames, tx_stat_rst);
        $finish;
    end

endmodule
