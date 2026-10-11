@echo off
REM ===========================================================================
REM run_xvlog_wrapper.bat -- P7B-BIZ compile-face gate for board/wrapper_p4.v
REM
REM   Scope: syntax + "declared before use" (VRFC 10-2989 expression form).
REM   NOT covered: undeclared nets in expression form are LEGAL Verilog (measured:
REM   a typo in the new bundle compiled silently) => see check_window.py, which does
REM   a declared-before-use scan over the edited regions. Also NOT covered:
REM   port-connection silent truncation (VRFC 10-3091) -- that face
REM   needs xelab/synth over the full IP set, which is the round's unified build.
REM   All comments in this .bat are ASCII on purpose (project rule).
REM
REM   4 macro combos, all must compile:
REM     1  (none)                       K7/P4 default build
REM     2  P7B_10G
REM     3  APP_MODE
REM     4  APP_MODE P7B_10G PCIE_OBS DEV_USP DP_156MHZ UDP_TX_OVL   = P7B-BIZ real
REM
REM   Self-locating: repo root from %~dp0; unresolvable => hard fail (never
REM   compile another checkout silently -- the "vacuum gate" defect).
REM ===========================================================================
setlocal enabledelayedexpansion
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=%~dp0..\..\..
set W=%~dp0work_xvlog
if not exist "%ROOT%\board\wrapper_p4.v" ( echo [PATHGUARD FAIL] no wrapper_p4.v under %ROOT% & exit /b 90 )
if not exist "%XV%\xvlog.bat" ( echo [TOOL FAIL] no xvlog.bat & exit /b 91 )
if not exist "%W%" mkdir "%W%"
set SRCFILE=%ROOT%\board\wrapper_p4.v
REM 2026-10-10 (P7B-GAP9-TX): fingerprint 61 -> 65. NOTE: it had already gone stale at
REM   63 (P7B-WU round) => this gate was DEAD (exit 92) ever since; kept as a fingerprint,
REM   only the expected value is bumped.
findstr /C:"SNAP_NW_P6E = 71" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 71-word version & exit /b 92 )

set NBAD=0
call :one "d0_default"      ""
call :one "d1_p7b"          "-d P7B_10G"
call :one "d2_app"          "-d APP_MODE"
call :one "d3_biz_full"     "-d APP_MODE -d P7B_10G -d PCIE_OBS -d DEV_USP -d DP_156MHZ -d UDP_TX_OVL"

echo.
if %NBAD% NEQ 0 ( echo XVLOG_WRAPPER_FAIL %NBAD% & exit /b 1 )
echo XVLOG_WRAPPER_PASS 4/4
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
