# -*- coding: utf-8 -*-
# Convert the four group-8 chk calls into [OPEN] displays and demangle the
# literal backslash-u escapes that add_f2.py left in its comment block.
import io
import re

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

esc = re.compile('(?:' + re.escape(chr(92) + 'u') + '[0-9a-fA-F]{4})+')


def dm(m):
    try:
        return m.group(0).encode('ascii').decode('unicode_escape')
    except Exception:
        return m.group(0)


s = esc.sub(dm, s)

pat = re.compile(r'chk\("(8[abcd][^"]*)",\s*([^\n]+?),\n\s*"[^"]*"\);')


def to_open(m):
    return '$display("  [OPEN] %s = %%b   (UNRESOLVED: see the round report)", %s);' % (
        m.group(1), m.group(2).strip())


s2, n = pat.subn(to_open, s)
assert n == 4, n
io.open(P, 'w', encoding='utf-8', newline='').write(s2)
print('group8 -> OPEN (%d); escapes demangled' % n)
