#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""One-off evidence tool: build the "the registered gate really goes RED on the
buggy tree" control (the A-arm of the 2026-10-10 diag round, re-run through the
REGISTERED gate text).

Writes, under sim/aliasgate/_selftest/ (never touching board/ or sim/p5sim/):
  mutboard/wrapper_p4.v              -- the mutant copy (pre-fix direction)
  run_tb_p5_wrapper_negctl.bat       -- byte copy of sim/p5sim/run_tb_p5_wrapper.bat
                                        with EXACTLY ONE line changed:
                                        BD points at _selftest/mutboard
Placing it under sim/aliasgate/_selftest keeps the gate's own
'%~dp0..\\p4gates\\p4env.bat' resolution intact (sim/aliasgate/../p4gates).

usage: make_gate_negctl.py   (exit 0 = written, 2 = refused)
"""
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     '..', '..', '..'))
SELFTEST = os.path.join(ROOT, 'sim', 'aliasgate', '_selftest')
MUT = os.path.join(SELFTEST, 'wrapper_p4_mutant.v')
SRC_BAT = os.path.join(ROOT, 'sim', 'p5sim', 'run_tb_p5_wrapper.bat')
DST_BAT = os.path.join(SELFTEST, 'run_tb_p5_wrapper_negctl.bat')
MUTBOARD = os.path.join(SELFTEST, 'mutboard')


def main():
    if not os.path.isfile(MUT):
        print('REFUSE: mutant missing (%s) -- run run_aliasgate_selftest.bat' % MUT)
        return 2
    os.makedirs(MUTBOARD, exist_ok=True)
    with open(MUT, 'rb') as f:
        mut = f.read()
    with open(os.path.join(MUTBOARD, 'wrapper_p4.v'), 'wb') as f:
        f.write(mut)
    print('wrote mutboard/wrapper_p4.v (%d bytes)' % len(mut))

    with open(SRC_BAT, 'rb') as f:
        bat = f.read()
    # TWO lines change, both only because this copy sits one directory deeper
    # (sim\aliasgate\_selftest\ instead of sim\p5sim\): the p4env call needs one
    # more '..' and BD points at the mutant board dir.  Everything else is a
    # byte copy -- the FIRST attempt failed with "system cannot find the path"
    # because I had patched only BD (false red, caught by reading the output).
    # Only the WRAPPER comes from the mutant dir; the other two board sources
    # (util_gmii_to_rgmii.v / uart_dbg.v) stay where they are.  An earlier
    # attempt repointed the whole BD variable and died with
    # "[XSIM 43-4316] Can not find file: ...\mutboard\util_gmii_to_rgmii.v"
    # -- a tool-level red, not the gate's verdict (read the output, don't
    # trust the exit code alone).
    subs = [
        (b'%BD%\\wrapper_p4.v', b'%~dp0mutboard\\wrapper_p4.v'),
        (b'call "%~dp0..\\p4gates\\p4env.bat"',
         b'call "%~dp0..\\..\\p4gates\\p4env.bat"'),
    ]
    out = bat
    for old, new in subs:
        n = out.count(old)
        if n != 1:
            print('REFUSE: expected exactly 1 %r line, found %d' % (old, n))
            return 2
        out = out.replace(old, new)
    assert out != bat
    with open(DST_BAT, 'wb') as f:
        f.write(out)
    print('wrote %s (2 lines changed of %d)'
          % (os.path.relpath(DST_BAT, ROOT), bat.count(b'\n') + 1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
