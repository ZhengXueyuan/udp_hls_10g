import os

d = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rollout"
B = chr(92)
XV = "C:" + B + "AMDDesignTools" + B + "2025.2" + B + "Vivado" + B + "bin"
ROOT = "D:" + B + "repo" + B + "XCKU5PMini" + B + "udp_hls_10g"

def fileset(extra_defs, us):
    out = []
    out.append("dir /b /s \"%ROOT%" + B + "rtl" + B + "*.v\" > files.f")
    out.append("dir /b /s \"%ROOT%" + B + "hls" + B + "slowstack_prj" + B + "solution1" + B + "syn" + B + "verilog" + B + "*.v\" >> files.f")
    out.append("echo %ROOT%" + B + "board" + B + "wrapper_p4.v >> files.f")
    out.append("echo %ROOT%" + B + "board" + B + "util_gmii_to_rgmii%s.v >> files.f" % us)
    out.append("echo %ROOT%" + B + "board" + B + "uart_dbg.v >> files.f")
    return out

lines = [
    "@echo off",
    "setlocal",
    "set XV=" + XV,
    "set ROOT=" + ROOT,
    "set W=%~dp0probe_cfg_work",
    'if exist "%W%" rmdir /s /q "%W%"',
    'mkdir "%W%"',
    'cd /d "%W%"',
]
# ---- config B: DEV_USP + APP_MODE (no PCIE_OBS)  -> run_preflight.bat
lines += ["echo ##### CONFIG B: DEV_USP+APP_MODE, util_gmii_to_rgmii_us #####"]
lines += fileset(None, "_us")
lines += [
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -i %ROOT%" + B + "rtl -i %ROOT%" + B + "board -f files.f > xvB.log 2>&1",
    "echo XVLOG_B=%ERRORLEVEL%",
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP \"%XV%" + B + ".." + B + "data" + B + "verilog" + B + "src" + B + "glbl.v\" >> xvB.log 2>&1",
    "call %XV%" + B + "xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s cfgB -log xeB.log > NUL 2>&1",
    "echo XELAB_B=%ERRORLEVEL%",
    "findstr /C:\"Built simulation snapshot\" xeB.log >NUL && echo SNAPSHOT_B=yes || echo SNAPSHOT_B=NO",
    "findstr /I /C:\"Synth 8-11241\" /C:\"undeclared symbol\" /C:\"VRFC 10-3091] actual bit length 1 differs from formal bit length\" /C:\"VRFC 10-2989\" /C:\"implicitly declared\" xeB.log && echo NARROW-HIT-B || echo NARROW-CLEAN-B",
    "echo --- config B errors ---",
    "findstr /C:\"ERROR\" xeB.log",
]
# ---- config C: DEFAULT (no defines) -> sim/p6b_lint/lint_def.bat
lines += ["echo ##### CONFIG C: default (K7 shim util_gmii_to_rgmii.v) #####"]
lines += [
    'del /q files.f >NUL',
]
lines += fileset(None, "")
lines += [
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib -i %ROOT%" + B + "rtl -i %ROOT%" + B + "board -f files.f > xvC.log 2>&1",
    "echo XVLOG_C=%ERRORLEVEL%",
    "call %XV%" + B + "xvlog.bat -work xil_defaultlib \"%XV%" + B + ".." + B + "data" + B + "verilog" + B + "src" + B + "glbl.v\" >> xvC.log 2>&1",
    "call %XV%" + B + "xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s cfgC -log xeC.log > NUL 2>&1",
    "echo XELAB_C=%ERRORLEVEL%",
    "findstr /C:\"Built simulation snapshot\" xeC.log >NUL && echo SNAPSHOT_C=yes || echo SNAPSHOT_C=NO",
    "echo --- C: BROAD 10-3091 (expected: benign util_gmii literals) ---",
    "findstr /C:\"10-3091\" xeC.log | findstr /C:\"util_gmii_to_rgmii.v\" | findstr /C:\"formal bit length 1 \"",
    "echo --- C: NARROW key (must be clean) ---",
    "findstr /I /C:\"VRFC 10-3091] actual bit length 1 differs from formal bit length\" xeC.log && echo NARROW-HIT-C || echo NARROW-CLEAN-C",
    "echo --- C: all 5 keys ---",
    "findstr /I /C:\"Synth 8-11241\" /C:\"undeclared symbol\" /C:\"VRFC 10-3091] actual bit length 1 differs from formal bit length\" /C:\"VRFC 10-2989\" /C:\"implicitly declared\" xeC.log && echo KEYS-HIT-C || echo KEYS-CLEAN-C",
    "echo --- config C errors ---",
    "findstr /C:\"ERROR\" xeC.log",
    "echo PROBE-CFG-DONE",
]
p = os.path.join(d, "probe_cfg.bat")
open(p, "wb").write(("\r\n".join(lines) + "\r\n").encode("ascii"))
print("wrote", p)
