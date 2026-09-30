#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b chain-gate F-2 attribution, step 3: instrument the F2X experiments.

Findings so far (pristine run, logs/f2x_pristine.txt):
  X1 (ONE complete 60B frame injected) produced a 23-byte RUNT on the wire, i.e.
  the MAC aborted mid-frame although all 8 words were pushed.  Every experiment's
  frame is truncated.  => need the cycle view + the write record.

Adds:
  * injw_n = 0 in f2x_begin (per-experiment write record)
  * a gap-driven push variant  f2x_push_g / f2x_push_frame_g  (rate control)
  * X1 rewritten: X1a = frame with GAPS between words, X1b = frame back-to-back,
    each with [TR] trace + dump_injw, and counter deltas printed.
  * f2x_show prints the abort/flush/stat counter deltas of the experiment.
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X2-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# ---- gap-driven push (rate control for the CDC) ----
sub("""    // 把登记的第 f 帧按 7 满字 + 1 个 tkeep=F0 尾字推入 (总 60 内容字节, 无 pad)""",
    """    // F2X2-PATCH: 带间隔的注入 (测 CDC 可见性/速率效应)
    task f2x_push_g;
        input [63:0] d;
        input [7:0]  k;
        input        l;
        input integer gap;
        integer gi;
        begin
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = k;
            force u_dut.txsrc_tlast = l;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
            for (gi = 0; gi < gap; gi = gi + 1) @(negedge u_dut.dp_clk);
        end
    endtask

    task f2x_push_frame_g;
        input integer f;
        input integer gap;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 7; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                f2x_push_g(d, 8'hFF, 1'b0, gap);
            end
            d = {f2x_c[f*F2X_STRIDE+56], f2x_c[f*F2X_STRIDE+57],
                 f2x_c[f*F2X_STRIDE+58], f2x_c[f*F2X_STRIDE+59], 32'd0};
            f2x_push_g(d, 8'hF0, 1'b1, gap);
        end
    endtask

    // 把登记的第 f 帧按 7 满字 + 1 个 tkeep=F0 尾字推入 (总 60 内容字节, 无 pad)""",
    'gap_push')

# ---- per-experiment write record reset ----
sub("""            f2x_cn = 0;
            wq_base = wq_wr;""",
    """            f2x_cn = 0;
            injw_n = 0;
            f2_tr_on = 1'b0;
            wq_base = wq_wr;""", 'begin_reset')

# ---- counter deltas in f2x_show ----
sub("""    task f2x_show;
        input [255:0] tag;
        integer f, q;
        begin
            $display("  [F2X %0s] wire frames=%0d (window [%0d,%0d) inj=%0d)",
                     tag, f2x_wn, wq_base, wq_wr, f2x_cn);""",
    """    task f2x_show;
        input [255:0] tag;
        integer f, q;
        begin
            $display("  [F2X %0s] wire frames=%0d (window [%0d,%0d) inj=%0d)",
                     tag, f2x_wn, wq_base, wq_wr, f2x_cn);
            $display("  [F2X %0s] injw_n=%0d (dp-side writes) | d_abort=%0d d_flush_words=%0d d_flush_done=%0d d_frames=%0d d_tx_short=%0d | cdc_occ_w=%0d cdc_e=%b m_tx_tvalid=%b",
                     tag, injw_n,
                     u_dut.u_mac_tx.stat_abort - f2x_abort0,
                     u_dut.u_mac_tx.stat_flush_words - f2x_flw0,
                     u_dut.u_mac_tx.stat_flush_done - f2x_fld0,
                     u_dut.u_mac_tx.stat_frames,
                     u_dut.u_mac_tx.stat_tx_short,
                     u_dut.txcdc_occ_w, u_dut.tx_fifo_empty, u_dut.m_tx_tvalid);
            dump_injw;""", 'show_deltas')

# ---- X1 split into X1a (gap) / X1b (back-to-back), both traced ----
sub("""        // -------- X1: 单帧 (逐字节已知) --------
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = PAT[1..60]
        f2x_push_frame(0);
        f2x_settle;
        f2x_scan;
        f2x_show("X1");
        chk("X1 one frame on the wire", f2x_wn === 1, "derived: 1 injected tlast frame");
        chk("X1 frame is complete (60B content + FCS)",
            (f2x_wn == 1) && (f2x_wkind[0] === 2), "derived: content byte-exact + FCS len");
        chk("X1 no ghost", (f2x_wn <= 0) || (f2x_wkind[0] !== 0), "derived: classification");""",
    """        // -------- X1a: 单帧, 字间留间隔 (隔离 CDC 速率/可见性效应) --------
        $display("  ---- X1a: one frame, 6-cycle gap between words ----");
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = PAT[1..60]
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_push_frame_g(0, 6);
        f2x_settle;
        f2_tr_on = 1'b0;
        f2x_scan;
        f2x_show("X1a");
        chk("X1a one frame on the wire", f2x_wn === 1, "derived: 1 injected tlast frame");
        chk("X1a frame is complete (60B content + FCS)",
            (f2x_wn == 1) && (f2x_wkind[0] === 2), "derived: content byte-exact + FCS len");
        chk("X1a no ghost", (f2x_wn <= 0) || (f2x_wkind[0] !== 0), "derived: classification");

        // -------- X1b: 同一帧, 背靠背 (字间无间隔) --------
        $display("  ---- X1b: same frame, back-to-back (no gap) ----");
        f2x_begin;
        f2x_add60(1);
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_push_frame(0);
        f2x_settle;
        f2_tr_on = 1'b0;
        f2x_scan;
        f2x_show("X1b");
        chk("X1b one frame on the wire", f2x_wn === 1, "derived: 1 injected tlast frame");
        chk("X1b frame is complete (60B content + FCS)",
            (f2x_wn == 1) && (f2x_wkind[0] === 2), "derived: content byte-exact + FCS len");""",
    'x1_split')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
