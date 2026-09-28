# -*- coding: utf-8 -*-
"""P6a independent-review negative controls (test agent).

Generates mutated COPIES of the milestone RTL into sim/p6a_ku5p/negctl/ plus one
bat per variant (ASCII + CRLF).  Originals under rtl/ board/ tb/ are never touched.

Every mutation is a byte-level substring replacement; if the anchor substring is
not found exactly once the generator fails loudly (no silent no-op).
"""
import os

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
NEG = os.path.join(ROOT, "sim", "p6a_ku5p", "negctl")
XV = r"C:\AMDDesignTools\2025.2\Vivado\bin"
GLBL = os.path.join(XV, "..", "data", "verilog", "src", "glbl.v")

FF = os.path.join(ROOT, "rtl", "frame_fifo.v")
RGMU = os.path.join(ROOT, "board", "util_gmii_to_rgmii_us.v")
RGMK = os.path.join(ROOT, "board", "util_gmii_to_rgmii.v")
TBF = os.path.join(ROOT, "tb", "tb_frame_fifo.v")
TBP = os.path.join(ROOT, "tb", "tb_rgmii_phy_model.v")


def read(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8", "surrogateescape")


def write(p, s):
    with open(p, "wb") as f:
        f.write(s.encode("utf-8", "surrogateescape"))


def sub1(s, old, new, tag):
    n = s.count(old)
    assert n == 1, "anchor count %d != 1 for %s" % (n, tag)
    return s.replace(old, new)


def bat(name, lines):
    body = "@echo off\r\n" + "\r\n".join(lines) + "\r\n"
    assert all(ord(c) < 128 for c in body), name
    write(os.path.join(NEG, name), body)


def xv(tool):
    return os.path.join("%XV%", tool + ".bat")


def ff_bat(tag, src, snap, define=""):
    d = (" -d " + define) if define else ""
    v, l = "xvlog_" + tag + ".log", "xelab_" + tag + ".log"
    src_p = os.path.join("%ROOT%", "sim", "p6a_ku5p", "negctl", src)
    bat("run_ff_" + tag + ".bat", [
        "@echo off",
        "REM negctl frame_fifo: " + src + d + " + tb_frame_fifo.v",
        "cd /d %~dp0",
        "set XV=" + XV,
        "set ROOT=" + ROOT,
        "call " + os.path.join("%XV%", "xvlog.bat") + " -work xil_defaultlib" + d + " "
        + src_p + " " + os.path.join("%ROOT%", "tb", "tb_frame_fifo.v") + " > " + l.replace("xelab", "xvlog")
        + " 2>&1 || (type " + l.replace("xelab", "xvlog") + " & exit /b 1)",
        "call " + os.path.join("%XV%", "xvlog.bat") + " -work xil_defaultlib "
        + os.path.join("%XV%", "..", "data", "verilog", "src", "glbl.v")
        + " >> " + l.replace("xelab", "xvlog") + " 2>&1 || (type "
        + l.replace("xelab", "xvlog") + " & exit /b 1)",
        "call " + os.path.join("%XV%", "xelab.bat") + " -debug typical -L unisims_ver "
        + "xil_defaultlib.tb_frame_fifo xil_defaultlib.glbl -s " + snap + " -log " + l
        + " > NUL 2>&1 || (type " + l + " & exit /b 1)",
        "call " + os.path.join("%XV%", "xsim.bat") + " " + snap + " -runall -log xsim_"
        + tag + ".log > NUL 2>&1",
        "findstr /C:\"PASS_ALL\" /C:\"FAIL\" /C:\"FATAL\" /C:\"TIMEOUT\" xsim_" + tag + ".log",
    ])


def phy_bat(tag, src, snap):
    v, l = "xvlog_" + tag + ".log", "xelab_" + tag + ".log"
    bat("run_phy_" + tag + ".bat", [
        "@echo off",
        "REM negctl rgmii: " + src + " + util_gmii_to_rgmii.v (K7) + tb_rgmii_phy_model.v",
        "cd /d %~dp0",
        "set XV=" + XV,
        "set ROOT=" + ROOT,
        "call " + os.path.join("%XV%", "xvlog.bat") + " -work xil_defaultlib "
        + os.path.join("%ROOT%", "sim", "p6a_ku5p", "negctl", src) + " "
        + os.path.join("%ROOT%", "board", "util_gmii_to_rgmii.v") + " "
        + os.path.join("%ROOT%", "tb", "tb_rgmii_phy_model.v") + " > " + v
        + " 2>&1 || (type " + v + " & exit /b 1)",
        "call " + os.path.join("%XV%", "xvlog.bat") + " -work xil_defaultlib "
        + os.path.join("%XV%", "..", "data", "verilog", "src", "glbl.v")
        + " >> " + v + " 2>&1 || (type " + v + " & exit /b 1)",
        "call " + os.path.join("%XV%", "xelab.bat") + " -debug typical -L unisims_ver "
        + "xil_defaultlib.tb_rgmii_phy_model xil_defaultlib.glbl -s " + snap + " -log " + l
        + " > NUL 2>&1 || (type " + l + " & exit /b 1)",
        "call " + os.path.join("%XV%", "xsim.bat") + " " + snap + " -runall -log xsim_"
        + tag + ".log > NUL 2>&1",
        "findstr /C:\"---\" /C:\"[TX]\" /C:\"[RX]\" /C:\"RESULT\" /C:\"VERDICT\" /C:\"TIMEOUT\" xsim_"
        + tag + ".log",
    ])


# ---------------------------------------------------------------- frame_fifo
ff = read(FF)

# (i-a) literal form of the "shifted address" idea: {1'b0, a[8:0], 6'h00}
#       16-bit actual into a 15-bit port -> bit15 IS the inserted 1'b0 -> no-op.
write(os.path.join(NEG, "frame_fifo_bad_addr_lit.v"),
      sub1(ff, ".ADDRARDADDR({r_ad[8:0], 6'h00}),",
           ".ADDRARDADDR({1'b0, r_ad[8:0], 6'h00}),", "ff i-a"))

# (i-b) real one-bit shift: word address loses its LSB -> 2 words alias to 1 slot.
write(os.path.join(NEG, "frame_fifo_bad_addr_shift.v"),
      sub1(ff, ".ADDRARDADDR({r_ad[8:0], 6'h00}),",
           ".ADDRARDADDR({1'b0, r_ad[8:1], 7'h00}),", "ff i-b"))

# (ii) READ_WIDTH_A 72 -> 36 (E2 branch only; E1 branch has READ_WIDTH_B(72) not (0))
write(os.path.join(NEG, "frame_fifo_bad_rw36.v"),
      sub1(ff, ".READ_WIDTH_A(72), .READ_WIDTH_B(0),",
           ".READ_WIDTH_A(36), .READ_WIDTH_B(0),", "ff ii"))

# frame_fifo_head.v (zero-regression control) is produced by `git show` - see runbook.
ff_bat("headk7", "frame_fifo_head.v", "tb_ff_headk7")
ff_bat("addlit", "frame_fifo_bad_addr_lit.v", "tb_ff_addlit", "DEV_USP")
ff_bat("addrshift", "frame_fifo_bad_addr_shift.v", "tb_ff_addrshift", "DEV_USP")
ff_bat("rw36", "frame_fifo_bad_rw36.v", "tb_ff_rw36", "DEV_USP")

# ---------------------------------------------------------------- rgmii US+
us = read(RGMU)

# (1) RX IDDRE1 Q1/Q2 swapped on the 4 data lanes (ctl IDDRE1 left intact).
m = sub1(us, ".Q1(gmii_rxd_s[j]),", ".\x01S1(gmii_rxd_s[j+4]),", "q12 q1")
m = sub1(m, ".Q2(gmii_rxd_s[j+4]),", ".\x01S2(gmii_rxd_s[j]),", "q12 q2")
m = m.replace(".\x01S1", ".Q1").replace(".\x01S2", ".Q2")
write(os.path.join(NEG, "util_gmii_to_rgmii_us_q12swap.v"), m)

# (2) TXD ODDRE1 D1/D2 swapped on the 4 data lanes.
m = sub1(us, ".D1(txd_r[j]), .D2(txd_r[j+4]),", ".D1(txd_r[j+4]), .D2(txd_r[j]),", "d12")
write(os.path.join(NEG, "util_gmii_to_rgmii_us_d12swap.v"), m)

# (3) IDDRE1 IS_CB_INVERTED 1 -> 0 (2 source occurrences = 5 elaborated instances:
#     4 data lanes in the generate loop + 1 ctl).
assert us.count(".IS_CB_INVERTED(1'b1)") == 2, us.count(".IS_CB_INVERTED(1'b1)")
write(os.path.join(NEG, "util_gmii_to_rgmii_us_cbinv0.v"),
      us.replace(".IS_CB_INVERTED(1'b1)", ".IS_CB_INVERTED(1'b0)"))

phy_bat("q12swap", "util_gmii_to_rgmii_us_q12swap.v", "tb_phy_q12swap")
phy_bat("d12swap", "util_gmii_to_rgmii_us_d12swap.v", "tb_phy_d12swap")
phy_bat("cbinv0", "util_gmii_to_rgmii_us_cbinv0.v", "tb_phy_cbinv0")

print("generated OK")
