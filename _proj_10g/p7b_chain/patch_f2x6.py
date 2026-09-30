#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b X5 calibration: same content, TB-computed FCS vs DUT-TX FCS, both replayed.

Measured in X5a/X5b (logs/f2x5_pristine.txt):
  60B frame  loopback -> rx_frames +1, rx_crc_err +1   (control FAILED too)
  20B+pad    loopback -> rx_frames +1, rx_crc_err +1
The 60B control failing means my replay path is NOT calibrated (the TX FCS of a
no-pad frame must agree with the RX CRC).  => X5a/X5b are downgraded to pure
diagnostics; the decisive criterion moves to X5c:

  X5c  same content (68B, no pad, no pktgen FCS involvement):
       (a) DUT TX frame captured off the wire, replayed into RX
       (b) TB build_frame(n=68) frame (TB's own bit-serial crc32 FCS), replayed
       If (b) passes and (a) fails for identical content -> the DUT TX FCS is
       wrong.  If both fail -> my replay path is broken, X5 is inconclusive.
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X6-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# ---- generic 68-byte content injection (PAT[0..67] = build_frame's content) ----
sub("""    // F2X5-PATCH: 20 字节内容帧""",
    """    // F2X6-PATCH: 68 字节内容帧 (PAT[0..67] = TB build_frame(68) 的同一内容, 无 pad)
    task f2x_add68;
        integer i;
        begin
            for (i = 0; i < 68; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[i];
            f2x_clen[f2x_cn] = 68;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    task f2x_stream68;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 8; i = i + 1) begin
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
            d = {f2x_c[f*F2X_STRIDE+64], f2x_c[f*F2X_STRIDE+65],
                 f2x_c[f*F2X_STRIDE+66], f2x_c[f*F2X_STRIDE+67], 32'd0};
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = 8'hF0;
            force u_dut.txsrc_tlast = 1'b1;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // F2X5-PATCH: 20 字节内容帧""", 'x6_tasks')

# ---- X5a/X5b: chk -> diagnostic ----
sub("""            chk("X5b loopback 60B frame delivered", (u_dut.rx_stat_frames > rf0),
                "derived: RX must deliver the replayed frame");
            chk("X5b loopback 60B frame FCS agrees (no new crc_err)",
                (u_dut.rx_stat_crc_err === rc0), "derived: TX FCS vs RX CRC over the same bytes");""",
    """            $display("  [F2X X5b] DIAG only (not a criterion): replayed frame delivered=%b crc_err_delta=%0d",
                     (u_dut.rx_stat_frames > rf0), (u_dut.rx_stat_crc_err - rc0));""", 'x5b_diag')

sub("""            chk("X5a loopback short frame delivered", (u_dut.rx_stat_frames > rf0),
                "derived: RX must deliver the replayed frame");
            chk("X5a loopback short frame FCS agrees (no new crc_err)",
                (u_dut.rx_stat_crc_err === rc0),
                "derived: 802.3 3.2.9 - FCS covers the PAD; mac_tx_64 does, mac_tx_10g (measured) does not");""",
    """            $display("  [F2X X5a] DIAG only (not a criterion): replayed frame delivered=%b crc_err_delta=%0d",
                     (u_dut.rx_stat_frames > rf0), (u_dut.rx_stat_crc_err - rc0));

            // -------- X5c: 校准 —— 同一内容 (68B, 无 pad) 两条路径 --------
            begin : x5c
                integer rf2, rc2, rf3, rc3;
                // (a) DUT TX 帧 (DUT 自算 FCS)
                f2x_begin;
                f2x_add68;
                f2x_stream68(0);
                f2x_settle;
                f2x_scan;
                $display("  [F2X X5c] DUT TX 68B frame: wire frames=%0d kind=%0d content_len=%0d",
                         f2x_wn, f2x_wkind[0], f2x_wlen[0] - 7 - 4);
                rf2 = u_dut.rx_stat_frames; rc2 = u_dut.rx_stat_crc_err;
                f2x_loop(wf_start[0] - 4, wf_stop[0] + 5);
                repeat (400) @(posedge u_dut.rx_clk_out_1);
                $display("  [F2X X5c-a] DUT-TX frame replayed: rx_frames %0d->%0d crc_err %0d->%0d",
                         rf2, u_dut.rx_stat_frames, rc2, u_dut.rx_stat_crc_err);
                // (b) TB 自算 FCS 的同一内容帧 (build_frame 自己把帧推入 xq)
                rf3 = u_dut.rx_stat_frames; rc3 = u_dut.rx_stat_crc_err;
                build_frame(68, 1'b0, -1);
                repeat (400) @(posedge u_dut.rx_clk_out_1);
                $display("  [F2X X5c-b] TB-FCS frame replayed : rx_frames %0d->%0d crc_err %0d->%0d",
                         rf3, u_dut.rx_stat_frames, rc3, u_dut.rx_stat_crc_err);
                chk("X5c calibration: TB-FCS frame passes our own RX",
                    (u_dut.rx_stat_crc_err === rc3) && (u_dut.rx_stat_frames > rf3),
                    "calibration: replay path is faithful (no crc_err for a TB-computed FCS)");
                chk("X5c same content, DUT-TX frame passes our own RX",
                    (u_dut.rx_stat_crc_err === rc2) && (u_dut.rx_stat_frames > rf2),
                    "derived: TX FCS must equal TB FCS for the same 68B content");
            end""", 'x5c')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
