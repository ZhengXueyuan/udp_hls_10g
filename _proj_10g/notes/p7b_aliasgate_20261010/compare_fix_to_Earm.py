#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Evidence tool: is the landed fix token-identical to the E-arm copy that the
2026-10-10 diag round already proved green in xsim (three gates)?

Extracts the TX alias block (`ifdef DP_156MHZ ... `endif), keeps the assign
lines, normalises whitespace, and compares the three versions.

Only whitespace and the added comment may differ -- if the assign *directions*
differ, the xsim evidence from the E/F/H arms does not transfer to the landed
fix and this tool says so loudly.
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     '..', '..', '..'))
FILES = [
    ('live fixed', os.path.join(ROOT, 'board', 'wrapper_p4.v')),
    ('diag E-arm', os.path.join(ROOT, '_proj_10g', 'notes',
                                'p7b_p5wrapper_diag_20261010', 'work', 'E',
                                'wrapper_p4.v')),
    ('selftest mutant', os.path.join(ROOT, 'sim', 'aliasgate', '_selftest',
                                     'wrapper_p4_mutant.v')),
]


def block_assigns(path):
    """The TX single-domain alias block = the `ifdef DP_156MHZ whose ELSE
    branch carries `txsrc_tdata` (the file has several DP_156MHZ blocks)."""
    with open(path, 'rb') as f:
        t = f.read().decode('utf-8', 'replace').replace('\r\n', '\n')
    pos = 0
    while True:
        i = t.find('ifdef DP_156MHZ', pos)
        if i < 0:
            raise SystemExit('no TX alias ifdef DP_156MHZ block in %s' % path)
        j = t.find('\x60else', i)      # grave accent, written as \x60
        k = t.find('\x60endif', j) if j >= 0 else -1
        if j < 0 or k < 0:
            raise SystemExit('unterminated block in %s' % path)
        seg = t[j:k]
        if 'txsrc_tdata' in seg:
            out = []
            for line in seg.split('\n'):
                s = line.strip()
                if s.startswith('assign'):
                    out.append(re.sub(r'\s+', ' ', s.split('//')[0].strip()))
            return out
        pos = k


def main():
    got = {}
    for name, p in FILES:
        if not os.path.isfile(p):
            print('MISSING %s (%s) -- control incomplete' % (name, p))
            return 2
        got[name] = block_assigns(p)
        print('== %s (%s)' % (name, os.path.relpath(p, ROOT)))
        for x in got[name]:
            print('   %s' % x)
    a = got['live fixed']
    b = got['diag E-arm']
    m = got['selftest mutant']
    print()
    print('assign lines: live=%d E-arm=%d mutant=%d' % (len(a), len(b), len(m)))
    def aliases(xs):
        return [x for x in xs if re.match(r'assign (m_tx_t|txsrc_t)', x)]

    la, lb, lm = aliases(a), aliases(b), aliases(m)
    rev = sorted(re.sub(r'^assign (\S+) = (\S+);$', r'assign \2 = \1;', x)
                 for x in la)
    print('alias lines only: live=%d E-arm=%d mutant=%d' % (len(la), len(lb), len(lm)))
    print('live == E-arm (token-normalised): %s' % (la == lb))
    print('mutant == reversed(live):         %s' % (sorted(lm) == rev))
    if len(la) == 5 and la == lb and sorted(lm) == rev:
        print('FIX-EQUIVALENCE OK: the landed 5 lines are token-identical to '
              'the copy that the diag E/F/H arms already ran green in xsim, '
              'and the selftest mutant is exactly their reversal')
        return 0
    print('FIX-EQUIVALENCE FAIL: not token-identical -- the E/F/H xsim '
          'evidence does NOT transfer')
    return 1


if __name__ == '__main__':
    sys.exit(main())
