import os

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"

# --- (1) revert my xelab block in run_preflight.bat (KEEP the narrowing edit) ---
# The block is exactly the 7 lines after "==== PREFLIGHT DONE".  Verified by
# content, not by a loose prefix (a loose prefix also matched the gate's own
# pre-existing xvlog calls at lines 11-13).
p = os.path.join(ROOT, "sim", "p6a_ku5p", "pf", "run_preflight.bat")
b = open(p, "rb").read()
e = b"\r\n" if b.count(b"\r\n") else b"\n"
L = b.split(e)
idx = None
for i, ln in enumerate(L):
    if ln.startswith(b"echo ==== PREFLIGHT DONE"):
        idx = i
        break
assert idx is not None, "anchor line not found"
block = L[idx + 1: idx + 8]
assert len(block) == 7, len(block)
expected = [
    b"REM ---- P7B xelab face",
    b'call %XV%\\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP "%XV%\\..\\data\\verilog\\src\\glbl.v"',
    b"call %XV%\\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4",
    b"if errorlevel 1 (echo XELAB-FAIL",
    b'findstr /C:"Built simulation snapshot" xelab_pf.log',
    b"echo ---- implicit nets (xelab face) ----",
    b'findstr /I /C:"Synth 8-11241"',
]
for got, exp in zip(block, expected):
    assert got.startswith(exp), (got, exp)
out = L[:idx + 1] + L[idx + 8:]
nb = e.join(out)
assert [x for x in nb if x > 127] == [x for x in b if x > 127]
open(p, "wb").write(nb)
print("run_preflight.bat: reverted %d line(s) at index %d" % (len(block), idx + 1))

# --- (2) p6b lints: guarantee rc=0 AND a positive-evidence tail ---
for f, log in [("lint.bat", "xelab_lint.log"), ("lint_def.bat", "xelab_def.log")]:
    p = os.path.join(ROOT, "sim", "p6b_lint", f)
    b = open(p, "rb").read()
    e = b"\r\n" if b.count(b"\r\n") else b"\n"
    L = b.split(e)
    extra = [b"echo XELAB-LINT-OK: xelab face ran, log = " + log.encode()]
    out, done = [], 0
    for ln in L:
        out.append(ln)
        if ln.startswith(b'findstr /I /C:"Synth 8-11241"') and b"xelab_" in ln and done == 0:
            out.extend(extra)
            done = 1
    assert done == 1, f
    assert [x for x in e.join(out) if x > 127] == [x for x in b if x > 127]
    open(p, "wb").write(e.join(out))
    print("%s: appended positive-evidence line" % f)
