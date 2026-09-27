`timescale 1ns/1ps
//=============================================================================
// tb_rxp_v6.v -- RXP_DIAG v6 FUNCTIONAL gate: the THIRD LFSR byte checker,
// sitting on the *input port side* of udp_split (the stream entering u_pre).
// (ISSUE_RX_BYTE_CORRUPTION sections 18.9 / 18.10 / 18.13)
//=============================================================================
// WHAT THIS GATE IS FOR
//   v6 answers the "three cannot all be true" contradiction of section 18.9:
//     (1) a permutation needs a frame-sized store, (2) nothing before `din` can
//     hold a frame, (3) `SW == GW != EW` says `din` is already rotated.
//   The input port of u_pre is the only stream on the path that was never
//   instrumented.  Claim under test: v6 must see EXACTLY the same byte stream
//   as v5 (din) and as the app (ds_idx) -- three independent mechanisms
//   (input-side counter / write-port counter / delivered-byte counter) agreeing
//   byte for byte.  A one-byte LFSR phase difference between any two of them
//   turns a phase red.
//
// PHASES (all assert exact values; `chk` uses `!==` so X is a failure)
//   V1  POSITIVE : one known injected mismatch (frame 2, payload offset 100
//                  => global payload byte 3044).  Asserts CV/CG/CE/CO exactly,
//                  plus CM=1 CZ=1, plus the cross-mechanism anchors
//                  CV == app ds_idx, CM == app stat_mismatch, CV == v5 DV,
//                  and CO == CV % paylen.
//   V2  ZERO     : clean 4x1472B.  CM=0 CZ=0 AND `u_split.v6_cnt` == 4*1472
//                  (positive proof the checker actually ran the whole stream --
//                  a dead checker would also print zero).
//   V3  42-BYTE SKIP BOUNDARY : UDP-checksum low byte (frame byte 41) set to a
//                  distinctive 0x5A while payload bytes 0/1 (frame bytes 42/43)
//                  stay clean => CM must stay 0 (a 41-byte skip would compare
//                  0x5A as payload byte 0).  Then payload byte 1 of frame 1 is
//                  flipped => CV=1473 CO=1 (a 43-byte skip would report CV=1472
//                  CO=0 with CG=payload[1]).
//   V4  PARTIAL TAIL WORD : paylen 1471 (frame 1513 B => last word 1 byte).
//                  Injects payload 1470 (a 1-byte tail word) and 1471 (frame 1
//                  offset 0) => CV=1470 CO=1470 CM=2, and CV == ds_idx.
//   V5  TWO MISMATCHES in ONE engine phase (payload 100 and 101 are lanes 2/3
//                  of the same word's phase B) => CM=2 while CV/CO point at the
//                  FIRST one.
//   V6  TWO MISMATCHES in DIFFERENT phases (payload 96 = phase A lane 2,
//                  payload 100 = phase B lane 2) => CM=2, CV=3040 CO=96.
//   V7  OVER-SPEED (word pacing 0 = back to back): the engine does 1 word per
//                  2 cycles while the input can present 1 word per cycle => the
//                  skid overflows and CS must go non-zero.  This is the POSITIVE
//                  proof that CS is a live indicator and not a dead zero; it also
//                  documents the throughput ceiling (1G line rate = 1 word per 8
//                  cycles, i.e. 4x margin => CS==0 on the board).
//
// WORD PACING: every phase except V7 drives `wp_v` idle cycles between words.
//   The engine needs 2 cycles/word; wp_v=2 (3 cycles/word) is used for the
//   functional phases so the skid never overflows (CS == 0 asserted everywhere
//   except V7) -- matching the board, where the 1G line rate delivers one 64-bit
//   word every 8 cycles.
//
// ASCII-only, CRLF.  Never redirect to xvlog.log / xelab.log.
//=============================================================================
module tb_rxp_v6;
    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [31:0] PEER_IP  = 32'hC00A0001;   // 192.168.100.1
    localparam [15:0] APP_PORT = 16'd9000;
    localparam integer PLEN    = 1472;           // board payload (184 words)
    localparam integer PLEN4   = 1471;           // V4: non-multiple of 8 => 1-byte tail
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
    // DUT: udp_split (real player + real rollback + v3/v4/v5/v6 checkers)
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

    // v3/v4/v5 observation ports (same as tb_rxp_v5; kept for cross-generation
    // accounting -- this gate only asserts v6 + the v5 cross-anchor)
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

    // v6 observation ports (A: input-port-side LFSR checker)
    wire [31:0] v6_cv, v6_cm;
    wire [7:0]  v6_cg, v6_ce, v6_cs;
    wire [15:0] v6_co;
    wire        v6_cz;

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
        .v6_dv_sk(v6_cs)
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
    // Stimulus: build a classify-slow word stream (headers as in tb_rxp_v3/v4/v5)
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

    // Per-frame variable header params (set per phase; declared before the tasks
    // that use them -- xvlog requires declare-before-use)
    reg [15:0] dport_v;         // destination port
    reg        ipc_bad;         // 1 = flip one bit of the IP header checksum
    reg [7:0]  ucsum_lo_v;      // V3: low byte of the UDP checksum field (= frame byte 41)
    reg [15:0] wp_v;            // idle cycles inserted AFTER every word (0 = back to back)

    integer h_i; reg [19:0] h_sum; reg [16:0] h_f1; reg [15:0] h_ck;
    task mk_hdr(input integer iplen);
        begin
            flen = 0;
            fb_put32(32'h000A3501); fb_put16(16'hFEC0);     // dst mac
            fb_put32(32'h11223344); fb_put16(16'h5566);     // src mac
            fb_put16(16'h0800);                             // ethertype IPv4
            fb_put(8'h45); fb_put(8'h00);                   // ver/ihl, dscp
            fb_put16(iplen[15:0]); fb_put16(16'h1234); fb_put16(16'h4000);
            fb_put(8'd64); fb_put(8'h11);                   // ttl, UDP
            fb_put16(16'h0000);                             // ip csum placeholder
            fb_put32(PEER_IP); fb_put32(MY_IP);
            h_sum = 20'd0;
            for (h_i = 0; h_i < 10; h_i = h_i + 1)
                h_sum = h_sum + {4'b0, fb[14+2*h_i], fb[15+2*h_i]};
            h_f1 = h_sum[15:0] + {12'b0, h_sum[19:16]};
            h_ck = ~(h_f1[15:0] + {15'b0, h_f1[16]});
            if (ipc_bad) fb[24] = h_ck[15:8] ^ 8'h01;       // flip LSB => ipcsum_ok=0
            else begin fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0]; end
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
            fb_put16(u_len); fb_put16({8'h00, ucsum_lo_v});  // udp len, udp csum (V3 uses byte 41)
            for (u_i = 0; u_i < plen; u_i = u_i + 1) fb_put(payc[base + u_i]);
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
                // word pacing: the v6 engine needs 2 cycles/word, the input port
                // cannot be backpressured => insert idle beats (gotcha: a
                // back-to-back burst overflows the skid and is counted in CS)
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

    integer wt_i;
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
    // `!==` so that X counts as a failure (v3's M4 mutation proved `if (!cond)`
    // treats X as a pass)
    // NOTE: the name port is [511:0] (64 bytes) on purpose.  The v3/v4/v5 TBs use
    // [255:0] (32 bytes), so any longer message loses its LEADING characters in the
    // log (a Verilog string literal assigned to a narrower vector is left-truncated):
    // v6's messages are longer than 32 chars, and a clipped "FAIL:  detected -- CS is
    // a dead zero!)" is useless when reading a mutation log.  Widening the port is a
    // display-only change -- it cannot alter any comparison.
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
    // Baseline snapshot (app counters are round-cumulative => compare deltas)
    //=========================================================================
    integer s_ps, s_nm, s_ic, s_dc, s_sb, s_rxf, s_mm, s_rl;
    task v6_snap;
        begin
            s_ps = v5_ps; s_nm = v5_nm; s_ic = v5_ic; s_dc = v5_dc;
            s_sb = v5_sb; s_rxf = a_rx_frames; s_mm = a_mismatch; s_rl = v4_rl;
        end
    endtask

    task v6_dump(input [255:0] nm);
        begin
            $display("RXPV6 A %0s cv=%0d cg=%02X ce=%02X co=%0d cm=%0d cz=%0d cs=%0d | cnt=%0d",
                     nm, v6_cv, v6_cg, v6_ce, v6_co, v6_cm, v6_cz, v6_cs,
                     u_split.v6_cnt);
            $display("RXPV6 B %0s | v5(din) dv=%0d dg=%02X de=%02X do=%0d dm=%0d | app II=%0d UMM=%0d URF=%0d | dPS=%0d dRL=%0d",
                     nm, v5_dv, v5_dg, v5_de, v5_do, v5_dm,
                     ds_idx, a_mismatch, a_rx_frames,
                     v5_ps - s_ps, v4_rl - s_rl);
        end
    endtask

    //=========================================================================
    // Phases
    //=========================================================================
    integer fi, wi, inj_i;

    // Feed n frames one at a time + wait for each to drain (occupancy stays at
    // the 1-frame level => paths stay isolated: no overflow, no rollback)
    task feed_paced(input integer n, input integer plen);
        begin
            for (fi = 0; fi < n; fi = fi + 1) begin
                sp = 0;
                mk_udp_frame(fi*plen, plen, 0);
                emit_frame(1, 4);
                run_stim(0, sp);
                idle_drive(1800);
            end
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
        dport_v = APP_PORT; ipc_bad = 1'b0;
        ucsum_lo_v = 8'h00; wp_v = 16'd2;
        sp = 0; fail = 0;
        clean_pat;

        //---------------------------------------------------------------------
        // V1 POSITIVE: one known injected mismatch (frame 2, payload 100
        //    => global payload byte 2*1472+100 = 3044)
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[2*PLEN + 100] = pay[2*PLEN + 100] ^ 8'h40;
        paylen_v = PLEN[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v6_dump("V1");
        chk(v6_cv === 32'd3044, "V1 CV != 3044 (global payload index of the injection)");
        chk(v6_cg === (pay[3044] ^ 8'h40), "V1 CG != injected byte");
        chk(v6_ce === pay[3044], "V1 CE != clean pattern byte");
        chk(v6_co === 16'd100, "V1 CO != 100 (frame-internal offset)");
        chk(v6_cm === 32'd1, "V1 CM != 1");
        chk(v6_cz === 1'b1, "V1 CZ != 1");
        chk(v6_cs === 8'd0, "V1 CS != 0 (skid overflowed -- readings unusable)");
        chk(v6_co === (v6_cv % 32'd1472), "V1 CO != CV % paylen");
        // ★ three-mechanism agreement: input side (v6), write port (v5), delivered (app)
        chk(v6_cv === ds_idx, "V1 CV != app ds_idx (LFSR phase mismatch!)");
        chk(v6_cm === a_mismatch, "V1 CM != app stat_mismatch");
        chk(v6_cv === v5_dv, "V1 CV != v5 DV (v6/v5 anchors disagree!)");
        chk(v6_co === v5_do, "V1 CO != v5 DO");
        chk(u_split.v6_cnt === 32'd5888, "V1 v6_cnt != 4*1472 payload bytes fed");
        chk(v5_ps - s_ps === NFRM, "V1 PS != 4");

        //---------------------------------------------------------------------
        // V2 ZERO: clean stream.  CM=0 CZ=0 AND cnt == 4*1472 => "ran and saw
        //    nothing", not "dead checker".
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v6_dump("V2");
        chk(v6_cm === 32'd0, "V2 CM != 0 on clean stream");
        chk(v6_cz === 1'b0, "V2 CZ != 0 on clean stream");
        chk(v6_cv === 32'd0 && v6_cg === 8'd0 && v6_ce === 8'd0 && v6_co === 16'd0,
            "V2 CV/CG/CE/CO != 0 on clean stream");
        chk(v6_cs === 8'd0, "V2 CS != 0 (skid overflowed)");
        // anti-dead-zero: the byte counter must equal exactly the payload fed
        chk(u_split.v6_cnt === 32'd5888, "V2 v6_cnt != 4*1472 (checker dead?)");
        chk(a_mismatch === s_mm, "V2 app mismatch != 0");
        chk(v5_ps - s_ps === NFRM, "V2 PS != 4");
        chk(v5_sb - s_sb === NFRM*PLEN, "V2 SB != 4*1472");

        //---------------------------------------------------------------------
        // V3 42-BYTE SKIP BOUNDARY
        //   3a: frame byte 41 (UDP checksum low byte) = 0x5A, payload bytes 0/1
        //       clean => nothing may be compared before frame byte 42
        //       (a 41-byte skip would compare 0x5A against pay[0] at CV=0)
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        ucsum_lo_v = 8'h5A;
        paylen_v = PLEN[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v6_dump("V3a");
        chk(v6_cm === 32'd0, "V3a CM != 0 (byte 41 compared => skip != 42)");
        chk(v6_cz === 1'b0, "V3a CZ != 0 (byte 41 compared => skip != 42)");
        chk(u_split.v6_cnt === 32'd5888, "V3a v6_cnt != 4*1472");
        chk(v5_ps - s_ps === NFRM, "V3a PS != 4 (frame must still be delivered)");
        //   3b: same, plus a flip of payload byte 1 of frame 1 (frame byte 43).
        //       Correct 42-byte skip => CV = 1472+1 = 1473, CO = 1.
        //       A 43-byte skip would instead compare frame byte 43 against LFSR
        //       byte 0 and report CV=1472 CO=0 CG=payload[1].
        do_reset;
        clean_pat;
        payc[PLEN + 1] = pay[PLEN + 1] ^ 8'h10;
        ucsum_lo_v = 8'h5A;
        paylen_v = PLEN[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v6_dump("V3b");
        chk(v6_cv === 32'd1473, "V3b CV != 1473 (start alignment off)");
        chk(v6_cg === (pay[1473] ^ 8'h10), "V3b CG != injected byte");
        chk(v6_ce === pay[1473], "V3b CE != clean pattern byte");
        chk(v6_co === 16'd1, "V3b CO != 1 (frame-internal offset)");
        chk(v6_cm === 32'd1, "V3b CM != 1");
        chk(v6_cv === ds_idx, "V3b CV != app ds_idx");
        chk(v6_cv === v5_dv, "V3b CV != v5 DV");
        chk(u_split.v6_cnt === 32'd5888, "V3b v6_cnt != 4*1472");
        ucsum_lo_v = 8'h00;

        //---------------------------------------------------------------------
        // V4 PARTIAL TAIL WORD: paylen 1471 (frame 1513 B => last word 1 byte)
        //    inject payload 1470 (tail word, phase A lane 0 of a 1-byte word)
        //    and payload 1471 (frame 1 offset 0)
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[1470] = pay[1470] ^ 8'h20;
        payc[1471] = pay[1471] ^ 8'h04;
        paylen_v = PLEN4[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN4);
        idle_drive(400);
        v6_dump("V4");
        chk(v6_cv === 32'd1470, "V4 CV != 1470 (1-byte tail word)");
        chk(v6_cg === (pay[1470] ^ 8'h20), "V4 CG != injected byte");
        chk(v6_ce === pay[1470], "V4 CE != clean pattern byte");
        chk(v6_co === 16'd1470, "V4 CO != 1470");
        chk(v6_cm === 32'd2, "V4 CM != 2");
        chk(v6_cv === ds_idx, "V4 CV != app ds_idx (popcount anchor mismatch!)");
        chk(v6_cm === a_mismatch, "V4 CM != app stat_mismatch");
        chk(v6_cv === v5_dv, "V4 CV != v5 DV");
        chk(v6_co === (v6_cv % 32'd1471), "V4 CO != CV % paylen");
        chk(u_split.v6_cnt === 32'd5884, "V4 v6_cnt != 4*1471");
        chk(v5_ps - s_ps === NFRM, "V4 PS != 4");
        chk(v5_sb - s_sb === NFRM*PLEN4, "V4 SB != 4*1471");

        //---------------------------------------------------------------------
        // V5 TWO MISMATCHES IN ONE ENGINE PHASE: payload 100 and 101 are lanes
        //    2/3 of the same word's phase B => CM = 2 (both counted) while
        //    CV/CO still point at the FIRST one.
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[2*PLEN + 100] = pay[2*PLEN + 100] ^ 8'h40;
        payc[2*PLEN + 101] = pay[2*PLEN + 101] ^ 8'h01;
        paylen_v = PLEN[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v6_dump("V5");
        chk(v6_cv === 32'd3044, "V5 CV != 3044 (first of the two)");
        chk(v6_cg === (pay[3044] ^ 8'h40), "V5 CG != first bad byte");
        chk(v6_ce === pay[3044], "V5 CE != clean pattern byte");
        chk(v6_co === 16'd100, "V5 CO != 100");
        chk(v6_cm === 32'd2, "V5 CM != 2 (must count BOTH bad bytes)");
        chk(v6_cv === ds_idx && v6_cm === a_mismatch, "V5 CV/CM != app II/UMM");
        chk(v6_cv === v5_dv && v6_cm === v5_dm, "V5 CV/CM != v5 DV/DM");
        chk(u_split.v6_cnt === 32'd5888, "V5 v6_cnt != 4*1472");

        //---------------------------------------------------------------------
        // V6 TWO MISMATCHES IN DIFFERENT PHASES: payload 96 = phase A lane 2,
        //    payload 100 = phase B lane 2 of the SAME word => CM = 2, the
        //    snapshot must still be the phase-A one (CV = 2944+96 = 3040).
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[2*PLEN + 96]  = pay[2*PLEN + 96]  ^ 8'h08;
        payc[2*PLEN + 100] = pay[2*PLEN + 100] ^ 8'h40;
        paylen_v = PLEN[15:0];
        v6_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v6_dump("V6");
        chk(v6_cv === 32'd3040, "V6 CV != 3040 (phase-A mismatch must win)");
        chk(v6_cg === (pay[3040] ^ 8'h08), "V6 CG != phase-A injected byte");
        chk(v6_ce === pay[3040], "V6 CE != clean pattern byte");
        chk(v6_co === 16'd96, "V6 CO != 96");
        chk(v6_cm === 32'd2, "V6 CM != 2 (cross-phase accumulation)");
        chk(v6_cv === ds_idx && v6_cm === a_mismatch, "V6 CV/CM != app II/UMM");
        chk(v6_cv === v5_dv && v6_cm === v5_dm, "V6 CV/CM != v5 DV/DM");

        //---------------------------------------------------------------------
        // V7 OVER-SPEED: word pacing 0 (back to back, 1 word/cycle) -- the
        //    engine does 1 word per 2 cycles and the input CANNOT be
        //    backpressured => the skid overflows and CS must be non-zero.
        //    Positive proof that CS is a live indicator (not a dead zero).
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        wp_v = 16'd0;
        paylen_v = PLEN[15:0];
        sp = 0;
        mk_udp_frame(0, PLEN, 0);
        emit_frame(1, 4);
        run_stim(0, sp);
        idle_drive(600);
        v6_dump("V7");
        chk(v6_cs !== 8'd0, "V7 CS == 0 (over-speed not detected -- CS is a dead zero!)");
        wp_v = 16'd2;

        chk(stall_cyc == 0, "tready went 0 (TB over-fed)");
        if (fail == 0) $display("RXP-V6 GATE: OK");
        else           $display("RXP-V6 GATE: FAIL (%0d)", fail);
        $finish;
    end

    // watchdog
    initial begin
        repeat (4000000) @(posedge clk);
        $display("RXP-V6 GATE: FAIL (timeout) pop=%0d done=%0d", m_pop, m_done);
        $finish;
    end
endmodule
