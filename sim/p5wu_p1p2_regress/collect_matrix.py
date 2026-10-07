#!/usr/bin/env python
"""collect_matrix.py -- two-column reader for the 16-gate P4 matrix run.

Column A = the matrix log (runner stdout, per-gate EXIT= + gatebrief tail)
Column B = each gate's own work-dir logs (_gate_console.log + the xsim/xelab
           logs the gate .bat itself never greps -- the "only greps the main
           stdout" hole).

usage: python collect_matrix.py <workroot> <matrixlog>
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

work = sys.argv[1]
mlog = sys.argv[2]

txt = io.open(mlog, "r", encoding="utf-8", errors="replace").read()
blocks = re.findall(r"=== GATE (\S+) : (.*?)\n(.*?)(?=\n=== GATE |\n--- revision fingerprint \(after\))",
                    txt, re.S)
print("gates parsed = %d" % len(blocks))
print()
for name, hdr, body in blocks:
    rc = re.search(r"^EXIT=(\d+)", body, re.M)
    rc = rc.group(1) if rc else "?"
    print("=" * 78)
    print("GATE %-14s EXIT=%s   cmd: %s" % (name, rc, hdr.strip()))
    for line in body.splitlines():
        if line.startswith(("GATE ", "PRECHECK-FAIL", "--- last", "| ")):
            print("   A| %s" % line[:170])
    gd = os.path.join(work, name)
    cons = os.path.join(gd, "_gate_console.log")
    if os.path.isfile(cons):
        lines = io.open(cons, "r", encoding="utf-8", errors="replace").read().splitlines()
        print("   B| _gate_console.log = %d lines; tail:" % len(lines))
        for l in lines[-8:]:
            print("   B|   %s" % l[:170])
    for f in sorted(os.listdir(gd)) if os.path.isdir(gd) else []:
        if re.match(r"(x?sim|verify|run|auto).*\.log$", f) and f != "_gate_console.log":
            p = os.path.join(gd, f)
            try:
                lines = io.open(p, "r", encoding="utf-8", errors="replace").read().splitlines()
            except Exception as e:
                print("   B| %s: unreadable (%s)" % (f, e))
                continue
            hits = [l for l in lines if re.search(r"FAIL|ERROR|Error|error|OK|PASS", l)]
            print("   B| %-28s %5d lines, %3d verdict-ish:" % (f, len(lines), len(hits)))
            for l in hits[-6:]:
                print("   B|        %s" % l[:165])
