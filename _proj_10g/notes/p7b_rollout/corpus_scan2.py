"""Corpus scan v2: aggregate per file x key, so each hit can be classified."""
import os
import sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP_DIR_PARTS = [
    "\\demo", "\\.git", "\\xsim.dir", "\\.xil", "\\p7b_implicit_repro",
    "\\p7b_rollout", "\\work_",
]
EXTS = (".log", ".txt", ".rpt")

NEW_KEYS = [
    "Synth 8-11241",
    "undeclared symbol",
    "VRFC 10-3091",
    "VRFC 10-2989",
    "implicitly declared",
]
OLD_KEYS = ["implicitly", "implicit"]
EXCLUDED_KEYS = ["8-7129", "unconnected or has no load", "8-6014", "8-3917",
                 "VRFC 10-3645", "remains unconnected", "does not have driver"]

files = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP_DIR_PARTS):
        continue
    for f in fn:
        if f.lower().endswith(EXTS):
            files.append(os.path.join(dp, f))
files.sort()

agg = {}          # (relpath, key) -> [count, sample_line]
oldagg = {}
excagg = {}
nbytes = 0
for p in files:
    try:
        nbytes += os.path.getsize(p)
    except OSError:
        continue
    try:
        txt = open(p, "r", errors="replace").read()
    except OSError:
        continue
    rel = p[len(ROOT) + 1:]
    low = txt.lower()
    for kind, keys, store in (("new", NEW_KEYS, agg), ("old", OLD_KEYS, oldagg),
                              ("exc", EXCLUDED_KEYS, excagg)):
        for k in keys:
            if k.lower() not in low:
                continue
            cnt = 0
            sample = ""
            for ln in txt.splitlines():
                if k.lower() in ln.lower():
                    cnt += 1
                    if not sample:
                        sample = ln.strip()[:220]
            store[(rel, k)] = [cnt, sample]

print("CORPUS_FILES = %d   BYTES = %d" % (len(files), nbytes))
print()
print("=" * 78)
print("NEW 5-KEY: file x key")
print("=" * 78)
byfile = {}
for (rel, k), (c, s) in agg.items():
    byfile.setdefault(rel, []).append((k, c, s))
for rel in sorted(byfile):
    print("%-58s" % rel)
    for k, c, s in byfile[rel]:
        print("      %-20s x%-5d %s" % (k, c, s[:150]))
print()
print("NEW KEY TOTALS: files=%d  key-events=%d" % (len(byfile), len(agg)))
for k in NEW_KEYS:
    tot = sum(v[0] for (r, kk), v in agg.items() if kk == k)
    nf = sum(1 for (r, kk) in agg if kk == k)
    print("   %-22s events=%-6d files=%d" % (k, tot, nf))
print()
print("=" * 78)
print("OLD KEY (implicit / implicitly) -- on the SAME corpus")
print("=" * 78)
for (rel, k), (c, s) in sorted(oldagg.items()):
    print("   %-58s [%s] x%d" % (rel, k, c))
    print("        %s" % s[:170])
print("OLD KEY TOTALS: files=%d" % len(set(r for (r, k) in oldagg)))
print()
print("=" * 78)
print("EXCLUDED KEYS (must remain excluded; hits here prove why)")
print("=" * 78)
for k in EXCLUDED_KEYS:
    ev = [(r, v) for (r, kk), v in excagg.items() if kk == k]
    if not ev:
        print("   %-28s NO HITS in corpus" % k)
        continue
    tot = sum(v[0] for r, v in ev)
    print("   %-28s events=%-6d files=%d" % (k, tot, len(ev)))
    for r, v in sorted(ev)[:3]:
        print("        %-52s x%-5d %s" % (r, v[0], v[1][:120]))
