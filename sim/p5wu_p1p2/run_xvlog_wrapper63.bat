@echo off
REM ===========================================================================
REM run_xvlog_wrapper63.bat -- P7B-WU compile-face gate for board/wrapper_p4.v
REM   (same shape as _proj_10g\notes\p7b_biz_win\run_xvlog_wrapper.bat, whose
REM    fingerprint check pins SNAP_NW_P6E = 61 => it would refuse this version;
REM    this copy pins 63 and writes into sim\p5wu_p1p2\work_xvlog.)
REM
REM   Scope: syntax + "declared before use" (VRFC 10-2989 expression form).
REM   NOT covered: undeclared nets in expression form are LEGAL Verilog (a typo in
REM   the new bundle compiles silently) => see check_wu_words.py (targeted scan of
REM   the W61/W62 wiring) + check_window.py (assembly structure).
REM   Also NOT covered: port-connection silent truncation (VRFC 10-3091) -- that
REM   face needs xelab/synth over the full IP set (the round's unified build).
REM   All comments in this .bat are ASCII on purpose (project rule).
REM
REM   4 macro combos, all must compile:
REM     1  (none)                       K7/P4 default build
REM     2  P7B_10G
REM     3  APP_MODE
REM     4  APP_MODE P7B_10G PCIE_OBS DEV_USP DP_156MHZ UDP_TX_OVL   = P7B-WU real
REM ===========================================================================
setlocal enabledelayedexpansion
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=%~dp0..\..\.
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set W=%~dp0work_xvlog
if not exist "%ROOT%\board\wrapper_p4.v" ( echo [PATHGUARD FAIL] no wrapper_p4.v under %ROOT% & exit /b 90 )
if not exist "%XV%\xvlog.bat" ( echo [TOOL FAIL] no xvlog.bat & exit /b 91 )
if not exist "%W%" mkdir "%W%"
set SRCFILE=%ROOT%\board\wrapper_p4.v
findstr /C:"SNAP_NW_P6E = 63" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 63-word version & exit /b 92 )

set NBAD=0
call :one "d0_default"      ""
call :one "d1_p7b"          "-d P7B_10G"
call :one "d2_app"          "-d APP_MODE"
call :one "d3_wu_full"      "-d APP_MODE -d P7B_10G -d PCIE_OBS -d DEV_USP -d DP_156MHZ -d UDP_TX_OVL"

echo.
if %NBAD% NEQ 0 ( echo XVLOG_WRAPPER63_FAIL %NBAD% & exit /b 1 )
echo XVLOG_WRAPPER63_PASS 4/4
exit /b 0

:one
set TAG=%~1
set DEFS=%~2
set LOG=%W%\xvlog_%TAG%.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%SRCFILE%" > "%LOG%" 2>&1
set RC=%ERRORLEVEL%
set HIT=0
findstr /I /C:"VRFC 10-2989" /C:"not declared" /C:"ERROR:" "%LOG%" >NUL && set HIT=1
if "%RC%" NEQ "0" set HIT=1
if "%HIT%"=="1" ( echo [FAIL] %TAG% rc=%RC% & type "%LOG%" & set /a NBAD+=1 ) else ( echo [OK  ] %TAG% rc=0 )
exit /b 0
