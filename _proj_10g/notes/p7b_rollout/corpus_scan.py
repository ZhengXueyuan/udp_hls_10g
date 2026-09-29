"""Corpus-level false-positive test for the P7B implicit-net gate key table.

Scans every real production log/txt in the repo with BOTH the old (dead) key
and the recommended 5-key table, and prints every match verbatim so each hit
can be classified as TRUE positive / FALSE positive.
"""
import os
import sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP_DIR_PARTS = [
    "\\demo", "\\.git", "\\xsim.dir", "\\.xil", "\\p7b_implicit_repro",
    "\\p7b_rollout", "\\work_", "\\.p7b_", "\\vivado_prj\\",
]
EXTS = (".log", ".txt", ".rpt", ".jou")

OLD_KEYS = ["implicitly", "implicit"]
NEW_KEYS = [
    "Synth 8-11241",
    "undeclared symbol",
    "VRFC 10-3091",
    "VRFC 10-2989",
    "implicitly declared",
]
# keys deliberately EXCLUDED (documented false positives)
EXCLUDED_KEYS = ["8-7129", "unconnected or has no load", "8-6014", "8-3917",
                 "VRFC 10-3645", "remains unconnected"]

argv = sys.argv[1:]
mode = argv[0] if argv else "scan"
only_prefix = argv[1] if len(argv) > 1 else ""

files = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP_DIR_PARTS):
        continue
    for f in fn:
        if f.lower().endswith(EXTS):
            files.append(os.path.join(dp, f))
files.sort()

if only_prefix:
    pl = os.path.join(ROOT, only_prefix).lower()
    files = [f for f in files if f.lower().startswith(pl)]

total_bytes = 0
new_hits = []      # (path, key, line)
old_hits = []      # (path, key, line)
exc_hits = []      # (path, key, line)
scanned = 0
for p in files:
    try:
        sz = os.path.getsize(p)
    except OSError:
        continue
    if sz > 400 * 1024 * 1024:
        print("SKIP-TOO-BIG", sz, p)
        continue
    total_bytes += sz
    scanned += 1
    try:
        txt = open(p, "r", errors="replace").read()
    except OSError as e:
        print("READ-ERR", p, e)
        continue
    low = txt.lower()
    for k in NEW_KEYS:
        if k.lower() in low:
            for ln in txt.splitlines():
                if k.lower() in ln.lower():
                    new_hits.append((p, k, ln.strip()[:300]))
    for k in OLD_KEYS:
        if k in low:
            for ln in txt.splitlines():
                if k in ln.lower():
                    old_hits.append((p, k, ln.strip()[:300]))
    for k in EXCLUDED_KEYS:
        if k.lower() in low:
            for ln in txt.splitlines():
                if k.lower() in ln.lower():
                    exc_hits.append((p, k, ln.strip()[:300]))

print("CORPUS_FILES_SCANNED =", scanned)
print("CORPUS_BYTES =", total_bytes)
print()
print("=== NEW 5-KEY HITS: %d ===" % len(new_hits))
for p, k, ln in new_hits:
    print("  [%s] %s" % (k, p[len(ROOT) + 1:]))
    print("      %s" % ln)
print()
print("=== OLD-KEY HITS (implicit / implicitly): %d ===" % len(old_hits))
seen = set()
for p, k, ln in old_hits:
    key = (p, ln)
    if key in seen:
        continue
    seen.add(key)
    print("  [%s] %s" % (k, p[len(ROOT) + 1:]))
    print("      %s" % ln)
print()
print("=== EXCLUDED-KEY HITS (must stay excluded): %d ===" % len(exc_hits))
agg = {}
for p, k, ln in exc_hits:
    agg.setdefault(k, []).append(p[len(ROOT) + 1:])
for k, v in sorted(agg.items()):
    print("  key=%-32s files=%d  e.g. %s" % (k, len(v), v[0]))
    print("      %s" % dict.fromkeys([x for x in v]).__iter__().__next__())
