import os

d = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rollout"
B = chr(92)
PRJ = r"%ROOT%\_proj_10g\vivado_prj\p7a_prj.gen\sources_1\ip"
lines = [
    "@echo off",
    "REM probe p7a: can p7a_top be elaborated (GT + VIO IP sources)?",
    "setlocal",
    "set XV=C:" + B + "AMDDesignTools" + B + "2025.2" + B + "Vivado" + B + "bin",
    "set ROOT=D:" + B + "repo" + B + "XCKU5PMini" + B + "udp_hls_10g",
    "set RTL=%ROOT%" + B + "_proj_10g" + B + "rtl",
    "set IP=" + PRJ,
    "set WORK=%~dp0probe_p7a_work",
    "if exist \"%WORK%\" rmdir /s /q \"%WORK%\"",
    "mkdir \"%WORK%\"",
    "cd /d \"%WORK%\"",
    "copy /y \"%RTL%" + B + ".." + B + "tcl" + B + "lint" + B + "files.f\" files.f >NUL",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gtwizard_ultrascale_v1_7_gtye4_channel.v >> files.f",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gtwizard_ultrascale_v1_7_gtye4_common.v >> files.f",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gt_10gbr.v >> files.f",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gt_10gbr_gtwizard_gtye4.v >> files.f",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gt_10gbr_gtwizard_top.v >> files.f",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gt_10gbr_gtye4_channel_wrapper.v >> files.f",
    "echo %IP%" + B + "gt_10gbr" + B + "synth" + B + "gt_10gbr_gtye4_common_wrapper.v >> files.f",
    "echo %IP%" + B + "vio_p7a" + B + "synth" + B + "vio_p7a.v >> files.f",
    "echo --- files.f ---",
    "type files.f",
    "echo === XVLOG %TIME% ===",
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib -i %RTL% -f files.f > xv_p7a.log 2>&1",
    "echo XVLOG_RC=%ERRORLEVEL%",
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib \"%XV%" + B + ".." + B + "data" + B + "verilog" + B + "src" + B + "glbl.v\" >> xv_p7a.log 2>&1",
    "echo === XELAB %TIME% ===",
    "call %XV%" + B + "xelab.bat -debug typical -L unisims_ver -L secureip xil_defaultlib.p7a_top xil_defaultlib.glbl -s lint_p7a -log xe_p7a.log > NUL 2>&1",
    "echo XELAB_RC=%ERRORLEVEL%",
    "echo === xelab log ===",
    "type xe_p7a.log",
]
p = os.path.join(d, "probe_p7a.bat")
open(p, "wb").write(("\r\n".join(lines) + "\r\n").encode("ascii"))
print("wrote", p)
