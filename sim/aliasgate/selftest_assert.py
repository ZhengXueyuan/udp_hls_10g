#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""selftest_assert.py -- assertions for run_aliasgate_selftest.bat.

usage: selftest_assert.py NEG_STDOUT NEG_RC POS_STDOUT POS_RC
exit 0 = every control behaved as expected, 1 = at least one did not.

Deliberately python (not findstr gymnastics): cmd's `find` is shadowed by
MSYS's Unix find.exe when a .bat is invoked from this box's Git Bash
(C:\\Program Files\\Git\\usr\\bin\\find.exe comes first in PATH; measured
2026-10-10) -- `/c` is then read as a path and the drive is traversed
recursively, which HANGS the calling script.
"""

import re
import sys


def read(p):
    with open(p, 'r', encoding='utf-8', errors='replace') as f:
        return f.read().splitlines()


def reversed_rows(lines):
    return [l for l in lines if l.startswith('   REVERSED ')]


def summary(lines, cfg):
    for l in lines:
        if l.startswith('   SUMMARY ') and (' ' + cfg + ' ') in l:
            m = re.search(r'rev=(\d+) multi=(\d+) unresolved=(\d+)', l)
            if m:
                return tuple(int(x) for x in m.groups())
    return None


def rev_of(lines, cfg):
    s = summary(lines, cfg)
    return s[0] if s else None


def main(argv):
    if len(argv) != 4:
        print('usage: selftest_assert.py NEG_STDOUT NEG_RC POS_STDOUT POS_RC')
        return 2
    neg, pos = read(argv[0]), read(argv[2])
    nrc, prc = int(argv[1]), int(argv[3])
    negrows, posrows = reversed_rows(neg), reversed_rows(pos)
    named = set(re.findall(r'wrapper_p4_mutant\.v:(\d+)', '\n'.join(negrows)))

    checks = [
        ('NEG exit code == 1', nrc == 1, 'got %d' % nrc),
        ('NEG has exactly 5 REVERSED rows', len(negrows) == 5,
         'got %d' % len(negrows)),
        ('NEG rows name 5 distinct line numbers', len(named) == 5,
         'got %d' % len(named)),
        ('NEG rows name the 5 nets',
         all(any(n in l for l in negrows) for n in
             ('m_tx_tdata', 'm_tx_tkeep', 'm_tx_tlast', 'm_tx_tvalid',
              'txsrc_tready')), ''),
        ('NEG config A rev=5 multi=0', summary(neg, 'A_appmode_only') == (5, 0, 0),
         str(summary(neg, 'A_appmode_only'))),
        ('NEG config G rev=0 (DP branch untouched)',
         rev_of(neg, 'G_appmode_dp156') == 0, str(summary(neg, 'G_appmode_dp156'))),
        ('NEG parser selfcheck 18/18',
         any('parser selfcheck: 18/18' in l for l in neg), ''),
        ('POS exit code == 0', prc == 0, 'got %d' % prc),
        ('POS config A rev=0', rev_of(pos, 'A_appmode_only') == 0,
         str(summary(pos, 'A_appmode_only'))),
        ('POS config G rev=0', rev_of(pos, 'G_appmode_dp156') == 0,
         str(summary(pos, 'G_appmode_dp156'))),
        ('POS has no REVERSED rows', len(posrows) == 0,
         'got %d' % len(posrows)),
    ]
    bad = 0
    for name, ok, extra in checks:
        print('[%s] %s%s' % ('OK ' if ok else 'BAD', name,
                             ('   (' + extra + ')') if (extra and not ok) else ''))
        if not ok:
            bad += 1
    print('CONTROLS: %d/%d as expected' % (len(checks) - bad, len(checks)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
