import os
ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP = ["\\demo", "\\.git", "\\xsim.dir", "\\.xil"]
tot = 0
hits = []
xe = 0
xehits = 0
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if not f.lower().endswith((".log", ".txt")):
            continue
        if "xvlog" not in f.lower() and "xelab" not in f.lower():
            continue
        p = os.path.join(dp, f)
        try:
            t = open(p, errors="replace").read()
        except OSError:
            continue
        if "xvlog" in f.lower():
            tot += 1
            if "10-3091" in t:
                hits.append(p[len(ROOT) + 1:])
        else:
            xe += 1
            if "10-3091" in t:
                xehits += 1
print("xvlog-named logs scanned = %d ; containing 10-3091 = %d" % (tot, len(hits)))
for h in hits[:20]:
    print("   ", h)
print("xelab-named logs scanned = %d ; containing 10-3091 = %d" % (xe, xehits))
