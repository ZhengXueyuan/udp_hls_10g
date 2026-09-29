import os

d = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rollout"
B = chr(92)
lines = [
    "@echo off",
    "REM probe2: xelab wrapper_p4 with the xdma_0 sim stub (P6e lint config), timed",
    "setlocal",
    "set XV=C:" + B + "AMDDesignTools" + B + "2025.2" + B + "Vivado" + B + "bin",
    "set ROOT=D:" + B + "repo" + B + "XCKU5PMini" + B + "udp_hls_10g",
    "set WORK=%~dp0probe2_work",
    'if exist "%WORK%" rmdir /s /q "%WORK%"',
    'mkdir "%WORK%"',
    'cd /d "%WORK%"',
    "dir /b /s \"%ROOT%" + B + "rtl" + B + "*.v\" > files.f",
    "dir /b /s \"%ROOT%" + B + "hls" + B + "slowstack_prj" + B + "solution1" + B + "syn" + B + "verilog" + B + "*.v\" >> files.f",
    "echo %ROOT%" + B + "board" + B + "wrapper_p4.v >> files.f",
    "echo %ROOT%" + B + "board" + B + "util_gmii_to_rgmii_us.v >> files.f",
    "echo %ROOT%" + B + "board" + B + "uart_dbg.v >> files.f",
    "echo %ROOT%" + B + "_proj_pcie" + B + "rtl" + B + "axi_regs.v >> files.f",
    "echo %ROOT%" + B + "sim" + B + "p6e_pcie" + B + "xdma_0_sim_stub.v >> files.f",
    "echo === XVLOG %TIME% ===",
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%" + B + "rtl -i %ROOT%" + B + "board -f files.f > xv_p6.log 2>&1",
    "echo XVLOG_RC=%ERRORLEVEL%",
    "call %XV%" + B + "xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -work xil_defaultlib \"%XV%" + B + ".." + B + "data" + B + "verilog" + B + "src" + B + "glbl.v\" >> xv_p6.log 2>&1",
    "echo GLBL_RC=%ERRORLEVEL%",
    "echo === XELAB %TIME% ===",
    "call %XV%" + B + "xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lintprobe -log xe_p6.log > NUL 2>&1",
    "echo XELAB_RC=%ERRORLEVEL%",
    "echo === XELAB %TIME% ===",
    "type xe_p6.log",
]
p = os.path.join(d, "probe2_xelab_p6e.bat")
open(p, "wb").write(("\r\n".join(lines) + "\r\n").encode("ascii"))
print("wrote", p)
