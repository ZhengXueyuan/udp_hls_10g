@echo off
REM ---------------------------------------------------------------------------
REM run_tb_snap_cdc.bat -- unit gate for snap_cdc (coherent snapshot CDC).
REM   hard failures per run: implicit nets and bit-width mismatches (trap 24).
REM   runs in its own sim dir (trap 7: parallel gates must not share xsim.dir).
REM
REM   FIVE runs, one per NW: 14 / 22 / 24 / 32 / 36  (each with -d TB_NW_<W>)
REM     NW=14 / NW=22  = the REAL bundle widths of the P6b integration
REM                      (board/wrapper_p4.v: SNAP_FE_NW=14, SNAP_DP_NW=22)
REM     NW=36          = SNAP_NW_P6E, the whole two-bundle window (14+22)
REM     NW=24 / NW=32  = historical widths, kept for regression continuity
REM
REM   *** printed size == measured size (the reason this script was rewritten) ***
REM   Each run prints the width it ACTUALLY compiled: the TB echoes its own `TB_NW
REM   macro as  "TB_NW_SEL: NW=<n> NB=<n*32> MACRO=TB_NW_<n>"  and this script
REM   asserts that line matches the width it asked for.  Mismatch => that run FAILs.
REM   History: v1 echoed "NW=36" while compiling -d TB_NW_32, and the TB had no 36
REM   path at all (it fell back to 32) => it really ran {32,24}. Printed A, measured B.
REM
REM   Same for the skew self-check: the TB prints
REM     "SKEW_SELFTEST: NW=<n> STEP_FS=.. TOTAL_FS=.. LIMIT_FS=.. VERDICT=OK"
REM   and this script requires VERDICT=OK (per-lane skew must scale with NW so the
REM   whole-bundle skew stays 3.6ns < clk_b half period 4.55ns).
REM
REM   exit 0 = every width PASS_ALL / exit 1 = any width failed.
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\snapcdc\run_tb_snap_cdc.bat'
REM   bat rules: ASCII only + CRLF.
REM ---------------------------------------------------------------------------
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set BAD=0
REM evidence freshness: record hashes of the exact sources used (same as sim/fifoasync)
certutil -hashfile "%ROOT%\rtl\snap_cdc.v" SHA256 > "%~dp0fingerprint.txt"
certutil -hashfile "%ROOT%\tb\tb_snap_cdc.v" SHA256 >> "%~dp0fingerprint.txt"
echo run at %DATE% %TIME% >> "%~dp0fingerprint.txt"
echo ================= snap_cdc gate: 5 widths (14/22/24/32/36) =================
echo ================= NW=14 (REAL: SNAP_FE_NW, -d TB_NW_14) =================
call :one 14
if errorlevel 1 (echo NW14-FAIL & set BAD=1)
echo ================= NW=22 (REAL: SNAP_DP_NW, -d TB_NW_22) =================
call :one 22
if errorlevel 1 (echo NW22-FAIL & set BAD=1)
echo ================= NW=24 (legacy P6e word count, -d TB_NW_24) =============
call :one 24
if errorlevel 1 (echo NW24-FAIL & set BAD=1)
echo ================= NW=32 (legacy P6b v1 estimate, -d TB_NW_32) ============
call :one 32
if errorlevel 1 (echo NW32-FAIL & set BAD=1)
echo ================= NW=36 (REAL: SNAP_NW_P6E whole window, -d TB_NW_36) ====
call :one 36
if errorlevel 1 (echo NW36-FAIL & set BAD=1)
echo ===================================================================
if "%BAD%"=="1" (echo SNAP_CDC_GATE_ALL: FAIL & exit /b 1)
echo SNAP_CDC_GATE_ALL: OK (NW=14/22/24/32/36 all PASS_ALL)
exit /b 0

REM ---------------------------------------------------------------------------
REM :one <W> -- build+run the TB at NW=<W>; raw log kept as gate_nw<W>.txt
REM ---------------------------------------------------------------------------
:one
set W=%1
set /a NBW=%W%*32
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d TB_NW_%W% %ROOT%\rtl\snap_cdc.v %ROOT%\tb\tb_snap_cdc.v > xvlog_nw%W%.log 2>&1 || (type xvlog_nw%W%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_nw%W%.log 2>&1 || (type xvlog_nw%W%.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_nw%W%.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_nw%W%.log & exit /b 1)
findstr /C:"10-3091" xvlog_nw%W%.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_nw%W%.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_snap_cdc xil_defaultlib.glbl -s tb_snap_cdc -log xelab_nw%W%.log > NUL 2>&1 || (type xelab_nw%W%.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_nw%W%.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_nw%W%.log & exit /b 1)
call %XV%\xsim.bat tb_snap_cdc -runall -log xsim_nw%W%.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"WARN" /C:"INFO" /C:"TIMEOUT" xsim_nw%W%.log
REM keep a committable copy of the RAW log (sim/**/*.log is gitignored; .txt is not)
if exist "%~dp0fingerprint.txt" copy /y "%~dp0fingerprint.txt" "%~dp0gate_nw%W%.txt" > NUL
type xsim_nw%W%.log >> "%~dp0gate_nw%W%.txt"
REM ---- printed size MUST equal measured size ----
findstr /C:"TB_NW_SEL: NW=%W% NB=%NBW% MACRO=TB_NW_%W%" xsim_nw%W%.log >NUL || (echo NW%W%-ECHO-MISMATCH-FAIL: TB did not really run at NW=%W% & exit /b 1)
findstr /C:"TB_NW_SEL-WARN" xsim_nw%W%.log >NUL && (echo NW%W%-ECHO-MISMATCH-FAIL: TB fell back to the default width & exit /b 1)
REM ---- excitation self-consistency (skew scaling) must be OK ----
findstr /C:"SKEW_SELFTEST: NW=%W% " xsim_nw%W%.log | findstr /C:"VERDICT=OK" >NUL || (echo NW%W%-SKEW-SELFTEST-FAIL & exit /b 1)
findstr /C:"PASS_ALL" xsim_nw%W%.log >NUL || (echo NW%W%-PASS_ALL-MISSING & exit /b 1)
echo NW%W%-OK
exit /b 0
