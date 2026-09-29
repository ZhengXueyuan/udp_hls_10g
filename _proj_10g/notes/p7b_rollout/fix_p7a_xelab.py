"""Add the xelab face to _proj_10g/tcl/run_lint_p7a.bat (line-level, byte-exact).

Same reason as board/run_lint_p6e.bat: p7a_top.v's port connections are invisible
to xvlog.  The recipe was measured first (probe_p7a.bat, 23 s, snapshot built):
  - gt_10gbr   : the IP's synth/ + hdl/ verilog (the hdl/ helpers are the
                 gtwizard_ultrascale_v1_7_* user-clock/reset/userdata modules)
  - vio_p7a    : vio_p7a_stub.v (the VIO core is not plain RTL) -- same black-box
                 trick as xdma_0_sim_stub.v in the P6e gate
  - -L unisims_ver -L secureip   (IBUFDS_GTE4 + the encrypted GTYE4 wrappers)
"""
import os

P = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\tcl\run_lint_p7a.bat"
KEYS = ('/I /C:"Synth 8-11241" /C:"undeclared symbol" '
        '/C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" '
        '/C:"VRFC 10-2989" /C:"implicitly declared"')

b = open(P, "rb").read()
eol = b"\r\n" if b.count(b"\r\n") > 0 else b"\n"
print("line ending:", "CRLF" if eol == b"\r\n" else "LF-only (pre-existing style)")
lines = b.split(eol)

IPV = [
    b"",
    b"REM ---- P7B: the IP sources p7a_top.v needs in order to ELABORATE ----",
    b"REM   gt_10gbr  = the IP's own verilog (synth wrapper + hdl helper modules)",
    b"REM   vio_p7a   = the synthesis STUB (the VIO core is not delivered as RTL)",
    b"set IP=%~dp0..\\vivado_prj\\p7a_prj.gen\\sources_1\\ip",
    b"set GTHDL=%IP%\\gt_10gbr\\hdl",
]
GUARD = [
    b"REM   the xelab face needs the generated IP; refuse (97) rather than pass blind",
    b"if not exist \"%IP%\\gt_10gbr\\hdl\\gtwizard_ultrascale_v1_7_gtwiz_reset.v\" (echo [PATHGUARD FAIL] missing gt_10gbr hdl sources -- build p7a_prj first & exit /b 97)",
    b"if not exist \"%IP%\\vio_p7a\\vio_p7a_stub.v\" (echo [PATHGUARD FAIL] missing vio_p7a_stub.v -- build p7a_prj first & exit /b 97)",
]
FILES = [
    b"dir /b /s \"%IP%\\gt_10gbr\\synth\\*.v\" >> files.f",
    b"dir /b /s \"%GTHDL%\\*.v\" >> files.f",
    b"echo %IP%\\vio_p7a\\vio_p7a_stub.v >> files.f",
]
XELAB = [
    b"REM",
    b"REM ---- xelab face (P7B): the PORT-CONNECTION form of trap 24 prints NOTHING",
    b"REM   in xvlog (exit 0, empty log), so xvlog alone structurally cannot catch it.",
    b"REM   Measured ~23 s.  vio_p7a_stub.v is a black box: we lint OUR rtl, not the",
    b"REM   VIO core internals.",
    b"call %XV%\\xvlog.bat -work xil_defaultlib -i \"%GTHDL%\" \"%XV%\\..\\data\\verilog\\src\\glbl.v\" >> xvlog.txt 2>&1",
    b"call %XV%\\xelab.bat -debug typical -L unisims_ver -L secureip xil_defaultlib.p7a_top xil_defaultlib.glbl -s lint_p7a -log xelab.txt > NUL 2>&1",
    b"if errorlevel 1 (echo XELAB-FAIL & type xelab.txt & exit /b 1)",
    b"REM   positive evidence: an empty/absent xelab log must NOT read as clean",
    b"findstr /C:\"Built simulation snapshot\" xelab.txt >NUL || (echo XELAB-NO-SNAPSHOT & type xelab.txt & exit /b 1)",
    b"findstr " + KEYS.encode() + b" xelab.txt >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr " + KEYS.encode() + b" xelab.txt & exit /b 1)",
]

out = []
did = {"ipv": 0, "guard": 0, "files": 0, "xelab": 0, "del": 0}
for ln in lines:
    if ln.startswith(b"set XV=") and did["ipv"] == 0:
        out.append(ln)
        out.extend(IPV)
        did["ipv"] = 1
        continue
    if ln.startswith(b"if not exist \"%RTL%\\p7a_counters.v\"") and did["guard"] == 0:
        out.append(ln)
        out.extend(GUARD)
        did["guard"] = 1
        continue
    if ln.startswith(b"del /q files.f") and did["del"] == 0:
        out.append(b"del /q files.f xvlog.txt xelab.txt >nul 2>&1")
        did["del"] = 1
        continue
    if ln.startswith(b"echo ---- files.f ----") and did["files"] == 0:
        out.extend(FILES)
        out.append(ln)
        did["files"] = 1
        continue
    if ln.startswith(b"call %XV%\\xvlog.bat -i %RTL%") :
        out.append(b"call %XV%\\xvlog.bat -work xil_defaultlib -i %RTL% -f files.f > xvlog.txt 2>&1")
        continue
    if ln.startswith(b"echo LINT-OK") and did["xelab"] == 0:
        out.extend(XELAB)
        did["xelab"] = 1
        out.append(ln)
        continue
    out.append(ln)

for k, v in did.items():
    assert v == 1, (k, v)
nb = eol.join(out)
assert [x for x in nb if x > 127] == [x for x in b if x > 127]
open(P, "wb").write(nb)

print("PATCHED", P)
print("lines %d -> %d" % (len(lines), len(out)))
for i, ln in enumerate(out, 1):
    print("%3d| %s" % (i, ln.decode("ascii")))
