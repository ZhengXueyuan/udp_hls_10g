# -*- coding: utf-8 -*-
"""Doctor: 只打坏【一个】锚点字符串 (语义零改动), 其余字节逐字不动. 用法: doctor.py <src> <tx|cont> <out>"""
import io, sys
src, kind, out = sys.argv[1], sys.argv[2], sys.argv[3]
t = io.open(src, encoding="utf-8", newline="").read()
pairs = {
  # tx: mut_c6 的锚点 —— 只删掉注释里的一个 '§' (注释改动, RTL 语义零影响)
  "tx":   (u"\u56de\u5377\u95e8 (\u00a71.4(4))", u"\u56de\u5377\u95e8 (1.4(4))"),
  # cont: m4_term_open 的锚点 —— 加一对括号 (Verilog 语义逐位等价)
  "cont": (u"if ((remain == 32'd0) && !CONT_OK) begin", u"if ((remain == 32'd0) && (!CONT_OK)) begin"),
}
old, new = pairs[kind]
n = t.count(old)
assert n == 1, "doctor anchor hits=%d (expect 1)" % n
io.open(out, "w", encoding="utf-8", newline="").write(t.replace(old, new, 1))
print("DOCTOR %s: 1 substring replaced (%r -> %r)" % (out, old, new))
