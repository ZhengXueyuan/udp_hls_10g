# -*- coding: utf-8 -*-
"""Scan every .bat/.cmd in the repo for the pattern that made
run_tb_p4_replay.bat execute a bogus command:

    a REM/:: line that carries BOTH a '%' and a non-ASCII byte

cmd re-parses such a line as a live command (measured: 'CACK' was executed
before the simulation -- see logs/p4_replay_before.txt).  Read-only.
"""
import os
import re

SKIP_DIRS = {'.git', 'xsim.dir', 'vivado_prj', 'runs', 'work'}
hits = []
nbat = 0
for dirpath, dirnames, filenames in os.walk('.'):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if not fn.lower().endswith(('.bat', '.cmd')):
            continue
        p = os.path.join(dirpath, fn)
        nbat += 1
        try:
            b = open(p, 'rb').read()
        except OSError:
            continue
        sep = b'\r\n' if b'\r\n' in b else b'\n'
        for i, line in enumerate(b.split(sep), 1):
            if not re.match(rb'(?i)^\s*(rem\b|::)', line):
                continue
            if b'%' in line and any(c > 127 for c in line):
                hits.append((p.replace(os.sep, '/'), i,
                             line[:70].decode('utf-8', 'replace')))
print('bat/cmd files scanned: %d' % nbat)
print('REM lines with BOTH %% and non-ASCII: %d' % len(hits))
for p, i, s in hits[:30]:
    print('  %s:%d  %s' % (p, i, s))
