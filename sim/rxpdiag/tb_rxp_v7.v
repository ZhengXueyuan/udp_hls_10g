`timescale 1ns/1ps
//=============================================================================
// tb_rxp_v7.v -- RXP_DIAG v7 FUNCTIONAL gate
//   A: rtl/udp_rx.v  IP-identification sequence checker (IV/IS/IA/IB/IW)
//   B: rtl/udp_split.v v6 section: "IPv4/UDP only" gate + NB (skipped bytes)
// (ISSUE_RX_BYTE_CORRUPTION sections 18.14 / 18.15 / 18.16)
//=============================================================================
// WHAT THIS GATE IS FOR
//   A) The board verdict so far: 0.1-0.6% of frames arrive as a whole-frame
//      permutation (a window of L adjacent frames rotated), frame/byte counts
//      exact, the sender verified clean by capture, and the corruption already
//      present at the INPUT of udp_split -- while every store upstream holds at
//      most 14 words (112 B), i.e. cannot permute a 1472-byte frame.  The
//      remaining candidates are (i) the PC-side NIC/driver TX path reordering
//      frames and (ii) PHY/GMII receive margin.  The peer increments `ip.id`
//      per frame (capture-verified, 0/5699 mismatches), so the ARRIVAL order of
//      the ID field is a DIRECT measure of (i): in-order => id == prev+1.
//   B) The v6 checker compared *any* frame's bytes 42.. as payload, so
//      non-UDP frames arriving after a round were counted as mismatches
//      (board: CM=560 while app and v5 both reported 0, CV == exactly the
//      round's payload bytes).  Fixed structurally: only IPv4/UDP frames are
//      compared AND only they advance the LFSR; the skipped bytes go to NB.
//
// PHASES (all assert exact values; `chk` uses `!==` so X is a failure)
//   P1 POSITIVE (forward jump): ids 0x1000,0x1001,0x1002,0x2000 with clean
//      payloads => IV=1 IS=4 IA=0x2000 IB=0x1002 IW=0, and the payload
//      checkers stay clean (the ID test is orthogonal to payload corruption).
//   P2 ZERO (strictly +1, 6 frames): IV=0 IW=0 IS=6 while v6_cnt == 6*1472
//      (the byte checker ran the whole stream => "ran and saw nothing", not a
//      dead zero), app mismatch 0, PS delta 6.
//   P3 FIELD POSITION / BYTE ORDER: two ids that are byte-swaps of each other
//      (0xA5C3, 0x3C5A) => P3a IA=0x3C5A IB=0xA5C3 IW=1; P3b (0x3C5A then
//      0x3C5B) => IV=0.  A byte-swapped or offset-shifted field read cannot
//      reproduce either assertion (0xC3A5 / 0x5A3C / 0x... would show up).
//   P4 SCOPE (match-gate only): F1 id=0x0100 (matching), F2 id=0x0200
//      (NON-matching destination port), F3 id=0x0101 (matching) =>
//      IV=0 IS=2 (F2 must not participate; "compare all frames" would give
//      IV=2 IS=3).  Also: parser NM delta 1 (F2 dropped), app URF delta 2.
//   P5 TASK B (UDP-only gate): clean UDP frame, then an ICMP frame and an ARP
//      frame whose payload is the BITWISE COMPLEMENT of the expected pattern
//      (guaranteed mismatch if compared), then a clean UDP frame continuing the
//      stream => CM=0 CZ=0 CV=0, NB == skipped bytes exactly, v6_cnt == 2*1472,
//      app mismatch 0.  Without the gate the two junk frames are compared
//      (CM > 0, phase red) AND the LFSR is pushed out of phase so the third
//      frame mismatches as well.
//
// WORD PACING: wp_v idle cycles between words (the engine needs 2 cycles/word
//   and the input port cannot be backpressured) => CS == 0, asserted everywhere.
//
// ASCII-only, CRLF.  Never redirect to xvlog.log / xelab.log.
//=============================================================================
module tb_rxp_v7;
    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [31:0] PEER_IP  = 32'hC00A0001;   // 192.168.100.1
    localparam [15:0] APP_PORT = 16'd9000;
    localparam [15:0] BAD_PORT = 16'h9999;       // P4: non-matching destination port
    localparam integer PLEN    = 1472;           // board payload (184 words)
    localparam integer NFRM    = 4;
    localparam integer NB      = 32768;          // pattern array

    reg clk = 1'b0, rst_n = 1'b0;
    always #4 clk = ~clk;                        // 125 MHz

    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    reg [7:0] pay  [0:NB-1];                     // clean pattern (expected values)
    reg [7:0] payc [0:NB-1];                     // on-the-wire bytes (with injection)
    integer   k;
    reg [63:0] st;
    initial begin
        st = 64'h9E3779B97F4A7C15;
        for (k = 0; k < NB; k = k + 1) begin
            pay[k] = st[31:24];                  // fetch-then-advance (same as RTL/peer)
            st = xs_next(st);
        end
    end

    //=========================================================================
    // DUT: udp_split (real player + real rollback + v3..v7 instruments)
    //      + app_udp_pattern (real checker)
    //=========================================================================
    reg  [63:0] s_tdata;  reg [7:0] s_tkeep;  reg s_tvalid;
    wire        s_tready;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    wire [63:0] p_tdata;  wire [7:0] p_tkeep; wire p_tvalid;
    wire        p_tlast, p_tuser, p_tcrs, p_terr;
    wire        p_tready = 1'b1;
    wire [63:0] a_tdata;  wire [7:0] a_tkeep; wire a_tvalid; wire a_tlast, a_sof;
    wire [15:0] a_len;    wire [31:0] a_sip;  wire [15:0] a_sport;
    wire        a_tready;
    reg  [15:0] paylen_v;                        // app i_paylen (set per phase)

    reg  [31:0] cfg_dip;
    wire [31:0] st_app_frames, st_app_bytes, st_app_null, st_drop_crc,
                st_drop_ovf, st_drop_part, st_drop_excl,
                st_hls_frames, st_hls_drop, st_hls_split;

    // v3/v4/v5/v6 observation ports (kept for cross-generation accounting; this
    // gate asserts v7 + the v5/v6 byte-checker anchors)
    wire        ds_cap;
    wire [63:0] v3_sw;
    wire [8:0]  v3_sf;
    wire        v3_sm;
    wire [7:0]  v3_wd;
    wire [9:0]  v3_fr, v3_fw, v3_fo, v3_fh;
    wire [1:0]  v3_fs;
    wire [15:0] v3_fn;
    wire [9:0]  v3_pr, v3_pw, v3_ph;
    wire [9:0]  v3_lr, v3_lw, v3_lo, v3_lh;
    wire [15:0] v3_rc, v3_vc;
    wire [9:0]  v3_vx, v3_vs, v3_vr;
    wire [15:0] v3_vn;
    wire [15:0] v4_cn, v4_rd, v4_nc, v4_np, v4_wf, v4_rl, v4_wc;
    wire [31:0] v5_dv, v5_dm;
    wire [7:0]  v5_dg, v5_de;
    wire [15:0] v5_do;
    wire        v5_vz;
    wire [31:0] v5_ps, v5_nm, v5_ic, v5_dc, v5_sb;
    wire [31:0] v6_cv, v6_cm;
    wire [7:0]  v6_cg, v6_ce, v6_cs;
    wire [15:0] v6_co;
    wire        v6_cz;
    // v7 observation ports (A: IP-ID sequence checker; B: skipped non-UDP bytes)
    wire [15:0] v7_iv, v7_is, v7_ia, v7_ib, v7_iw, v7_nb;

    udp_split #(.EXCL_PORT(16'd8080)) u_split (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .p_axis_tdata(p_tdata), .p_axis_tkeep(p_tkeep), .p_axis_tvalid(p_tvalid),
        .p_axis_tready(p_tready),
        .p_axis_tlast(p_tlast), .p_axis_tuser(p_tuser),
        .p_axis_tcrs(p_tcrs), .p_axis_terr(p_terr),
        .app_rx_tdata(a_tdata), .app_rx_tkeep(a_tkeep), .app_rx_tvalid(a_tvalid),
        .app_rx_tready(a_tready), .app_rx_tlast(a_tlast), .app_rx_sof(a_sof),
        .app_rx_len(a_len), .app_rx_src_ip(a_sip), .app_rx_src_port(a_sport),
        .cfg_dst_ip(cfg_dip), .cfg_multi_en(1'b0),
        .cfg_port0(APP_PORT), .cfg_port1(16'hFFFF),
        .cfg_port2(16'hFFFF), .cfg_port3(16'hFFFF), .cfg_port_any(1'b0),
        .stat_app_frames(st_app_frames), .stat_app_bytes(st_app_bytes),
        .stat_app_null(st_app_null), .stat_drop_crc(st_drop_crc),
        .stat_drop_ovf(st_drop_ovf), .stat_drop_part(st_drop_part),
        .stat_drop_excl(st_drop_excl), .stat_hls_frames(st_hls_frames),
        .stat_hls_drop(st_hls_drop), .stat_hls_split(st_hls_split),
        .ds_cap(ds_cap),
        .v3_sw(v3_sw), .v3_sf(v3_sf), .v3_sm(v3_sm), .v3_wd(v3_wd),
        .v3_fr(v3_fr), .v3_fw(v3_fw), .v3_fo(v3_fo), .v3_fh(v3_fh),
        .v3_fs(v3_fs), .v3_fn(v3_fn),
        .v3_pr(v3_pr), .v3_pw(v3_pw), .v3_ph(v3_ph),
        .v3_lr(v3_lr), .v3_lw(v3_lw), .v3_lo(v3_lo), .v3_lh(v3_lh),
        .v3_rc(v3_rc), .v3_vc(v3_vc),
        .v3_vx(v3_vx), .v3_vs(v3_vs), .v3_vr(v3_vr), .v3_vn(v3_vn),
        .v4_cn(v4_cn), .v4_rd(v4_rd), .v4_nc(v4_nc), .v4_np(v4_np),
        .v4_wf(v4_wf), .v4_rl(v4_rl), .v4_wc(v4_wc),
        .v5_dv_idx(v5_dv), .v5_dv_got(v5_dg), .v5_dv_exp(v5_de),
        .v5_dv_off(v5_do), .v5_dv_mm(v5_dm), .v5_dv_v(v5_vz),
        .v5_up_pass(v5_ps), .v5_up_nm(v5_nm), .v5_up_ipc(v5_ic),
        .v5_up_crc(v5_dc), .v5_up_bytes(v5_sb),
        .v6_dv_idx(v6_cv), .v6_dv_got(v6_cg), .v6_dv_exp(v6_ce),
        .v6_dv_off(v6_co), .v6_dv_mm(v6_cm), .v6_dv_v(v6_cz),
        .v6_dv_sk(v6_cs),
        .v7_id_viol(v7_iv), .v7_id_seen(v7_is), .v7_id_cur(v7_ia),
        .v7_id_prev(v7_ib), .v7_id_back(v7_iw), .v7_nb(v7_nb)
    );

    wire [31:0] ds_idx, ds_b1, ds_b2, ds_bg, ds_dup;
    wire [7:0]  ds_got, ds_exp, ds_prev;
    wire        ds_v;
    wire [63:0] ds_gw, ds_ew;
    wire [31:0] ds_oz, ds_ol, ds_om, ds_oh;
    wire [31:0] a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
    wire [15:0] v4_ne, v4_nr, v4_mr;
    wire [3:0]  v4_en;
    wire        v4_eo;
    wire [23:0] v4_qa, v4_qb, v4_qc, v4_qd, v4_qe, v4_qf, v4_qg, v4_qh;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(paylen_v[11:0]),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b0), .m_tlast(),
        .rx_tdata(a_tdata), .rx_tkeep(a_tkeep), .rx_tvalid(a_tvalid),
        .rx_tready(a_tready), .rx_tlast(a_tlast), .rx_sof(a_sof), .rx_len(a_len),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_rx_bytes(a_rx_bytes),
        .stat_rx_frames(a_rx_frames), .stat_rx_null(a_rx_null),
        .stat_mismatch(a_mismatch), .active(), .done(), .led(),
        .ds_idx(ds_idx),
        .ds_b1(ds_b1), .ds_b2(ds_b2), .ds_bg(ds_bg), .ds_dup(ds_dup),
        .ds_got(ds_got), .ds_exp(ds_exp), .ds_prev(ds_prev), .ds_v(ds_v),
        .ds_gw(ds_gw), .ds_ew(ds_ew),
        .ds_oz(ds_oz), .ds_ol(ds_ol), .ds_om(ds_om), .ds_oh(ds_oh),
        .ds_cap(ds_cap),
        .v4_ne(v4_ne), .v4_nr(v4_nr), .v4_mr(v4_mr),
        .v4_en(v4_en), .v4_eo(v4_eo),
        .v4_ea(v4_qa), .v4_eb(v4_qb), .v4_ec(v4_qc), .v4_ed(v4_qd),
        .v4_ee(v4_qe), .v4_ef(v4_qf), .v4_eg(v4_qg), .v4_eh(v4_qh)
    );

    //=========================================================================
    // Interface-side model (truth source = app RX handshake + known geometry)
    //=========================================================================
    integer m_pop;          // words popped by the consumer (= uf_rptr)
    integer m_sof;          // frame starts seen at the app port
    integer m_done;
    integer m_null;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_pop <= 0; m_sof <= 0; m_done <= 0; m_null <= 0;
        end else if (a_tvalid && a_tready) begin
            if (a_sof) begin
                m_sof <= m_sof + 1;
                if (a_len == 16'd0) m_null <= m_null + 1;
            end
            if (a_len != 16'd0) m_pop <= m_pop + 1;
            if (a_tlast)        m_done <= m_done + 1;
        end
    end

    // Never-backpressure observation: if the TB feeds faster than the reader can
    // drain, the "structurally never backpressures" premise is broken.
    integer stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stall_cyc <= 0;
        else if (!s_tready) stall_cyc <= stall_cyc + 1;

    //=========================================================================
    // Stimulus: build a classify-slow word stream (headers as in tb_rxp_v3..v6)
    //=========================================================================
    localparam integer SN = 16384;
    reg [76:0] stim [0:SN-1];
    integer    sp;

    reg [7:0]  fb [0:2047];
    integer    flen;

    task fb_put(input [7:0] b); begin fb[flen] = b; flen = flen + 1; end endtask
    task fb_put16(input [15:0] v); begin
        fb[flen] = v[15:8]; fb[flen+1] = v[7:0]; flen = flen + 2; end endtask
    task fb_put32(input [31:0] v); begin
        fb[flen]=v[31:24]; fb[flen+1]=v[23:16]; fb[flen+2]=v[15:8]; fb[flen+3]=v[7:0];
        flen = flen + 4; end endtask

    // Per-frame variable header params (declared before the tasks that use them)
    reg [15:0] id_v;            // IP identification (network order value)
    reg [7:0]  proto_v;         // IP protocol (0x11 = UDP)
    reg [15:0] etype_v;         // ethertype (0x0800 = IPv4)
    reg [15:0] dport_v;         // destination port
    reg        junk_v;          // 1 = payload is the BITWISE COMPLEMENT of the
                                //     pattern at junk_base_v (guaranteed mismatch)
    reg [15:0] junk_base_v;     // pattern index the payload must NOT match
    reg [15:0] wp_v;            // idle cycles inserted AFTER every word (0 = back to back)

    integer h_i; reg [19:0] h_sum; reg [16:0] h_f1; reg [15:0] h_ck;
    task mk_hdr(input integer iplen);
        begin
            flen = 0;
            fb_put32(32'h000A3501); fb_put16(16'hFEC0);     // dst mac
            fb_put32(32'h11223344); fb_put16(16'h5566);     // src mac
            fb_put16(etype_v);                              // ethertype
            fb_put(8'h45); fb_put(8'h00);                   // ver/ihl, dscp
            fb_put16(iplen[15:0]); fb_put16(id_v); fb_put16(16'h4000);
            fb_put(8'd64); fb_put(proto_v);                 // ttl, proto
            fb_put16(16'h0000);                             // ip csum placeholder
            fb_put32(PEER_IP); fb_put32(MY_IP);
            h_sum = 20'd0;
            for (h_i = 0; h_i < 10; h_i = h_i + 1)
                h_sum = h_sum + {4'b0, fb[14+2*h_i], fb[15+2*h_i]};
            h_f1 = h_sum[15:0] + {12'b0, h_sum[19:16]};
            h_ck = ~(h_f1[15:0] + {15'b0, h_f1[16]});
            fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0];
        end
    endtask

    integer u_i; reg [15:0] u_len;
    // base = payload start in the pattern stream; plen = payload bytes;
    // bad_udplen: declare more than actually present
    task mk_udp_frame(input integer base, input integer plen, input integer bad_udplen);
        begin
            mk_hdr(plen + 28);
            fb_put16(16'h3039);            // sport
            fb_put16(dport_v);             // dport
            u_len = plen + 8;
            if (bad_udplen) u_len = plen + 58;
            fb_put16(u_len); fb_put16(16'h0000);            // udp len, udp csum
            for (u_i = 0; u_i < plen; u_i = u_i + 1) begin
                if (junk_v) fb_put(payc[junk_base_v + u_i] ^ 8'hFF);
                else        fb_put(payc[base + u_i]);
            end
        end
    endtask

    integer e_w, e_b, e_nw, e_nb;
    reg [63:0] e_d;  reg [7:0] e_k;
    task emit_frame(input integer crc_ok, input integer gap);
        begin
            e_nw = (flen + 7) / 8;
            for (e_w = 0; e_w < e_nw; e_w = e_w + 1) begin
                e_nb = flen - e_w*8;  if (e_nb > 8) e_nb = 8;
                e_d = 64'd0;  e_k = 8'hFF << (8 - e_nb);
                for (e_b = 0; e_b < e_nb; e_b = e_b + 1)
                    e_d[63 - 8*e_b -: 8] = fb[e_w*8 + e_b];
                stim[sp] = {1'b1, e_d, e_k, (e_w == e_nw-1), (e_w == 0),
                            (((e_w == e_nw-1) && (crc_ok != 0)) ? 1'b1 : 1'b0), 1'b0};
                sp = sp + 1;
                // word pacing: the v6/v7 engine needs 2 cycles/word and the input
                // port cannot be backpressured => insert idle beats
                for (e_b = 0; e_b < wp_v; e_b = e_b + 1) begin
                    stim[sp] = 77'd0; sp = sp + 1;
                end
            end
            for (e_w = 0; e_w < gap; e_w = e_w + 1) begin stim[sp] = 77'd0; sp = sp + 1; end
        end
    endtask

    integer r_i;
    // Non-blocking landing per beat (gotchas 3/17: a blocking write inside an
    // @(posedge clk) loop races the DUT and produces phantom failures)
    task run_stim(input integer a, input integer b);
        begin
            for (r_i = a; r_i < b; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= stim[r_i][76];
                s_tdata  <= stim[r_i][75:12];
                s_tkeep  <= stim[r_i][11:4];
                s_tlast  <= stim[r_i][3];
                s_tuser  <= stim[r_i][2];
                s_tcrs   <= stim[r_i][1];
                s_terr   <= stim[r_i][0];
            end
        end
    endtask

    task idle_drive(input integer n);
        begin
            for (r_i = 0; r_i < n; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= 1'b0; s_tdata <= 64'd0; s_tkeep <= 8'd0;
                s_tlast <= 1'b0;  s_tuser <= 1'b0; s_tcrs <= 1'b0; s_terr <= 1'b0;
            end
        end
    endtask

    integer fail = 0;
    // `!==` so that X counts as a failure
    // NOTE: the name port is [511:0] on purpose (a narrower port left-truncates
    // long messages, and a clipped FAIL line is useless in a mutation log).
    task chk(input cond, input [511:0] name);
        begin
            if (cond !== 1'b1) begin
                fail = fail + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0;
            repeat (20) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    //=========================================================================
    // Baselines (round-cumulative counters => compare deltas)
    //=========================================================================
    integer s_ps, s_nm, s_ic, s_dc, s_sb, s_rxf, s_mm, s_rl;
    task v7_snap;
        begin
            s_ps = v5_ps; s_nm = v5_nm; s_ic = v5_ic; s_dc = v5_dc;
            s_sb = v5_sb; s_rxf = a_rx_frames; s_mm = a_mismatch; s_rl = v4_rl;
        end
    endtask

    task v7_dump(input [255:0] nm);
        begin
            $display("RXPV7 A %0s iv=%0d is=%0d ia=%04X ib=%04X iw=%0d nb=%0d | v6 cnt=%0d cm=%0d cz=%0d cs=%0d | v5 dm=%0d | app II=%0d UMM=%0d URF=%0d",
                     nm, v7_iv, v7_is, v7_ia, v7_ib, v7_iw, v7_nb,
                     u_split.v6_cnt, v6_cm, v6_cz, v6_cs, v5_dm,
                     ds_idx, a_mismatch, a_rx_frames);
        end
    endtask

    //=========================================================================
    // Phases
    //=========================================================================
    integer fi;

    // Feed n frames one at a time + wait for each to drain (occupancy stays at
    // the 1-frame level => paths stay isolated: no overflow, no rollback).
    // id_start + fi = the per-frame IP id (the peer's "+1 per frame" contract);
    // payload = the natural pattern continuation (fi*plen).
    task feed_seq(input integer n, input integer plen, input integer id_start);
        begin
            for (fi = 0; fi < n; fi = fi + 1) begin
                sp = 0;
                id_v = id_start + fi;
                dport_v = APP_PORT; etype_v = 16'h0800; proto_v = 8'h11;
                junk_v = 1'b0;
                mk_udp_frame(fi*plen, plen, 0);
                emit_frame(1, 4);
                run_stim(0, sp);
                idle_drive(1800);
            end
        end
    endtask

    // One frame with an explicit id / destination port / payload base.
    task feed_one(input integer base, input integer plen, input integer idv,
                  input [15:0] dp);
        begin
            sp = 0;
            id_v = idv[15:0]; dport_v = dp;
            etype_v = 16'h0800; proto_v = 8'h11; junk_v = 1'b0;
            mk_udp_frame(base, plen, 0);
            emit_frame(1, 4);
            run_stim(0, sp);
            idle_drive(1800);
        end
    endtask

    // One frame whose payload is the bitwise complement of the pattern at
    // `jb` (guaranteed to differ from the checker's expectation).
    task feed_junk(input integer jb, input integer plen, input integer idv,
                   input [15:0] etype, input [7:0] proto);
        begin
            sp = 0;
            id_v = idv[15:0]; etype_v = etype; proto_v = proto;
            junk_v = 1'b1; junk_base_v = jb[15:0];
            mk_udp_frame(0, plen, 0);
            emit_frame(1, 4);
            run_stim(0, sp);
            junk_v = 1'b0;
            idle_drive(1800);
        end
    endtask

    task clean_pat;
        begin
            for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        end
    endtask

    initial begin
        s_tvalid = 1'b0; s_tdata = 64'd0; s_tkeep = 8'd0;
        s_tlast = 1'b0; s_tuser = 1'b0; s_tcrs = 1'b0; s_terr = 1'b0;
        cfg_dip = MY_IP; paylen_v = PLEN[15:0];
        dport_v = APP_PORT; id_v = 16'h1234; proto_v = 8'h11; etype_v = 16'h0800;
        junk_v = 1'b0; junk_base_v = 16'd0; wp_v = 16'd2;
        sp = 0; fail = 0;
        clean_pat;

        //---------------------------------------------------------------------
        // P1 POSITIVE: consecutive ids then ONE known jump.
        //    ids 0x1000,0x1001,0x1002 then 0x2000 => exactly ONE violation, and
        //    the latched pair must be {this=0x2000, prev=0x1002} bit for bit.
        //    (payloads stay pattern-continuous: bases 0,PLEN,2*PLEN,3*PLEN)
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_seq(NFRM - 1, PLEN, 16'h1000);
        feed_one(3*PLEN, PLEN, 16'h2000, APP_PORT);
        idle_drive(400);
        v7_dump("P1");
        chk(v7_iv === 16'd1, "P1 IV != 1 (exactly one violation)");
        chk(v7_is === 16'd4, "P1 IS != 4 (compared frames)");
        chk(v7_ia === 16'h2000, "P1 IA != 0x2000 (this-frame id at first violation)");
        chk(v7_ib === 16'h1002, "P1 IB != 0x1002 (prev id at first violation)");
        chk(v7_iw === 16'd0, "P1 IW != 0 (forward jump must not count as backwards)");
        chk(v7_ia !== v7_ib, "P1 IA == IB (fields not distinguishable)");
        // orthogonality: the ids are out of order while the payloads are clean
        chk(v6_cm === 32'd0, "P1 CM != 0 (payload must stay clean)");
        chk(v6_cz === 1'b0, "P1 CZ != 0");
        chk(v5_dm === 32'd0, "P1 DM != 0 (payload must stay clean)");
        chk(a_mismatch === s_mm, "P1 app mismatch != 0");
        chk(u_split.v6_cnt === 32'd5888, "P1 v6_cnt != 4*1472 (checker dead?)");
        chk(v5_ps - s_ps === NFRM, "P1 PS != 4");

        //---------------------------------------------------------------------
        // P2 ZERO: ids strictly +1 over 6 frames => IV=0 IW=0 while IS=6 and
        //    v6_cnt == 6*1472 ("ran the whole stream and saw nothing").
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_seq(6, PLEN, 16'h3000);
        idle_drive(400);
        v7_dump("P2");
        chk(v7_iv === 16'd0, "P2 IV != 0 on a strictly +1 sequence");
        chk(v7_iw === 16'd0, "P2 IW != 0");
        chk(v7_is === 16'd6, "P2 IS != 6 (anti-dead-zero: the comparison never ran?)");
        chk(v7_ia === 16'd0 && v7_ib === 16'd0, "P2 IA/IB != 0 (no violation latched)");
        chk(v6_cm === 32'd0 && v6_cz === 1'b0, "P2 CM/CZ != 0");
        chk(u_split.v6_cnt === 32'd8832, "P2 v6_cnt != 6*1472");
        chk(a_mismatch === s_mm, "P2 app mismatch != 0");
        chk(v5_ps - s_ps === 6, "P2 PS != 6");
        chk(v5_sb - s_sb === 6*PLEN, "P2 SB != 6*1472");
        // IS must move with the number of frames (not stuck at a fixed value)
        chk(v7_is !== v7_iv, "P2 IS == IV (wrong wire?)");

        //---------------------------------------------------------------------
        // P3 FIELD POSITION / BYTE ORDER: the two ids are byte-swaps of each
        //    other => a swapped or offset-shifted field read cannot reproduce
        //    IA/IB; P3b then proves the +1 domain is the constructed one.
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_one(0,    PLEN, 16'hA5C3, APP_PORT);
        feed_one(PLEN, PLEN, 16'h3C5A, APP_PORT);
        idle_drive(400);
        v7_dump("P3a");
        chk(v7_is === 16'd2, "P3a IS != 2");
        chk(v7_iv === 16'd1, "P3a IV != 1 (0x3C5A is not 0xA5C3+1)");
        chk(v7_iw === 16'd1, "P3a IW != 1 (0x3C5A < 0xA5C3 => backwards)");
        chk(v7_ia === 16'h3C5A, "P3a IA != 0x3C5A (byte order / offset wrong?)");
        chk(v7_ib === 16'hA5C3, "P3a IB != 0xA5C3 (byte order / offset wrong?)");
        // P3b: +1 in the SAME domain (0x3C5A -> 0x3C5B) must be clean; a
        // byte-swapped comparator would see 0x5A3C -> 0x5B3C (delta 0x100).
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_seq(2, PLEN, 16'h3C5A);
        idle_drive(400);
        v7_dump("P3b");
        chk(v7_is === 16'd2, "P3b IS != 2");
        chk(v7_iv === 16'd0, "P3b IV != 0 (0x3C5B must be 0x3C5A+1)");
        chk(v7_iw === 16'd0, "P3b IW != 0");

        //---------------------------------------------------------------------
        // P4 SCOPE: only frames that pass the MATCH GATE are compared.
        //    F1 id=0x0100 (matching), F2 id=0x0200 (NON-matching port),
        //    F3 id=0x0101 (matching) => IV=0 IS=2.
        //    "compare all frames" would give IV=2 IS=3 (F2 in the chain).
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_one(0,      PLEN, 16'h0100, APP_PORT);
        feed_one(PLEN,   PLEN, 16'h0200, BAD_PORT);
        feed_one(2*PLEN, PLEN, 16'h0101, APP_PORT);
        idle_drive(400);
        v7_dump("P4");
        chk(v7_is === 16'd2, "P4 IS != 2 (non-matching frame must not participate)");
        chk(v7_iv === 16'd0, "P4 IV != 0 (0x0101 must be compared against 0x0100)");
        chk(v7_iw === 16'd0, "P4 IW != 0");
        // the non-matching frame really was filtered out (not silently delivered)
        chk(v5_nm - s_nm === 32'd1, "P4 parser nonmatch delta != 1");
        chk(a_rx_frames - s_rxf === 32'd2, "P4 app frames delta != 2 (filter failed)");
        chk(v6_cm === 32'd0, "P4 CM != 0 (all three payloads are pattern-continuous)");
        chk(u_split.v6_cnt === 32'd4416, "P4 v6_cnt != 3*1472 (v6 counts all UDP frames)");

        //---------------------------------------------------------------------
        // P5 TASK B: non-UDP frames are neither compared nor allowed to push
        //    the LFSR.  F1 (UDP, clean) then ICMP + ARP junk (payload = the
        //    BITWISE COMPLEMENT of the expected pattern) then F2 (UDP, clean
        //    continuation) => CM=0 CZ=0 CV=0, NB == skipped bytes exactly.
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_one(0, PLEN, 16'h4000, APP_PORT);                    // F1: UDP clean
        feed_junk(PLEN, 100, 16'h4001, 16'h0800, 8'h01);          // ICMP (proto 1)
        feed_junk(PLEN, 60,  16'h4002, 16'h0806, 8'h11);          // ARP (ethertype 0806)
        feed_one(PLEN, PLEN, 16'h4003, APP_PORT);                 // F2: UDP continuation
        idle_drive(400);
        v7_dump("P5");
        chk(v6_cm === 32'd0, "P5 CM != 0 (non-UDP frame was compared!)");
        chk(v6_cz === 1'b0, "P5 CZ != 0 (non-UDP frame was compared!)");
        chk(v6_cv === 32'd0, "P5 CV != 0 (non-UDP frame was compared!)");
        chk(v7_nb === 16'd160, "P5 NB != 160 (100 ICMP + 60 ARP payload bytes)");
        chk(u_split.v6_cnt === 32'd2944, "P5 v6_cnt != 2*1472 (only UDP payloads)");
        chk(v5_dm === 32'd0, "P5 DM != 0");
        chk(a_mismatch === s_mm, "P5 app mismatch != 0 (LFSR phase pushed out?)");
        chk(ds_idx === 32'd0, "P5 app ds_idx != 0");
        chk(a_rx_frames - s_rxf === 32'd2, "P5 app frames delta != 2");
        chk(v5_nm - s_nm === 32'd2, "P5 parser nonmatch delta != 2 (ICMP+ARP dropped)");
        // Only the two UDP frames pass the MATCH gate (the ICMP/ARP ones fail
        // proto/ethertype) => IS=2, and their ids are 0x4000 / 0x4003 (the two
        // junk frames consumed ids in between) => exactly one forward jump.
        chk(v7_is === 16'd2, "P5 IS != 2 (only the two UDP frames pass the gate)");
        chk(v7_iv === 16'd1, "P5 IV != 1 (0x4003 vs 0x4000+1 must be one violation)");
        chk(v7_iw === 16'd0, "P5 IW != 0 (forward jump, not backwards)");
        chk(v7_ia === 16'h4003 && v7_ib === 16'h4000,
            "P5 IA/IB != 0x4003/0x4000 (junk frame ids leaked into the chain?)");
        chk(v6_cs === 8'd0, "P5 CS != 0 (skid overflowed -- readings unusable)");

        //---------------------------------------------------------------------
        // P6 (task B, board shape): clean data frames followed by a trailing
        //    non-UDP frame -- the exact shape of the 100 Mbps board round
        //    (CM was 560 there, with CV == the round's payload byte count).
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v7_snap;
        feed_seq(3, PLEN, 16'h5000);                              // clean data
        feed_junk(3*PLEN, 560, 16'h5003, 16'h0800, 8'h01);        // trailing ICMP, 560 B
        idle_drive(400);
        v7_dump("P6");
        chk(v6_cm === 32'd0, "P6 CM != 0 (trailing non-UDP frame compared!)");
        chk(v6_cz === 1'b0, "P6 CZ != 0 (trailing non-UDP frame compared!)");
        chk(v7_nb === 16'd560, "P6 NB != 560 (the 100 Mbps board artifact must move here)");
        chk(u_split.v6_cnt === 32'd4416, "P6 v6_cnt != 3*1472");
        chk(a_mismatch === s_mm, "P6 app mismatch != 0");
        chk(v7_iv === 16'd0 && v7_is === 16'd3, "P6 IV/IS != 0/3");

        chk(stall_cyc == 0, "tready went 0 (TB over-fed)");
        if (fail == 0) $display("RXP-V7 GATE: OK");
        else           $display("RXP-V7 GATE: FAIL (%0d)", fail);
        $finish;
    end

    // watchdog
    initial begin
        repeat (8000000) @(posedge clk);
        $display("RXP-V7 GATE: FAIL (timeout) pop=%0d done=%0d", m_pop, m_done);
        $finish;
    end
endmodule
