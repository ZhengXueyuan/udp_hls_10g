#!/usr/bin/env python
"""Turn p6e_pcie_ab/head/run_tb_p6e_pcie.bat into a HEAD-source arm:
after files.f is generated, filter out the two changed files and append the
HEAD copies from sim/p5wu_p1p2_regress/head_rtl/, then compile with -f files2.f.
Everything else (defines, TB, stub, glbl, xsim invocation) is untouched.

Run this on a PRISTINE copy of the gate bat.
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "p6e_pcie_ab", "head", "run_tb_p6e_pcie.bat")
b = open(p, "rb").read()

anchor = b"call %XV%\\xvlog.bat -work xil_defaultlib -d PCIE_OBS"
tok = b"-f files.f"
assert b.count(anchor) == 1, "anchor count %d" % b.count(anchor)
assert b.count(tok) == 1, "token count %d" % b.count(tok)

ins = (b"findstr /V /I /C:\"\\rtl\\app_ctrl.v\" /C:\"\\board\\wrapper_p4.v\" files.f > files2.f\r\n"
       b"echo %~dp0..\\..\\head_rtl\\app_ctrl.v   >> files2.f\r\n"
       b"echo %~dp0..\\..\\head_rtl\\wrapper_p4.v >> files2.f\r\n")
b = b.replace(anchor, ins + anchor)          # run the filter BEFORE xvlog
b = b.replace(tok, b"-f files2.f")           # compile the filtered list
open(p, "wb").write(b)
print("patched ok")
