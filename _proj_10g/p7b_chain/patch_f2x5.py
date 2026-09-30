#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b: X5 -- TX->RX replay (out-of-scope extra, from the F-2 attribution work).

While digging into F-2 I measured the wire FCS of the chain gate's own short frame
(group 6: content 18B padded to 60) and compared it with the TB's bit-serial CRC:
    wire FCS = e9 07 cd 41  ==  crc32(18 content bytes)      <- pad EXCLUDED
    crc32(60 padded bytes)  = 0a bf 59 60                   <- 802.3 wants this
The 1G mac_tx_64 (P6b, board-verified) feds the pad into the CRC
(`crc_en = S_DATA || S_PAD`), mac_tx_10g does not (crc_en = S_DATA only, pad is
generated inside the merged tail word).  mac_rx_10g CRCs every received byte, pad
included => if that is real, the 10G TX and the 10G RX disagree and our own RX
must flag crc_err on our own short frames.

X5 replays a TX frame straight into the RX injector:
  X5a  content = 20B (pad 40B)  -> expect crc_err +1 for a pad-excluded-FCS TX
  X5b  content = 60B (no pad)   -> control: expect crc_err unchanged
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X5-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


sub("""    // F2X3-PATCH: 连续注入 (1 字/拍, = 真实 DP 侧合同)""",
    """    // F2X5-PATCH: 20 字节内容帧 (2 满字 + 1 个 tkeep=F0 尾字) —— 会被 MAC 补 pad 到 60
    task f2x_add20;
        input integer base;
        integer i;
        begin
            for (i = 0; i < 20; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[(base+i) % 256];
            f2x_clen[f2x_cn] = 20;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    task f2x_stream20;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 2; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF;
                force u_dut.txsrc_tlast = 1'b0;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            d = {f2x_c[f*F2X_STRIDE+16], f2x_c[f*F2X_STRIDE+17],
                 f2x_c[f*F2X_STRIDE+18], f2x_c[f*F2X_STRIDE+19], 32'd0};
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = 8'hF0;
            force u_dut.txsrc_tlast = 1'b1;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // 把捕获窗口 [from,to) 的线上字回放进 RX 注入队列 (TB 侧环回)
    task f2x_loop;
        input integer from;
        input integer to;
        integer li;
        begin
            for (li = from; li < to; li = li + 1) begin
                xq_d[xq_wr] = wq_d[li];
                xq_c[xq_wr] = wq_c[li];
                xq_wr = xq_wr + 1;
            end
            $display("  [F2X loop] replayed %0d wire words into the RX injector (xq_wr=%0d)",
                     to - from, xq_wr);
        end
    endtask

    // F2X3-PATCH: 连续注入 (1 字/拍, = 真实 DP 侧合同)""", 'x5_tasks')

sub("""        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;

        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);""",
    """        // -------- X5: TX → RX 环回 (短帧 FCS 覆盖面) --------
        $display("---- X5: TX->RX replay (short frame FCS scope) ----");
        begin : x5
            integer rf0, rc0;
            // X5b 控制组: 60B 内容 (无 pad)
            f2x_begin;
            f2x_add60(1);
            f2x_stream(0);
            f2x_settle;
            f2x_scan;
            rf0 = u_dut.rx_stat_frames; rc0 = u_dut.rx_stat_crc_err;
            f2x_loop(wf_start[0] - 4, wf_stop[0] + 5);
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5b] 60B frame: rx_frames %0d->%0d, rx_crc_err %0d->%0d",
                     rf0, u_dut.rx_stat_frames, rc0, u_dut.rx_stat_crc_err);
            chk("X5b loopback 60B frame delivered", (u_dut.rx_stat_frames > rf0),
                "derived: RX must deliver the replayed frame");
            chk("X5b loopback 60B frame FCS agrees (no new crc_err)",
                (u_dut.rx_stat_crc_err === rc0), "derived: TX FCS vs RX CRC over the same bytes");
            // X5a 待测组: 20B 内容 (MAC 补 40B pad)
            f2x_begin;
            f2x_add20(1);
            f2x_stream20(0);
            f2x_settle;
            f2x_scan;
            $display("  [F2X X5a] injected 20B-content frame: wire frames=%0d kind=%0d content_len_incl_pad=%0d",
                     f2x_wn, f2x_wkind[0], f2x_wlen[0] - 7 - 4);
            rf0 = u_dut.rx_stat_frames; rc0 = u_dut.rx_stat_crc_err;
            f2x_loop(wf_start[0] - 4, wf_stop[0] + 5);
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5a] 20B+pad frame: rx_frames %0d->%0d, rx_crc_err %0d->%0d",
                     rf0, u_dut.rx_stat_frames, rc0, u_dut.rx_stat_crc_err);
            chk("X5a loopback short frame delivered", (u_dut.rx_stat_frames > rf0),
                "derived: RX must deliver the replayed frame");
            chk("X5a loopback short frame FCS agrees (no new crc_err)",
                (u_dut.rx_stat_crc_err === rc0),
                "derived: 802.3 3.2.9 - FCS covers the PAD; mac_tx_64 does, mac_tx_10g (measured) does not");
        end

        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;

        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);""",
    'x5_section')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
