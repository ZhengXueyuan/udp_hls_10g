"""Narrow the implicit-net key VRFC 10-3091 -> the 坑-24 signature only.

Corpus measurement (see logs/corpus_scan2.txt + logs/classify_3091.txt):
  broad  "VRFC 10-3091" -> false positives: 32-vs-1 benign unsized literals
        (.CE(1)/R(0)/.S(0)) on the TRACKED file board/util_gmii_to_rgmii.v x13
  narrow "VRFC 10-3091] actual bit length 1 differs from formal bit length"
        -> an implicit net is definitionally 1 bit, so this is the exact
           trap-24 signature; no benign literal-to-1-bit-port case can match
           (equal widths print nothing).

Byte-level edit so line endings / encoding are preserved exactly.
"""
import os
import sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP = ["\\demo", "\\.git", "\\xsim.dir", "\\.xil", "\\p7b_implicit_repro",
        "\\p7b_rollout", "\\work_"]
OLD = b'/C:"VRFC 10-3091"'
NEW = b'/C:"VRFC 10-3091] actual bit length 1 differs from formal bit length"'

apply = "--apply" in sys.argv
targets = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if f.lower().endswith((".bat", ".py", ".tcl")):
            targets.append(os.path.join(dp, f))
targets.sort()

log = []
nfiles = 0
nlines = 0
for p in targets:
    b = open(p, "rb").read()
    if OLD not in b:
        continue
    cnt = b.count(OLD)
    nfiles += 1
    nlines += cnt
    rel = p[len(ROOT) + 1:]
    log.append("%s  occurrences=%d" % (rel, cnt))
    if apply:
        nb = b.replace(OLD, NEW)
        # invariants
        if p.lower().endswith(".bat"):
            # NOTE: a few bats are PRE-EXISTING non-ASCII (Chinese REM comments).
            # The invariant is "this edit changed no non-ASCII byte", not "is ASCII".
            assert [x for x in nb if x > 127] == [x for x in b if x > 127], \
                "edit altered non-ascii bytes: " + p
            crlf = nb.count(b"\r\n")
            lf = nb.count(b"\n")
            if crlf > 0:
                assert crlf == lf, "mixed line endings: " + p
        open(p, "wb").write(nb)

print("MODE =", "APPLY" if apply else "DRYRUN")
print("FILES = %d   OCCURRENCES = %d" % (nfiles, nlines))
print("OLD = %s" % OLD.decode())
print("NEW = %s" % NEW.decode())
print()
for l in log:
    print("   ", l)
