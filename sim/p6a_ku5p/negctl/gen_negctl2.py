# -*- coding: utf-8 -*-
"""P6a independent-review negative controls, part 2 (test agent).

Adds two diagnostic variants + their bats:
  tb_rgmii_phy_model_ctlfix.v   - PHY model with RGMII-legal per-half-slot RX_CTL
  util_gmii_to_rgmii_k7_noinv.v - K7 front end with BUFG(rxc) instead of BUFG(~rxc)
Originals under rtl/ board/ tb/ are never touched.
"""
import os

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
NEG = os.path.join(ROOT, "sim", "p6a_ku5p", "negctl")
XV = r"C:\AMDDesignTools\2025.2\Vivado\bin"
TBP = os.path.join(ROOT, "tb", "tb_rgmii_phy_model.v")
RGMU = os.path.join(ROOT, "board", "util_gmii_to_rgmii_us.v")
RGMK = os.path.join(ROOT, "board", "util_gmii_to_rgmii.v")


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


def phy_bat(tag, sources, snap):
    """sources: list of ABSOLUTE paths already inside negctl/ board/ tb/."""
    v, l = "xvlog_" + tag + ".log", "xelab_" + tag + ".log"
    srcs = " ".join("%ROOT%" + s[len(ROOT):] for s in sources)
    bat("run_phy_" + tag + ".bat", [
        "@echo off",
        "REM negctl rgmii variant " + tag,
        "REM sources: " + " ".join(sources),
        "cd /d %~dp0",
        "set XV=" + XV,
        "set ROOT=" + ROOT,
        "call " + os.path.join("%XV%", "xvlog.bat") + " -work xil_defaultlib " + srcs
        + " > " + v + " 2>&1 || (type " + v + " & exit /b 1)",
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


tb = read(TBP)

# (A) RGMII-legal RX_CTL: rising-edge slot = RX_DV, falling-edge slot = RX_DV ^ RX_ER.
#     current model drives RX_DV & ~RX_ER for BOTH slots of an ER byte.
write(os.path.join(NEG, "tb_rgmii_phy_model_ctlfix.v"),
      sub1(tb, "wire       ctl_w = load_en ^ (load_en & cur_er);",
           "wire       ctl_w = phy_clk ? load_en : (load_en & ~cur_er);", "ctlfix"))

# (B) K7 front end with a non-inverted RXC buffer (diagnostic for the RX-edge recipe).
k7 = read(RGMK)
write(os.path.join(NEG, "util_gmii_to_rgmii_k7_noinv.v"),
      sub1(k7, ".I(~rgmii_rxc),", ".I(rgmii_rxc),   // negctl: 去反相 (诊断用)", "k7noinv"))

phy_bat("ctlfix", [os.path.join(NEG, "tb_rgmii_phy_model_ctlfix.v"), RGMU, RGMK],
        "tb_phy_ctlfix")
phy_bat("k7noinv", [TBP, RGMU, os.path.join(NEG, "util_gmii_to_rgmii_k7_noinv.v")],
        "tb_phy_k7noinv")

print("generated part2 OK")
