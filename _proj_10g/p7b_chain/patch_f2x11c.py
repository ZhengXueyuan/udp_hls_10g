# -*- coding: utf-8 -*-
"""F2X11c: strengthen the pre-existing X4 "no B on the wire" criterion.

Measured weakness (negative control MUT-NOFLUSH, logs/f2x11_mut_noflush_FINAL.log:2801):
with the flush removed a COMPLETE B frame is on the wire (X4 frame 1, kind=2, content
64 65 66 67 ... = PAT[100..]) yet the criterion PASSED -- it only looked at frame 0
(the runt).  Fix: scan EVERY decoded wire frame for a B prefix (>= 8 bytes) and print
which frame offended.
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()
orig = s
old = '''        chk("X4 no B on the wire",
            ((f2x_wn >= 1) && ((f2x_wlen[0] - 7) < 60)) ||
            ((f2x_wn >= 1) && (f2x_wire[0][7] !== f2x_c[F2X_STRIDE + 0])),
            "derived: B's first content byte must not appear as a frame start");'''
new = '''        // F2X11c: 原判据只看 frame 0 ⇒ 实测在 MUT-NOFLUSH 下 **B 整帧在线** 却 PASS
        //   (logs/f2x11_mut_noflush_FINAL.log:2801 X4 frame1 kind=2 = PAT[100..])。
        //   改成扫**每一帧**: 任何帧都不得以 B 的 8 个内容字节开头。
        nob_n = -1;
        for (xa_f = 0; xa_f < f2x_wn && xa_f < 32; xa_f = xa_f + 1)
            if ((f2x_wlen[xa_f] >= 7 + 8) && (nob_n < 0) &&
                (f2x_wire[xa_f][7]  === f2x_c[F2X_STRIDE + 0]) &&
                (f2x_wire[xa_f][8]  === f2x_c[F2X_STRIDE + 1]) &&
                (f2x_wire[xa_f][9]  === f2x_c[F2X_STRIDE + 2]) &&
                (f2x_wire[xa_f][10] === f2x_c[F2X_STRIDE + 3]) &&
                (f2x_wire[xa_f][11] === f2x_c[F2X_STRIDE + 4]) &&
                (f2x_wire[xa_f][12] === f2x_c[F2X_STRIDE + 5]) &&
                (f2x_wire[xa_f][13] === f2x_c[F2X_STRIDE + 6]) &&
                (f2x_wire[xa_f][14] === f2x_c[F2X_STRIDE + 7])) nob_n = xa_f;
        $display("  [F2X X4] first wire frame with a B prefix: %0d (-1 = none) out of %0d frames",
                 nob_n, f2x_wn);
        chk("X4 no B on the wire", nob_n < 0,
            "F2X11c: every frame scanned");'''
if s.count(old) != 1:
    raise SystemExit('anchor x%d' % s.count(old))
s = s.replace(old, new)

old2 = '''    integer  i, j, k, m, n;'''
new2 = '''    integer  i, j, k, m, n, nob_n, xa_f;'''
if s.count(old2) != 1:
    raise SystemExit('anchor2 x%d' % s.count(old2))
s = s.replace(old2, new2)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('F2X11c applied: %d -> %d' % (len(orig), len(s)))
