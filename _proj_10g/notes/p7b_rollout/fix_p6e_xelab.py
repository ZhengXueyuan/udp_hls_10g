"""Add the xelab face to board/run_lint_p6e.bat (line-level insert, byte-exact).

WHY: the port-connection form of trap 24 prints NOTHING from xvlog (measured:
exit 0, log empty -- P7B_IMPLICIT_GATE_FIX.md 2.2).  A gate that only greps an
xvlog log therefore cannot ever catch it, whatever the keyword.  This gate's
whole stated reason to exist is trap 24, so it gets the xelab face.

RECIPE is the one already proven in sim/p6e_pcie/run_tb_p6e_pcie.bat:
  - xdma_0 is a Block-Design module with no RTL on disk -> compile the sim stub
  - glbl.v from the Vivado install
  - xelab -L unisims_ver (IDDRE1/ODDRE1/BUFG/RAMB36E2)
  - --mt so it stays fast (measured 11.7 s end to end)
"""
import os

P = r"D:\repo\XCKU5PMini\udp_hls_10g\board\run_lint_p6e.bat"
KEYS = ('/I /C:"Synth 8-11241" /C:"undeclared symbol" '
        '/C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" '
        '/C:"VRFC 10-2989" /C:"implicitly declared"')

b = open(P, "rb").read()
assert b.count(b"\r\n") == b.count(b"\n"), "expected uniform CRLF"
lines = b.split(b"\r\n")

STUB = (b"echo %ROOT%\\sim\\p6e_pcie\\xdma_0_sim_stub.v                >> files.f")
XELAB = [
    b"REM",
    b"REM ---- xelab face (P7B): the PORT-CONNECTION form of trap 24 prints NOTHING in",
    b"REM   xvlog (exit 0, empty log) -- xelab is the only detector for it.  xdma_0 is a",
    b"REM   Block-Design module with no RTL on disk, so the same sim stub the P6e gate",
    b"REM   uses is compiled in.  Measured ~12 s end to end (run_matrix is unaffected).",
    b"call %XV%\\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -work xil_defaultlib \"%XV%\\..\\data\\verilog\\src\\glbl.v\" >> xvlog_p6e.log 2>&1",
    b"call %XV%\\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lint_p6e -log xelab_p6e.log > NUL 2>&1",
    b"if errorlevel 1 (echo XELAB-FAIL & type xelab_p6e.log & exit /b 1)",
    b"findstr " + KEYS.encode() + b" xelab_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr " + KEYS.encode() + b" xelab_p6e.log & exit /b 1)",
]

out = []
nstub = nxel = 0
for ln in lines:
    if ln.startswith(b"call %XV%\\xvlog.bat ") and b"files.f" in ln and nstub == 0:
        out.append(STUB)
        nstub += 1
    if ln.startswith(b"echo LINT-OK") and nxel == 0:
        out.extend(XELAB)
        nxel += 1
    out.append(ln)

# the stub must be in the SAME library as wrapper_p4 -> switch that xvlog to xil_defaultlib
for i, ln in enumerate(out):
    if ln.startswith(b"call %XV%\\xvlog.bat ") and b"files.f" in ln and b"-work" not in ln:
        out[i] = ln.replace(b"-d PCIE_OBS", b"-work xil_defaultlib -d PCIE_OBS")
        assert b"-work xil_defaultlib" in out[i]

assert nstub == 1, nstub
assert nxel == 1, nxel
nb = b"\r\n".join(out)
assert nb.count(b"\r\n") == nb.count(b"\n")
assert [x for x in nb if x > 127] == [x for x in b if x > 127]
open(P, "wb").write(nb)

print("PATCHED", P)
print("  lines: %d -> %d" % (len(lines), len(out)))
print()
print("--- final file ---")
for i, ln in enumerate(out, 1):
    print("%3d| %s" % (i, ln.decode("ascii")))
