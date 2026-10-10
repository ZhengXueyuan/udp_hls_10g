# -*- coding: utf-8 -*-
"""搭 4 个 xsim 工作目录 (2x2 判据矩阵) + 生成 ASCII/CRLF 的 runner bat."""
import io, os, shutil
D = os.path.dirname(os.path.abspath(__file__))
PRIS = os.path.join(os.path.dirname(D), "pristine")
M = "D:/repo/XCKU5PMini/_proj_mdio"

new_rtl = io.open(os.path.join(M, "rtl/mdio_master.v"), encoding="utf-8").read()
new_tb  = io.open(os.path.join(M, "tb/tb_mdio_master.v"), encoding="utf-8").read()
old_rtl = io.open(os.path.join(PRIS, "mdio_master.v.orig"), encoding="utf-8").read()
old_tb  = io.open(os.path.join(PRIS, "tb_mdio_master.v.orig"), encoding="utf-8").read()

# --- 旧 RTL 的 shim: 只在副本上把模块改名, 正文逐字不动 (下面自证) ---
assert "module mdio_master #(" in old_rtl
legacy = old_rtl.replace("module mdio_master #(", "module mdio_master_legacy #(", 1)
assert legacy.count("mdio_master_legacy") == 1
assert len(legacy) == len(old_rtl) + len("_legacy")

SHIM = u"""// Negative-control shim (2026-10-10): instantiate the UNMODIFIED pre-guard
// mdio_master (imported verbatim, only the module name gains a _legacy suffix),
// and model the two observables the old core does not have as constants:
// a signal that does not exist cannot report anything, so it reads 0.
module mdio_master #(
    parameter integer DIV = 25
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire        op,
    input  wire [4:0]  phyad,
    input  wire [4:0]  regad,
    input  wire [15:0] wr_data,
    output wire [15:0] rd_data,
    output wire        done,
    output wire        done_sticky,
    output wire        busy,
    output wire        mdc,
    output wire        mdio_o,
    output wire        mdio_t,
    input  wire        mdio_i,
    output wire        param_bad,
    output wire        stat_start_lost
);
    mdio_master_legacy #(.DIV(DIV)) u_legacy (
        .clk (clk), .rstn (rstn), .start (start), .op (op),
        .phyad (phyad), .regad (regad), .wr_data (wr_data),
        .rd_data (rd_data), .done (done), .done_sticky (done_sticky),
        .busy (busy), .mdc (mdc), .mdio_o (mdio_o), .mdio_t (mdio_t),
        .mdio_i (mdio_i)
    );
    assign param_bad       = 1'b0;
    assign stat_start_lost = 1'b0;
endmodule
"""

BAT = r"""@echo off
cd /d %~dp0
rem 2026-10-10 tool-debt round: standalone xsim runner (no Vivado project).
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call "%XV%\xvlog.bat" -work work {srcs} > xvlog.stdout.txt 2>&1
if errorlevel 1 (echo XVLOG_FAIL & type xvlog.stdout.txt & type xvlog.log & exit /b 1)
call "%XV%\xelab.bat" work.tb_mdio_master -s tb_sim -log xelab.log > NUL 2>&1
if errorlevel 1 (echo XELAB_FAIL & type xelab.log & exit /b 1)
call "%XV%\xsim.bat" tb_sim -runall -log xsim.log > NUL 2>&1
set RC=%errorlevel%
echo XSIM_RC=%RC%
type xsim.log
exit /b %RC%
"""

CASES = {
    "rm1_newrtl_newtb": ("new_rtl", "new_tb"),
    "rm2_oldrtl_newtb": ("old_shim", "new_tb"),
    "rm3_newrtl_oldtb": ("new_rtl", "old_tb"),
    "rm4_oldrtl_oldtb": ("old_shim", "old_tb"),
}
for name, (rtl_kind, tb_kind) in CASES.items():
    d = os.path.join(D, name)
    if os.path.isdir(d): shutil.rmtree(d)
    os.makedirs(d)
    def wr(p, s):
        io.open(p, "w", encoding="utf-8", newline="\r\n").write(s.replace("\r\n", "\n"))
    if rtl_kind == "new_rtl":
        wr(os.path.join(d, "mdio_master.v"), new_rtl)
        srcs = "mdio_master.v tb_mdio_master.v"
    else:
        wr(os.path.join(d, "mdio_master_legacy.v"), legacy)
        wr(os.path.join(d, "mdio_master_shim.v"), SHIM)
        srcs = "mdio_master_legacy.v mdio_master_shim.v tb_mdio_master.v"
    wr(os.path.join(d, "tb_mdio_master.v"), new_tb if tb_kind == "new_tb" else old_tb)
    # bat must be ASCII only -> strip the non-ASCII comments from the template
    bat = "\n".join(l for l in BAT.split("\n") if all(ord(c) < 128 for c in l))
    io.open(os.path.join(d, "run.bat"), "w", encoding="ascii", newline="\r\n").write(
        bat.replace("{srcs}", srcs).replace("\r\n", "\n"))
    print("BUILT %-20s rtl=%-9s tb=%s" % (name, rtl_kind, tb_kind))
print("legacy body unchanged (only module name):", legacy.replace("_legacy", "", 1) == old_rtl)
