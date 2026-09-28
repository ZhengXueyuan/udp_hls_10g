#!/usr/bin/env python
# patch_phase7.py -- rewrite phase 7 of tb/tb_p5e_udp_wrapper.v (alpha/beta order).
# ASCII-only source; the inserted Verilog text is kept in a separate file to avoid
# quoting problems (see phase7_block.v.txt).
import io, os, sys

here = os.path.dirname(os.path.abspath(__file__))
tb = os.path.normpath(os.path.join(here, '..', '..', 'tb', 'tb_p5e_udp_wrapper.v'))
blk = os.path.join(here, 'phase7_block.v.txt')

L = io.open(tb, 'r', encoding='utf-8', newline='').read().split('\n')
i0 = None
i1 = None
for i, l in enumerate(L):
    if 'RXP_DIAG v4: 三组字段' in l:      # 三组字段
        i0 = i
    if i0 is not None and l.strip() == '`endif' and i > i0:
        i1 = i
        break
assert i0 is not None and i1 is not None, (i0, i1)
NEW = io.open(blk, 'r', encoding='utf-8', newline='').read().rstrip('\n').split('\n')
out = L[:i0] + NEW + L[i1:]
io.open(tb, 'w', encoding='utf-8', newline='').write('\n'.join(out))
print('phase7 block replaced: old lines %d..%d (%d lines) -> new %d lines; total %d'
      % (i0 + 1, i1 + 1, i1 - i0, len(NEW), len(out)))
