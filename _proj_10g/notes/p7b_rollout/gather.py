import os

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP = ["\\demo", "\\.git", "\\xsim.dir", "\\.xil", "p7b_implicit_repro", "p7b_rollout"]
NEEDLE = ('/C:"VRFC 10-3091] actual bit length 1 differs from formal bit length"').encode()
OLDNEEDLE = b'/C:"VRFC 10-3091"'
files = occ = 0
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if f.lower().endswith((".bat", ".py", ".tcl")):
            p = os.path.join(dp, f)
            b = open(p, "rb").read()
            c = b.count(NEEDLE)
            if c:
                files += 1
                occ += c
print("narrowed-key FILES=%d OCCURRENCES=%d" % (files, occ))
# also: how many files had the OLD key before (sanity: should now be 0 outside scratch)
rest = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if f.lower().endswith((".bat", ".py", ".tcl")):
            p = os.path.join(dp, f)
            if OLDNEEDLE in open(p, "rb").read():
                rest.append(p[len(ROOT) + 1:])
print("files still holding the BARE key:", len(rest), rest)
