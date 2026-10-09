#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""p7b_gate4_negctrl.sh 的合成夹具 63 -> 66 字 / BID 0x0A -> 0x18 同步 (5 处, 逐处断言)."""
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
p = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\p7b_gate4_negctrl.sh"
s = io.open(p, encoding="utf-8", newline="").read()
NL = "\n"
E = [
 u"# 几何: **63 字 (W0..W62)** \u2014\u2014 P7B-WU \u4e8c\u8f6e (2026-10-07, BID=9 / \u672a\u5b9e\u73b0 0x11C);",
 u"# \u51e0\u4f55: **66 \u5b57 (W0..W65)** \u2014\u2014 P7B-A7 \u6784\u5efa D (2026-10-10, BID=0x18 / \u672a\u5b9e\u73b0 0x128);\n"
 u"#       (\u539f\u53e5: \u201863 \u5b57 (W0..W62)\u2019 = \u5386\u53f2\u4ee3, \u9010\u5b57\u4fdd\u7559\u4e8e\u4e0b)",
]
assert s.count(E[0]) == 1
s = s.replace(E[0], E[1])

a = u"#       \u26a0\ufe0f W51..W62 = P7B-BIZ/WU \u65b0\u589e\u5b57, \u672c\u5939\u5177\u5168\u586b 0"
assert s.count(a) == 1, s.count(a)
s = s.replace(a, u"#       \u26a0\ufe0f W51..W65 = P7B-BIZ/WU/\u6784\u5efaC/\u6784\u5efaD \u65b0\u589e\u5b57, \u672c\u5939\u5177\u5168\u586b 0")

b = u'echo "MAGIC 0x50360001"; echo "BID 0x0000000A"; echo "MARKER 0xdeadbeef"'
assert s.count(b) == 1
s = s.replace(b, u'echo "MAGIC 0x50360001"; echo "BID 0x00000018"; echo "MARKER 0xdeadbeef"   # \u6784\u5efa D: \u539f 0x0000000A = Stage C')

c = u"                0 0 0 0 0 0 0 0 0 0 0 0)"
assert s.count(c) == 1, s.count(c)
s = s.replace(c, u"                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)   # W51..W65 (\u6784\u5efa D: W65 = mac_tx_10g.stat_tx_idle)")

d = u"for (( i = 0; i < 63; i++ ))"
assert s.count(d) == 1
s = s.replace(d, u"for (( i = 0; i < 66; i++ ))")

e = u"shift1(){ awk -v NW=63 "
assert s.count(e) == 1
s = s.replace(e, u"shift1(){ awk -v NW=66 ")

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("negctrl fixture -> 66 words / BID 0x18 (5 edits OK)")
