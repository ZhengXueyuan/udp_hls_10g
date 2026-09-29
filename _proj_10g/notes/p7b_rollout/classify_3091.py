"""Classify every VRFC 10-3091 hit in the corpus: distinct (msg, source-file) tuples."""
import os
import re

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP = ["\\demo", "\\.git", "\\xsim.dir", "\\.xil", "\\p7b_implicit_repro",
        "\\p7b_rollout", "\\work_"]
EXTS = (".log", ".txt", ".rpt")

files = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if f.lower().endswith(EXTS):
            files.append(os.path.join(dp, f))
files.sort()

pat = re.compile(r"VRFC 10-3091\].*", re.I)
tuples = {}
for p in files:
    try:
        txt = open(p, "r", errors="replace").read()
    except OSError:
        continue
    if "10-3091" not in txt:
        continue
    rel = p[len(ROOT) + 1:]
    for ln in txt.splitlines():
        if "10-3091" not in ln:
            continue
        m = pat.search(ln)
        if not m:
            continue
        msg = m.group(0).strip()
        # strip the [file:line] tail into its own field
        mm = re.match(r"(.*?)\s*\[([^\]]+)\]\s*$", msg)
        if mm:
            core, src = mm.group(1), mm.group(2)
        else:
            core, src = msg, "?"
        # normalise the numbers away so we group by port+source
        key = (core, src)
        tuples.setdefault(key, []).append(rel)

print("distinct (message, source) tuples = %d" % len(tuples))
print()
cur_src = None
for (core, src), logs in sorted(tuples.items(), key=lambda kv: kv[0][1]):
    if src != cur_src:
        print("\n### SOURCE: %s   (%d logs)" % (src, len(logs)))
        cur_src = src
    print("    %s" % core)
    uniq_logs = sorted(set(logs))
    show = uniq_logs[:4]
    print("        logs(%d): %s%s" % (len(uniq_logs), ", ".join(x[:60] for x in show),
                                     " ..." if len(uniq_logs) > 4 else ""))
