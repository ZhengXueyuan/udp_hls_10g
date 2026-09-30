# -*- coding: utf-8 -*-
"""Move 6b AFTER the /S/ scan: it uses wq_sw, which the scan sets.  Placed
before the scan (first attempt) wq_sw is still 0 -> reads the IDLE word's control
byte 8'hFF -> a FALSE FAIL of my own making."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = ('        chk("6b TX /S/ at lane0", (wq_c[wq_sw] === 8\'h01) === 1\'b1,\n'
       '            "vendor :995/:1147 + GATE1 C.4");\n')
assert s.count(old) == 1, s.count(old)
s = s.replace(old, '')

anchor = '            chk("6c TX preamble word", (w0d[63:8] === 56\'hD5555555555555) === 1\'b1,'
assert s.count(anchor) == 1, s.count(anchor)
ins = ('            chk("6b TX /S/ at lane0", (wq_c[wq_sw] === 8\'h01) === 1\'b1,\n'
       '                "vendor :995/:1147 + GATE1 C.4");\n')
s = s.replace(anchor, ins + anchor)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('6b moved after the scan')
