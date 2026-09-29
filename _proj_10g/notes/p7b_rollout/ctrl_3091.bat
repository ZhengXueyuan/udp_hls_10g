@echo off
REM paired control: NARROW vs BROAD 3091 key on a TRUE positive and a FALSE positive
setlocal
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set TP=%ROOT%\sim\p4gates\evidence\implicit_gate_2026-09-29\log_a_A1_xelab_10-3091.log.txt
set FP=%ROOT%\sim\p5e_t2\xelab_wh.log
echo ---- TP = A1_portconn xelab (implicit net, must FAIL) ----
echo %TP%
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" "%TP%" && echo   NARROW: TP-HIT  ^(good^) || echo   NARROW: TP-MISS  ^(BAD^)
findstr /I /C:"VRFC 10-3091" "%TP%" >NUL && echo   BROAD : TP-HIT  ^(good^) || echo   BROAD : TP-MISS
echo ---- FP = real design, util_gmii_to_rgmii benign literals (must PASS) ----
echo %FP%
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" "%FP%" && echo   NARROW: FP-HIT  ^(BAD - false positive^) || echo   NARROW: FP-CLEAN  ^(good^)
findstr /I /C:"VRFC 10-3091" "%FP%" && echo   BROAD : FP-HIT  ^(this is the measured false positive^) || echo   BROAD : FP-CLEAN
echo ---- the FP lines, verbatim ----
findstr /I /C:"VRFC 10-3091" "%FP%" | findstr /C:"port 'CE'" | findstr /C:"util_gmii_to_rgmii.v:188"
echo ---- ALSO: does the narrowed key hit the frozen SYNTH log? ----
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" "%ROOT%\sim\p4gates\evidence\implicit_gate_2026-09-29\log_a_A1_synth_8-11241.log.txt" >NUL && echo   narrowed-in-synth-log: HIT  ^(expected - 10-3091 and 8-11241 coexist there^) || echo   narrowed-in-synth-log: no hit
echo CTRL-DONE
