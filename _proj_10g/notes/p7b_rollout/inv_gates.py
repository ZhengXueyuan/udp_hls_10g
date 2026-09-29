import os, re, sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
SKIP = ["\\demo", "\\.git", "\\xsim.dir", "\\.xil", "p7b_implicit_repro", "\\work_", "\\vivado_prj"]
bats = []
for dp, dn, fn in os.walk(ROOT):
    low = dp.lower()
    if any(s in low for s in SKIP):
        continue
    for f in fn:
        if f.lower().endswith(".bat"):
            bats.append(os.path.join(dp, f))

rows = []
for b in sorted(bats):
    t = open(b, "r", errors="replace").read()
    has_key = "Synth 8-11241" in t
    n_key = sum(1 for k in ["Synth 8-11241", "undeclared symbol", "VRFC 10-3091", "VRFC 10-2989", "implicitly declared"] if k in t)
    xv = bool(re.search(r"xvlog\.bat", t, re.I))
    xe = bool(re.search(r"xelab\.bat", t, re.I))
    sy = bool(re.search(r"synth_design", t, re.I))
    rel = b[len(ROOT) + 1:]
    rows.append((rel, has_key, n_key, xv, xe, sy))

print("=== gates carrying the new key table ===")
for rel, hk, nk, xv, xe, sy in rows:
    if hk:
        k = []
        if xv: k.append("xvlog")
        if xe: k.append("xelab")
        if sy: k.append("synth")
        print("%-14s keys=%d  %s" % ("/".join(k) or "NONE", nk, rel))
print("=== bats with xvlog but NO a-detector and no key table ===")
for rel, hk, nk, xv, xe, sy in rows:
    if xv and not hk:
        print("   ", rel)
print("total bats:", len(bats), " with-key:", sum(1 for r in rows if r[1]))
