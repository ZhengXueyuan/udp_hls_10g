# -*- coding: utf-8 -*-
"""Update the P6e real-wrapper gate's TB for the P7b 51-word snapshot map.
Line-based (the file may use CRLF; a multi-line literal search would miss)."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/sim/p6e_pcie/tb_p6e_pcie_wrapper.v'
raw = io.open(P, 'r', encoding='utf-8', newline='').read()
nl = '\r\n' if '\r\n' in raw else '\n'
lines = raw.split(nl)

hit = 0
for i, l in enumerate(lines):
    if '\u26a0\ufe0f 32 \u5b57\u5feb\u7167\u628a 0x20-0x9C' in l:
        lines[i] = ('        // \u26a0\ufe0f **P7b (2026-09-29) \u5730\u56fe\u53c8\u957f\u4e86**: 51 \u5b57\u5feb\u7167\u5360 0x20..0xE8 (word 58)'
                    ' \u21d2 \u672a\u5b9e\u73b0\u5730\u5740 = word 59 = **0xEC**')
        hit += 1
    elif '\u968f\u5730\u56fe\u6269\u5f20\u632a\u8fc7: 0x18 -> 0x44' in l:
        lines[i] = '        //    (\u968f\u5730\u56fe\u6269\u5f20\u632a\u8fc7: 0x18 -> 0x44 -> 0x60 -> 0x84 -> 0xA0 -> 0xB0 -> 0xEC).'
        hit += 1
    elif "axil_read(32'hB0, v);" in l:
        lines[i] = l.replace("32'hB0", "32'hEC")
        hit += 1
    elif '\u672a\u5b9e\u73b0\u5730\u5740 0xB0 \u21d2 rresp = SLVERR' in l:
        lines[i] = l.replace('0xB0', '0xEC')
        hit += 1
assert hit == 4, hit
io.open(P, 'w', encoding='utf-8', newline='').write(nl.join(lines))
print('p6e wrapper TB patched, hit=%d' % hit)
