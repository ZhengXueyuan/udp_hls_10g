#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b chain-gate F-2 attribution, step 4: correct the injection rate.

Defect in my own step-2/3 injection (found by reading the [TR] trace):
  f2x_push() forced tvalid high for exactly one dp_clk period and low for the
  next => 1 word per 2 cycles (50% duty).  mac_tx_10g sends one content word per
  cycle, so the MAC drain outran the fill, the internal 16-deep FIFO went empty
  mid-frame and the F-2 abort fired => every frame came out as a 2-word runt.
  Evidence: X1b trace TR7..TR10 (pops word0, pops word1, femp=1, st=6 S_ABORT).

Fix:
  * f2x_stream()  : one new word per dp_clk cycle (all forces land on negedge, so
    every posedge samples a stable word) = the real DP-side contract.
  * the deliberate-starvation heads keep the 50% style (that is how the abort is
    provoked on purpose).
  * release the group-7 producer forces (stat_flush_words/done, stat_tx_words...)
    before F2X, so the counter checks read real registers.
  * trace window on X1a.
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X3-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# ---------------- continuous (1 word / cycle) frame injection ----------------
sub("""    // F2X2-PATCH: 带间隔的注入 (测 CDC 可见性/速率效应)""",
    """    // F2X3-PATCH: 连续注入 (1 字/拍, = 真实 DP 侧合同) —— 全部 force 落在 negedge,
    //   于是每个 posedge 采到的都是稳定字 => 恰好 1 写/拍, 无 50% 占空比气泡
    task f2x_stream;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                if (i < 7) begin
                    d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                         f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                         f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                         f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                    force u_dut.txsrc_tdata = d;
                    force u_dut.txsrc_tkeep = 8'hFF;
                    force u_dut.txsrc_tlast = 1'b0;
                end else begin
                    d = {f2x_c[f*F2X_STRIDE+56], f2x_c[f*F2X_STRIDE+57],
                         f2x_c[f*F2X_STRIDE+58], f2x_c[f*F2X_STRIDE+59], 32'd0};
                    force u_dut.txsrc_tdata = d;
                    force u_dut.txsrc_tkeep = 8'hF0;
                    force u_dut.txsrc_tlast = 1'b1;
                end
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // F2X2-PATCH: 带间隔的注入 (测 CDC 可见性/速率效应)""", 'stream_task')

# ---------------- use the stream for the complete frames -------------------
sub("""        // -------- X1a: 单帧, 字间留间隔 (隔离 CDC 速率/可见性效应) --------
        $display("  ---- X1a: one frame, 6-cycle gap between words ----");
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = PAT[1..60]
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_push_frame_g(0, 6);""",
    """        // 释放组 7 的**生产者 force** (stat_flush_words/done, stat_tx_words/ctrl,
        //   txcdc.ovf, u_pcs.blk_lock/hi_ber, tx_clk_act...) —— 否则 F2X 的计数器
        //   判据读的是常量 (实测: flw=2779054145=0xA5A50041 = 组 7 的 force 值)
        release u_dut.u_classify.dbg_stat_ovf;   release u_dut.u_classify.dbg_stat_route_ovf;
        release u_dut.u_classify.dbg_stat_stall_in; release u_dut.u_classify.dbg_occ;
        release u_dut.u_txcdc.ovf_cnt;  release u_dut.u_rxcdc.ovf_cnt;
        release u_dut.u_mac_tx.stat_flush_words; release u_dut.u_mac_tx.stat_flush_done;
        release u_dut.u_mac_tx.stat_tx_words;    release u_dut.u_mac_tx.stat_tx_ctrl_char;
        release u_dut.u_mac_rx.stat_rx_words;    release u_dut.u_mac_rx.stat_rx_pay_bytes;
        release u_dut.tx_clk_act;  release u_dut.u_pcs.blk_lock;  release u_dut.u_pcs.hi_ber;

        // -------- X1a: 单帧, 连续注入 (1 字/拍, = DP 侧合同) --------
        $display("  ---- X1a: one frame, continuous injection (1 word/cycle) ----");
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = PAT[1..60]
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_stream(0);""", 'x1a_stream')

sub("""        // -------- X1b: 同一帧, 背靠背 (字间无间隔) --------
        $display("  ---- X1b: same frame, back-to-back (no gap) ----");
        f2x_begin;
        f2x_add60(1);
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_push_frame(0);""",
    """        // -------- X1b: 同一帧, 但以 50% 占空比注入 (1 字 / 2 拍) --------
        //   => 故意制造"帧内气泡" (F-2 语义下 = 断供): 期望线上只剩残帧 + 冲刷
        $display("  ---- X1b: same frame at 50%% duty (1 word / 2 cycles = deliberate bubble) ----");
        f2x_begin;
        f2x_add60(1);
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_push_frame(0);""", 'x1b_50pct')

# X2: both frames continuous
sub("""        f2x_add60(100);                     // 帧 1 = PAT[100..159] (与帧 0 逐字节不同)
        f2x_push_frame(0);
        f2x_push_frame(1);""",
    """        f2x_add60(100);                     // 帧 1 = PAT[100..159] (与帧 0 逐字节不同)
        f2x_stream(0);
        f2x_stream(1);""", 'x2_stream')

# X3: B frame continuous (A's head stays 50% = deliberate starvation)
sub("""        f2x_push_tail(0, 2, 7);             // A 的残字 + 本帧 TLAST (必须被冲刷)
        f2x_push_frame(1);                  // B""",
    """        f2x_push_tail(0, 2, 7);             // A 的残字 + 本帧 TLAST (必须被冲刷)
        f2x_stream(1);                      // B (连续注入)""", 'x3_streamB')

# X4: B continuous
sub("""        f2x_push_head(0, 2);
        f2x_wait_abort;
        f2x_push_frame(1);                  // B: 这帧必须被冲刷吞掉""",
    """        f2x_push_head(0, 2);
        f2x_wait_abort;
        f2x_stream(1);                      // B (连续注入): 必须被冲刷吞掉""", 'x4_streamB')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
