import os

d = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rollout"
B = chr(92)
NARROW = 'VRFC 10-3091] actual bit length 1 differs from formal bit length'
BROAD = 'VRFC 10-3091'
EV = 'sim' + B + 'p4gates' + B + 'evidence' + B + 'implicit_gate_2026-09-29'
lines = [
    "@echo off",
    "REM paired control: NARROW vs BROAD 3091 key on a TRUE positive and a FALSE positive",
    "setlocal",
    "set ROOT=D:" + B + "repo" + B + "XCKU5PMini" + B + "udp_hls_10g",
    "set TP=%ROOT%" + B + EV + B + "log_a_A1_xelab_10-3091.log.txt",
    "set FP=%ROOT%" + B + "sim" + B + "p5e_t2" + B + "xelab_wh.log",
    "echo ---- TP = A1_portconn xelab (implicit net, must FAIL) ----",
    "echo %TP%",
    "findstr /I /C:\"" + NARROW + "\" \"%TP%\" && echo   NARROW: TP-HIT  ^(good^) || echo   NARROW: TP-MISS  ^(BAD^)",
    "findstr /I /C:\"" + BROAD + "\" \"%TP%\" >NUL && echo   BROAD : TP-HIT  ^(good^) || echo   BROAD : TP-MISS",
    "echo ---- FP = real design, util_gmii_to_rgmii benign literals (must PASS) ----",
    "echo %FP%",
    "findstr /I /C:\"" + NARROW + "\" \"%FP%\" && echo   NARROW: FP-HIT  ^(BAD - false positive^) || echo   NARROW: FP-CLEAN  ^(good^)",
    "findstr /I /C:\"" + BROAD + "\" \"%FP%\" && echo   BROAD : FP-HIT  ^(this is the measured false positive^) || echo   BROAD : FP-CLEAN",
    "echo ---- the FP lines, verbatim ----",
    "findstr /I /C:\"" + BROAD + "\" \"%FP%\" | findstr /C:\"port 'CE'\" | findstr /C:\"util_gmii_to_rgmii.v:188\"",
    "echo ---- ALSO: does the narrowed key hit the frozen SYNTH log? ----",
    "findstr /I /C:\"" + NARROW + "\" \"%ROOT%" + B + EV + B + "log_a_A1_synth_8-11241.log.txt\" >NUL && echo   narrowed-in-synth-log: HIT  ^(expected - 10-3091 and 8-11241 coexist there^) || echo   narrowed-in-synth-log: no hit",
    "echo CTRL-DONE",
]
p = os.path.join(d, "ctrl_3091.bat")
open(p, "wb").write(("\r\n".join(lines) + "\r\n").encode("ascii"))
print("wrote", p)
