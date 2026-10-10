#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""One-off evidence tool: build the entry-level negative control.

Copies _proj_10g/tcl/run_lint_p7a.bat byte-for-byte and changes EXACTLY ONE
line: the aliasgate call is retargeted at the mutant copy produced by
sim/aliasgate/run_aliasgate_selftest.bat.  Running the copy must therefore
exit 1 from the alias face (proving the face runs BEFORE the entry's own 97
preconditions and that a red face turns the entry red).  The repository entry
is never modified.
"""
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     '..', '..', '..'))
SRC = os.path.join(ROOT, '_proj_10g', 'tcl', 'run_lint_p7a.bat')
DST = os.path.join(ROOT, '_proj_10g', 'notes', 'p7b_aliasgate_20261010',
                   'entry_negctl_run_lint_p7a.bat')
GATE = os.path.join(ROOT, 'sim', 'aliasgate', 'run_aliasgate.bat')
MUT = os.path.join(ROOT, 'sim', 'aliasgate', '_selftest',
                   'wrapper_p4_mutant.v')

OLD = b'call "%~dp0..\\..\\sim\\aliasgate\\run_aliasgate.bat" || exit /b 1'
NEW = ('call "%s" "%s" || exit /b 1' % (GATE, MUT)).encode('ascii')


def main():
    if not os.path.isfile(MUT):
        print('REFUSE: mutant not found (%s) -- run run_aliasgate_selftest.bat '
              'first' % MUT)
        return 2
    with open(SRC, 'rb') as f:
        raw = f.read()
    n = raw.count(OLD)
    if n != 1:
        print('REFUSE: expected exactly 1 alias-gate call line in %s, found %d'
              % (SRC, n))
        return 2
    out = raw.replace(OLD, NEW)
    with open(DST, 'wb') as f:
        f.write(out)
    print('wrote %s' % os.path.relpath(DST, ROOT))
    print('changed lines: 1 of %d' % (raw.count(b'\n') + 1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
