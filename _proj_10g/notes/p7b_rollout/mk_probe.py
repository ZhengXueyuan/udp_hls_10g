import os

d = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rollout"
os.makedirs(d, exist_ok=True)
B = chr(92)  # backslash
lines = [
    "@echo off",
    "REM probe: can xelab elaborate the P6e lint source set? (timed, scratch only)",
    "setlocal",
    "set XV=C:" + B + "AMDDesignTools" + B + "2025.2" + B + "Vivado" + B + "bin",
    "set ROOT=D:" + B + "repo" + B + "XCKU5PMini" + B + "udp_hls_10g",
    "set WORK=%~dp0probe_work",
    'if exist "%WORK%" rmdir /s /q "%WORK%"',
    'mkdir "%WORK%"',
    'cd /d "%WORK%"',
    "dir /b /s \"%ROOT%" + B + "rtl" + B + "*.v\" > files.f",
    "dir /b /s \"%ROOT%" + B + "hls" + B + "slowstack_prj" + B + "solution1" + B + "syn" + B + "verilog" + B + "*.v\" >> files.f",
    "echo %ROOT%" + B + "board" + B + "wrapper_p4.v >> files.f",
    "echo %ROOT%" + B + "board" + B + "util_gmii_to_rgmii_us.v >> files.f",
    "echo %ROOT%" + B + "board" + B + "util_gmii_to_rgmii.v >> files.f",
    "echo %ROOT%" + B + "board" + B + "uart_dbg.v >> files.f",
    "echo %ROOT%" + B + "_proj_pcie" + B + "rtl" + B + "axi_regs.v >> files.f",
    "echo === XVLOG START %TIME% ===",
    "call %XV%" + B + "xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%" + B + "rtl -i %ROOT%" + B + "board -f files.f > xvlog.log 2>&1",
    "echo XVLOG_RC=%ERRORLEVEL%",
    "echo === XELAB START %TIME% ===",
    "call %XV%" + B + "xelab.bat -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lintprobe --mt 4 > xelab.log 2>&1",
    "echo XELAB_RC=%ERRORLEVEL%",
    "echo === xelab.log tail ===",
    "type xelab.log",
    "echo === XELAB DONE %TIME% ===",
]
p = os.path.join(d, "probe_xelab_p6e.bat")
open(p, "wb").write(("\r\n".join(lines) + "\r\n").encode("ascii"))
print("wrote", p, os.path.getsize(p), "bytes")
