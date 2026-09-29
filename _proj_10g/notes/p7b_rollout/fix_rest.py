# -*- coding: utf-8 -*-
"""P7B rollout, part 2:
  (1) sim/p4gates/implicit_gate.bat -- canonical detector header: record the
      narrowed 10-3091 key and the newly measured excluded key 10-3645.
  (2) the remaining xvlog-only gates get the xelab face.
Byte-level, line-anchored, CRLF/LF preserved per file.
"""
import os

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
KEYS = ('/I /C:"Synth 8-11241" /C:"undeclared symbol" '
        '/C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" '
        '/C:"VRFC 10-2989" /C:"implicitly declared"')
STUB = "%ROOT%\\sim\\p6e_pcie\\xdma_0_sim_stub.v"
GLBL = '"%XV%\\..\\data\\verilog\\src\\glbl.v"'

def io(p, eol=None):
    b = open(p, "rb").read()
    e = eol or (b"\r\n" if b.count(b"\r\n") else b"\n")
    return b, e

def write(p, lines, eol, orig):
    nb = eol.join(lines)
    assert [x for x in nb if x > 127] == [x for x in orig if x > 127], p
    if eol == b"\r\n":
        assert nb.count(b"\r\n") == nb.count(b"\n"), p
    open(p, "wb").write(nb)

def insert_after(lines, anchor, block, first_only=True):
    out, done = [], 0
    for ln in lines:
        out.append(ln)
        if ln.startswith(anchor) and (done == 0 or not first_only):
            out.extend(block)
            done += 1
    return out, done

report = []

# ---------------------------------------------------------------- (1) detector
p = os.path.join(ROOT, "sim", "p4gates", "implicit_gate.bat")
b, e = io(p)
L = b.split(e)
blk = [
    b"REM   VRFC 10-3091 is used ONLY in its NARROW form",
    b"REM     \"VRFC 10-3091] actual bit length 1 differs from formal bit length\"",
    b"REM   because the bare key was measured to fire on BENIGN unsized literals:",
    b"REM   board/util_gmii_to_rgmii.v lines 188/189/190/192/203/207/216/220/232/",
    b"REM   234/235/245/247/248 are .CE(1)/.D1(1)/.D2(0)/.R(0)/.S(0) -> \"actual bit",
    b"REM   length 32 differs from formal bit length 1\" x14 on EVERY xelab of the",
    b"REM   default (K7) config.  An implicit net is ALWAYS 1 bit, so \"actual = 1\"",
    b"REM   is the exact trap-24 signature and no equal-width case can match it.",
    b"REM   VRFC 10-3645 \"port ... remains unconnected\" is the xelab-side twin of",
    b"REM   8-7129 and fires 20x on the CLEAN real P6e design -> excluded too.",
]
L2, n1 = insert_after(L, b"REM KEYS DELIBERATELY *NOT* USED", blk)
report.append("implicit_gate.bat: header insert done=%d" % n1)
write(p, L2, e, b)

# ------------------------------------------------------- (2a) p6b_lint/lint.bat
p = os.path.join(ROOT, "sim", "p6b_lint", "lint.bat")
b, e = io(p)
L = b.split(e)
add_files = [b"echo " + STUB.encode() + b" >> files.f"]
L2, n1 = insert_after(L, b"echo %ROOT%\\_proj_pcie\\rtl\\axi_regs.v", add_files)
xl = [
    b"REM ---- P7B xelab face: the port-connection form of trap 24 is SILENT in xvlog,",
    b"REM   so this lint must also elaborate (same recipe as board/run_lint_p6e.bat).",
    b"call %XV%\\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ " + GLBL.encode() + b" >> xvlog_lint.log 2>&1",
    b"call %XV%\\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lint_p6b -log xelab_lint.log > NUL 2>&1",
    b"if errorlevel 1 (echo XELAB-FAIL & type xelab_lint.log)",
    b"findstr /C:\"Built simulation snapshot\" xelab_lint.log >NUL || echo XELAB-NO-SNAPSHOT",
    b"findstr " + KEYS.encode() + b" xelab_lint.log && echo === IMPLICIT-XELAB ===",
]
L3, n2 = insert_after(L2, b"echo XVLOG-DONE", xl)   # appended after the last line
report.append("p6b_lint/lint.bat: files=%d xelab=%d" % (n1, n2))
write(p, L3, e, b)

# --------------------------------------------------- (2b) p6b_lint/lint_def.bat
p = os.path.join(ROOT, "sim", "p6b_lint", "lint_def.bat")
b, e = io(p)
L = b.split(e)
xld = [
    b"REM ---- P7B xelab face (DEFAULT / K7 config: util_gmii_to_rgmii.v, no PCIE_OBS",
    b"REM   so there is no xdma_0 and no stub is needed).",
    b"call %XV%\\xvlog.bat -work xil_defaultlib2 " + GLBL.encode() + b" >> xvlog_def.log 2>&1",
    b"call %XV%\\xelab.bat -debug typical -L unisims_ver xil_defaultlib2.wrapper_p4 xil_defaultlib2.glbl -s lint_def -log xelab_def.log > NUL 2>&1",
    b"if errorlevel 1 (echo XELAB-FAIL & type xelab_def.log)",
    b"findstr /C:\"Built simulation snapshot\" xelab_def.log >NUL || echo XELAB-NO-SNAPSHOT",
    b"findstr " + KEYS.encode() + b" xelab_def.log && echo === IMPLICIT-XELAB ===",
]
L2, n1 = insert_after(L, b"echo XVLOG-DEF-DONE", xld)
report.append("p6b_lint/lint_def.bat: xelab=%d" % n1)
write(p, L2, e, b)

# ------------------------------------------------ (2c) p6a_ku5p/pf/run_preflight
p = os.path.join(ROOT, "sim", "p6a_ku5p", "pf", "run_preflight.bat")
b, e = io(p)
L = b.split(e)
xlp = [
    b"REM ---- P7B xelab face: the port-connection form of trap 24 is SILENT in xvlog.",
    b"call %XV%\\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP " + GLBL.encode() + b" >> pf.log 2>&1",
    b"call %XV%\\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s preflight -log xelab_pf.log > NUL 2>&1",
    b"if errorlevel 1 (echo XELAB-FAIL & type xelab_pf.log)",
    b"findstr /C:\"Built simulation snapshot\" xelab_pf.log >NUL || echo XELAB-NO-SNAPSHOT",
    b"echo ---- implicit nets (xelab face) ----",
    b"findstr " + KEYS.encode() + b" xelab_pf.log",
]
L2, n1 = insert_after(L, b"echo ==== PREFLIGHT DONE", xlp)
report.append("run_preflight.bat: xelab=%d" % n1)
write(p, L2, e, b)

for r in report:
    print("  ", r)
