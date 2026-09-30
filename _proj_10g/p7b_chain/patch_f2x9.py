#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b X5 final: fix the replay indices + calibrated pad/FCS A/B.

Bug in my own X5 (step 5/6): f2x_loop() used wf_start[]/wf_stop[] which f2x_scan
never fills (they belong to the older decode_wire).  So every X5 replay actually
replayed the *group-6* frame (words 7..16, i.e. the stale window again) -- which
is why the "60B control" also showed crc_err: that frame really does carry a
non-standard FCS (content 18B padded to 60, FCS = crc(18B), measured).

Fix: f2x_scan records its own start/stop word indices (f2x_wstart/f2x_wstop) and
f2x_loop uses those.  Then X5d builds the two candidate frames with the TB's own
bit-serial CRC over the SAME 60 wire content bytes:
  X5d-1  FCS over the padded 60 bytes   (standard / mac_tx_64 behaviour)
  X5d-2  FCS over the 18 data bytes     (mac_tx_10g behaviour, measured)
If (1) passes our own RX and (2) is flagged crc_err, then the RX expects the pad
inside the FCS and the 10G TX does not feed it -- a TX-side FCS scope defect that
is independent of any external standard citation (our own RX is the reference).
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X9-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# ---- 1. record f2x_scan's own frame word span ----
sub("""    integer    f2x_cls_n = 0;""",
    """    integer    f2x_cls_n = 0;
    integer    f2x_wstart [0:31];
    integer    f2x_wstop  [0:31];""", 'x9_decl')

sub("""                        if (wq_c[q][l2] === 1'b1 && byt === 8'hFB && l2 == 0) begin
                            if (f2x_wn < 32) begin in_f = 1'b1; st = 0; end
                        end""",
    """                        if (wq_c[q][l2] === 1'b1 && byt === 8'hFB && l2 == 0) begin
                            if (f2x_wn < 32) begin
                                in_f = 1'b1; st = 0; f2x_wstart[f2x_wn] = q;
                            end
                        end""", 'x9_start')

sub("""                        if (byt === 8'hFD) begin
                            if (f2x_wn < 32) begin
                                f2x_wlen[f2x_wn] = (st < 256) ? st : 256;
                                f2x_wn = f2x_wn + 1;
                            end
                            in_f = 1'b0;
                        end""",
    """                        if (byt === 8'hFD) begin
                            if (f2x_wn < 32) begin
                                f2x_wlen[f2x_wn] = (st < 256) ? st : 256;
                                f2x_wstop[f2x_wn] = q;
                                f2x_wn = f2x_wn + 1;
                            end
                            in_f = 1'b0;
                        end""", 'x9_stop')

# ---- 2. all X5 replays use f2x_wstart/f2x_wstop ----
s = s.replace('f2x_loop(wf_start[0] - 4, wf_stop[0] + 5);',
              'f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);')
print('replay anchors updated:', s.count('f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);'))

# ---- 3. X5d builder (TB-computed FCS over 60 wire content bytes, two scopes) ----
sub("""    // F2X6-PATCH: 68 字节内容帧""",
    """    // F2X9-PATCH: 60 字节线上内容 (18 数据 + 42 pad) 的帧, FCS 两种覆盖面
    task f2x_build_pad;
        input        dut_fcs;      // 1 = FCS 只覆盖 18 个数据字节 (mac_tx_10g 实测)
        integer i, m;
        reg [31:0] fc;
        begin
            fc = 32'hFFFFFFFF;
            if (dut_fcs) begin
                for (i = 0; i < 18; i = i + 1) fc = crc32_byte(fc, PAT[i]);
            end else begin
                for (i = 0; i < 60; i = i + 1)
                    fc = crc32_byte(fc, (i < 18) ? PAT[i] : 8'h00);
            end
            fc = ~fc;
            wb[0] = 8'hFB; wc[0] = 1;
            for (i = 0; i < 6; i = i + 1) begin wb[1+i] = 8'h55; wc[1+i] = 0; end
            wb[7] = 8'hD5; wc[7] = 0;
            m = 8;
            for (i = 0; i < 60; i = i + 1) begin
                wb[m] = (i < 18) ? PAT[i] : 8'h00; wc[m] = 0; m = m + 1;
            end
            wb[m] = fc[7:0];   wc[m] = 0; m = m + 1;
            wb[m] = fc[15:8];  wc[m] = 0; m = m + 1;
            wb[m] = fc[23:16]; wc[m] = 0; m = m + 1;
            wb[m] = fc[31:24]; wc[m] = 0; m = m + 1;
            wb[m] = 8'hFD; wc[m] = 1; m = m + 1;
            xq_pack_words(m);
            $display("  [F2X X5d] built frame: 18 data + 42 pad, FCS=%s (%02h %02h %02h %02h)",
                     dut_fcs ? "over 18 data bytes (DUT style)" : "over 60 padded bytes (standard)",
                     fc[7:0], fc[15:8], fc[23:16], fc[31:24]);
        end
    endtask

    // F2X6-PATCH: 68 字节内容帧""", 'x9_build')

# ---- 4. X5d section (after X5c) ----
sub("""            chk("X5c same content, DUT-TX frame passes our own RX",
                    (u_dut.rx_stat_crc_err === rc2) && (u_dut.rx_stat_frames > rf2),
                    "derived: TX FCS must equal TB FCS for the same 68B content");
            end""",
    """            chk("X5c same content, DUT-TX frame passes our own RX",
                    (u_dut.rx_stat_crc_err === rc2) && (u_dut.rx_stat_frames > rf2),
                    "derived: TX FCS must equal TB FCS for the same 68B content");

            // -------- X5d: 同一 60B 线上内容, 两种 FCS 覆盖面 (校准过的 A/B) --------
            f2x_build_pad(1'b0);                 // 标准: FCS 覆盖 pad
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5d-1] TB frame, FCS over 60 padded bytes: rx_frames=%0d crc_err=%0d",
                     u_dut.rx_stat_frames, u_dut.rx_stat_crc_err);
            chk("X5d-1 TB frame with pad-covered FCS passes our own RX",
                (u_dut.rx_stat_crc_err === rc3), "calibration: RX accepts the standard scope");
            f2x_build_pad(1'b1);                 // DUT 风格: FCS 只覆盖 18 数据字节
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5d-2] TB frame, FCS over 18 data bytes : rx_frames=%0d crc_err=%0d",
                     u_dut.rx_stat_frames, u_dut.rx_stat_crc_err);
            chk("X5d-2 TB frame with data-only FCS is flagged crc_err (discrimination)",
                (u_dut.rx_stat_crc_err === (rc3 + 32'd1)),
                "derived: the only difference is the FCS scope => RX wants the pad inside");
            end""", 'x9_section')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
