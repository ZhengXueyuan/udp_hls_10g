#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""selftest_mutate.py -- build the 2026-10-10 wrapper TX-alias mutant.

Used ONLY by sim/aliasgate/run_aliasgate_selftest.bat.  Reads the FIXED
board/wrapper_p4.v and writes a copy with the five TX single-domain aliases
back in the pre-fix (reversed) direction, so the alias-direction gate can be
shown to have teeth without ever touching the repository copy.

It deliberately does NOT reconstruct the mutant from git HEAD: a mutant taken
from "before" history would silently become a no-op the moment this fix is
committed (mutant == working tree), and the gate would keep a negative control
that tests nothing.

usage: selftest_mutate.py IN OUT
exit 0 = mutant written (exactly 5 swaps applied)
exit 2 = refused (IN does not carry the 5 fixed aliases -- a no-op mutant is
         worse than no mutant)
"""

import os
import re
import sys

PAIRS = [
    ('m_tx_tdata', 'txsrc_tdata'),
    ('m_tx_tkeep', 'txsrc_tkeep'),
    ('m_tx_tlast', 'txsrc_tlast'),
    ('m_tx_tvalid', 'txsrc_tvalid'),
    ('txsrc_tready', 'm_tx_tready'),
]


def main(argv):
    if len(argv) != 2:
        print('usage: selftest_mutate.py IN OUT')
        return 2
    src, dst = argv
    with open(src, 'rb') as f:
        raw = f.read()
    crlf = raw.count(b'\r\n')
    txt = raw.decode('utf-8', 'replace')
    txt = txt.replace('\r\n', '\n').replace('\r', '\n')
    n = 0
    for x, y in PAIRS:
        pat = re.compile(r'(?m)^([ \t]*)assign[ \t]+%s[ \t]*=[ \t]*%s;'
                         % (re.escape(x), re.escape(y)))
        txt, k = pat.subn(
            lambda m: '%sassign %s = %s;' % (m.group(1), y, x), txt)
        if k != 1:
            print('REFUSE: expected exactly 1 fixed alias "assign %s = %s;" '
                  'in %s, found %d' % (x, y, os.path.basename(src), k))
            return 2
        n += k
    if n != 5:
        print('REFUSE: applied %d swaps, expected 5' % n)
        return 2
    out = txt.replace('\n', '\r\n') if crlf else txt
    with open(dst, 'wb') as f:
        f.write(out.encode('utf-8'))
    print('MUTANT written: %s (%d swaps restored the pre-fix direction)'
          % (os.path.basename(dst), n))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
