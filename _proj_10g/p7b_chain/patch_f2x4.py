#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b chain-gate F-2 attribution, step 5: X1b expectation + mutation scaffold.

X1b injects a complete frame at 50% duty on purpose (= a mid-frame bubble, which
the F-2 contract calls "断供" => abort).  Its correct expectation is therefore NOT
"complete frame" but "runt(prefix) + flush counters advanced + no ghost".
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X4-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


sub("""        chk("X1b one frame on the wire", f2x_wn === 1, "derived: 1 injected tlast frame");
        chk("X1b frame is complete (60B content + FCS)",
            (f2x_wn == 1) && (f2x_wkind[0] === 2), "derived: content byte-exact + FCS len");""",
    """        // F2X4-PATCH: 50% 占空比 = 故意帧内气泡 => 期望"残帧 + 冲刷" (F-2 语义), 不是完整帧
        chk("X1b bubble -> exactly 1 wire frame", f2x_wn === 1,
            "contract: mid-frame starvation aborts the frame (F-2)");
        chk("X1b that frame is a runt (prefix of the injected frame)",
            (f2x_wn == 1) && (f2x_wkind[0] === 1), "derived: prefix compare");
        chk("X1b flush counters advanced (rest of the frame flushed)",
            (u_dut.u_mac_tx.stat_flush_done === (f2x_fld0 + 32'd1)) &&
            (u_dut.u_mac_tx.stat_flush_words > f2x_flw0),
            "design bookkeeping (NOT the primary criterion)");
        chk("X1b no ghost", (f2x_wn >= 1) && (f2x_wkind[0] !== 0), "derived: classification");""",
    'x1b_expect')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
