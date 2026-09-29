# -*- coding: utf-8 -*-
"""FINAL corpus scan with the FROZEN key set (narrowed 10-3091).

Reports per-key file/event counts and, for every hit, the source file the tool
blamed, so each hit can be classified true / false positive.
"""
import os
import re

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP = ["\\demo", "\\.git", "\\xsim.dir", "\\.xil", "\\p7b_implicit_repro", "\\p7b_rollout", "\\work_"]
EXTS = (".log", ".txt", ".rpt")

KEYS = [
    ("Synth 8-11241", r"Synth 8-11241"),
    ("undeclared symbol", r"undeclared symbol"),
    ("VRFC 10-3091]NARROW", r"VRFC 10-3091\] actual bit length 1 differs from formal bit length"),
    ("VRFC 10-2989", r"VRFC 10-2989"),
    ("implicitly declared", r"implicitly declared"),
]

files = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if f.lower().endswith(EXTS):
            files.append(os.path.join(dp, f))
files.sort()

agg = {}
srcs = {}
nbytes = 0
for p in files:
    try:
        nbytes += os.path.getsize(p)
        txt = open(p, "r", errors="replace").read()
    except OSError:
        continue
    rel = p[len(ROOT) + 1:]
    for name, rx in KEYS:
        if not re.search(rx, txt, re.I):
            continue
        ev = 0
        for ln in txt.splitlines():
            if re.search(rx, ln, re.I):
                ev += 1
                m = re.search(r"\[([^\]]*\.v):?\d*\]\s*$", ln.strip())
                if m:
                    srcs.setdefault((name, m.group(1).replace("\\", "/")), 0)
                    srcs[(name, m.group(1).replace("\\", "/"))] += 1
        agg[(rel, name)] = ev

print("CORPUS: %d files, %d bytes" % (len(files), nbytes))
print()
bykey = {}
for (rel, name), ev in agg.items():
    bykey.setdefault(name, []).append((rel, ev))
for name, _ in KEYS:
    v = bykey.get(name, [])
    print("%-22s files=%-4d events=%d" % (name, len(v), sum(e for _, e in v)))
print()
print("=== every hit file ===")
cur = None
for name, _ in KEYS:
    for rel, ev in sorted(bykey.get(name, [])):
        print("  [%-22s] x%-5d %s" % (name, ev, rel))
print()
print("=== blamed source files (top 25 by events) ===")
for (name, s), c in sorted(srcs.items(), key=lambda kv: -kv[1])[:25]:
    print("  %-22s x%-5d %s" % (name, c, s))
