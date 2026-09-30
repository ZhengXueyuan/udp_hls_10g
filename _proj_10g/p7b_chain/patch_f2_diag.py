#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b chain-gate F-2 attribution: add RAW diagnostics to tb_p7b_chain.v.

All additions are pure observation (no new judgements, no changed judgements):
  1. wf_start[]/wf_stop[]  - word index of each wire frame's /S/ and /T/
  2. dump_raw(from,to)     - every captured XGMII word, lane by lane
  3. dump_frames()         - every decoded wire frame's bytes, 8 per line
  4. injw_*                - every word actually written into u_txcdc (dp side)
  5. [TR n] trace          - per-cycle mac_tx_10g internals inside a window
  6. [F2W] prints          - is the capture-window reset (wq_wr = 0) honoured?

ASCII only on purpose: the .v file mixes real CJK with literal ESCAPED-CJK
comments, and a Python string literal mangles the latter.  Anchors avoid both.

Run:  <anaconda>/python.exe patch_f2_diag.py
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'

s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2-DIAG-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# ------------------------------------------------------- 1. declarations
sub("""    integer    wf_cur = 0, wf_len = 0;
    integer    wk, wl;""",
    """    integer    wf_cur = 0, wf_len = 0;
    integer    wk, wl;
    // ---- F2-DIAG-PATCH ----
    integer    wf_start [0:31];
    integer    wf_stop  [0:31];
    integer    wf_dump_max = 104;
    reg [63:0] injw_d [0:255];
    reg [7:0]  injw_k [0:255];
    reg        injw_l [0:255];
    integer    injw_n = 0;
    integer    f2_tr_n = 0, f2_tr_lim = 0;
    reg        f2_tr_on = 0;
    integer    f2_ev_n = 0;
    reg [63:0] f2_ev_d [0:63];
    reg [7:0]  f2_ev_c [0:63];
    reg        f2_ev_w = 0;
    integer    f2_ev_start = 0;""", 'decls')

# ------------------------------------------- 1b. record start/stop word idx
sub("""                    if (wcc === 1'b1 && wd === 8'hFB && wl == 0) begin
                        if (wf_cur < 32) begin wf_act = 1; wf_len = 0; end
                    end else if (wcc === 1'b1 && wd === 8'hFD) begin
                        if (wf_act && wf_cur < 32) begin
                            wf_n[wf_cur] = wf_len;
                            wf_cur = wf_cur + 1;
                        end
                        wf_act = 0;""",
    """                    if (wcc === 1'b1 && wd === 8'hFB && wl == 0) begin
                        if (wf_cur < 32) begin
                            wf_act = 1; wf_len = 0; wf_start[wf_cur] = wk;
                        end
                    end else if (wcc === 1'b1 && wd === 8'hFD) begin
                        if (wf_act && wf_cur < 32) begin
                            wf_n[wf_cur] = wf_len;
                            wf_stop[wf_cur] = wk;
                            wf_cur = wf_cur + 1;
                        end
                        wf_act = 0;""", 'decode_idxs')

# ------------------------------------------------------ 2/3. dump tasks
sub("""    task diag;
        input [127:0] tag;""",
    """    // ---- F2-DIAG-PATCH: raw XGMII word dump (index, c, d, lanes) ----
    task dump_raw;
        input integer from;
        input integer to;
        integer dk, dto;
        begin
            dto = (to < 16383) ? to : 16383;
            $display("  [RAW] span [%0d,%0d) wq_wr=%0d", from, dto, wq_wr);
            for (dk = from; dk < dto; dk = dk + 1) begin
                $display("  [RAW %0d] c=%02h d=%016h l0=%02h l1=%02h l2=%02h l3=%02h l4=%02h l5=%02h l6=%02h l7=%02h",
                    dk, wq_c[dk], wq_d[dk],
                    wq_d[dk][7:0], wq_d[dk][15:8], wq_d[dk][23:16], wq_d[dk][31:24],
                    wq_d[dk][39:32], wq_d[dk][47:40], wq_d[dk][55:48], wq_d[dk][63:56]);
            end
        end
    endtask

    // ---- F2-DIAG-PATCH: decoded wire frames, byte-exact ----
    task dump_frames;
        integer df, dk, dn;
        begin
            $display("  [WFRAMES] wf_cnt=%0d", wf_cnt);
            for (df = 0; df < wf_cnt && df < 32; df = df + 1) begin
                dn = wf_n[df];
                $display("  [WFRAME %0d] words[%0d..%0d] bytes=%0d",
                         df, wf_start[df], wf_stop[df], dn);
                for (dk = 0; dk < dn && dk < wf_dump_max; dk = dk + 8)
                    $display("    [%03d] %02h %02h %02h %02h %02h %02h %02h %02h",
                        dk, wf_b[df][dk], wf_b[df][dk+1], wf_b[df][dk+2], wf_b[df][dk+3],
                        wf_b[df][dk+4], wf_b[df][dk+5], wf_b[df][dk+6], wf_b[df][dk+7]);
                if (dn > wf_dump_max)
                    $display("    ... +%0d bytes not printed", dn - wf_dump_max);
            end
        end
    endtask

    // ---- F2-DIAG-PATCH: words actually written into u_txcdc (dp side) ----
    task dump_injw;
        integer di;
        begin
            $display("  [INJW] n=%0d", injw_n);
            for (di = 0; di < injw_n && di < 256; di = di + 1)
                $display("  [INJW %0d] keep=%02h last=%b d=%016h l0=%02h l1=%02h l2=%02h l3=%02h l4=%02h l5=%02h l6=%02h l7=%02h",
                    di, injw_k[di], injw_l[di], injw_d[di],
                    injw_d[di][7:0], injw_d[di][15:8], injw_d[di][23:16], injw_d[di][31:24],
                    injw_d[di][39:32], injw_d[di][47:40], injw_d[di][55:48], injw_d[di][63:56]);
        end
    endtask

    always @(posedge u_dut.dp_clk)
        if (u_dut.txsrc_tvalid && u_dut.txsrc_tready) begin
            if (injw_n < 256) begin
                injw_d[injw_n] = u_dut.txsrc_tdata;
                injw_k[injw_n] = u_dut.txsrc_tkeep;
                injw_l[injw_n] = u_dut.txsrc_tlast;
                injw_n = injw_n + 1;
            end
        end

    // ---- F2-DIAG-PATCH: per-cycle mac_tx_10g trace (windowed) ----
    always @(posedge u_dut.tx_mii_clk_1)
        if ((f2_tr_on == 1'b1) && (f2_tr_n < f2_tr_lim)) begin
            $display("  [TR %0d] st=%0d cwl=%0d cwlast=%b keep=%02h plen=%0d femp=%b frd=%b ftl=%b fcnt=%0d txd=%016h txc=%02h | abrt=%0d flw=%0d fldn=%0d frm=%0d txw=%0d sht=%0d clen=%0d | cdc_e=%b mtv=%b tsv=%b tsl=%b tsk=%02h tst=%b",
                f2_tr_n, u_dut.u_mac_tx.state, u_dut.u_mac_tx.cw_len,
                u_dut.u_mac_tx.cw_last, u_dut.u_mac_tx.cw_keep, u_dut.u_mac_tx.plen,
                u_dut.u_mac_tx.fempty, u_dut.u_mac_tx.frd, u_dut.u_mac_tx.flush_tl,
                u_dut.u_mac_tx.flush_cnt, u_dut.u_mac_tx.tx_d, u_dut.u_mac_tx.tx_c,
                u_dut.u_mac_tx.stat_abort, u_dut.u_mac_tx.stat_flush_words,
                u_dut.u_mac_tx.stat_flush_done, u_dut.u_mac_tx.stat_frames,
                u_dut.u_mac_tx.stat_tx_words, u_dut.u_mac_tx.stat_tx_short,
                u_dut.u_mac_tx.m_clen,
                u_dut.tx_fifo_empty, u_dut.m_tx_tvalid,
                u_dut.txsrc_tvalid, u_dut.txsrc_tlast, u_dut.txsrc_tkeep,
                u_dut.txsrc_tdata);
            f2_tr_n = f2_tr_n + 1;
        end

    task diag;
        input [127:0] tag;""", 'dump_tasks')

# ---------------------------------------- 4. instrument the F-2 (group 8) block
# (head of group 8: unique because of the all-zero second word)
sub("""        wq_wr = 0;
        force u_dut.txsrc_tdata = 64'h88776655_44332211;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b0;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tdata = 64'h00000000_00000000;
        force u_dut.txsrc_tkeep = 8'hFF;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;""",
    """        // ---- F2-DIAG-PATCH ----
        $display("  [F2W] group8 start $time=%0t wq_wr_before_reset=%0d", $time, wq_wr);
        injw_n = 0;
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 40;
        wq_wr = 0;
        $display("  [F2W] wq_wr_set=%0d", wq_wr);
        repeat (3) @(posedge u_dut.tx_mii_clk_1);
        $display("  [F2W] wq_wr_after3txedges=%0d  (~3 = reset honoured; ~1200 = stale group6 window)",
                 wq_wr);
        force u_dut.txsrc_tdata = 64'h88776655_44332211;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b0;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tdata = 64'h00000000_00000000;
        force u_dut.txsrc_tkeep = 8'hFF;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;""", 'grp8_head')

sub("""        force u_dut.txsrc_tdata = 64'hAABBCCDD_11223344;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b1;""",
    """        $display("  [F2W] before frame B $time=%0t wq_wr=%0d injw_n=%0d", $time, wq_wr, injw_n);
        f2_tr_n = 0; f2_tr_lim = 70;
        force u_dut.txsrc_tdata = 64'hAABBCCDD_11223344;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b1;""", 'grp8_B')

sub("""        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        decode_wire(wq_wr);
        begin : f2""",
    """        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        f2_tr_on = 1'b0;
        $display("  [F2W] decode $time=%0t wq_wr=%0d injw_n=%0d", $time, wq_wr, injw_n);
        dump_injw;
        decode_wire(wq_wr);
        dump_frames;
        $display("  [F2W] window head (first 10 captured words):");
        dump_raw(0, 10);
        if (wf_cnt > 0) begin
            $display("  [F2W] raw words of the decoded span:");
            dump_raw(wf_start[0], wf_stop[wf_cnt-1] + 2);
        end
        begin : f2""", 'grp8_decode')

# ------------------------------------- 5. group-6 window bookkeeping (baseline)
sub("""        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        decode_wire(wq_wr);   //""",
    """        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        $display("  [F2W] group6 decode $time=%0t wq_wr=%0d injw_n=%0d", $time, wq_wr, injw_n);
        begin : g6inj
            integer gi;
            $display("  [INJW6] n=%0d", injw_n);
            for (gi = 0; gi < injw_n && gi < 256; gi = gi + 1)
                $display("  [INJW6 %0d] keep=%02h last=%b d=%016h", gi, injw_k[gi], injw_l[gi], injw_d[gi]);
        end
        injw_n = 0;
        decode_wire(wq_wr);   //""", 'grp6_decode')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
