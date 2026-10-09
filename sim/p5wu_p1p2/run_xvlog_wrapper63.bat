@echo off
REM ===========================================================================
REM run_xvlog_wrapper63.bat -- P7B-WU compile-face gate for board/wrapper_p4.v
REM   (same shape as _proj_10g\notes\p7b_biz_win\run_xvlog_wrapper.bat, whose
REM    fingerprint check pins SNAP_NW_P6E = 61 => it would refuse this version;
REM    this copy pins 63 and writes into sim\p5wu_p1p2\work_xvlog.)
REM   2026-10-10 (build C gate-sync round): fingerprint 63 -> 65.  It had already gone
REM      DEAD at the 63->65 transition (exit 92 [FINGERPRINT FAIL] on every run:
REM      the live wrapper reports SNAP_NW_P6E = 65, this gate still looked for 63).
REM      Choice (recorded): keep the gate LIVE and re-pin, exactly like its two
REM      siblings already re-pinned by the GAP9-TX round
REM      (_proj_10g\notes\p7b_biz_win\run_xvlog_wrapper.bat:33  and
REM       _proj_10g\notes\p7b_biz_win\run_tb_biz_win.bat:20, both = "SNAP_NW_P6E = 65");
REM      NOT frozen, because this gate's whole job is the compile face (VRFC 10-2989
REM      "declared before use") of the LIVE wrapper -- freezing it onto a 63-word copy
REM      would turn a live lint guard into a check of an obsolete file.  The filename
REM      keeps the historical "63" (no caller depends on the name; the PASS marker
REM      XVLOG_WRAPPER63_PASS is quoted by notes, so it is left unchanged on purpose).
REM
REM   Scope: syntax + "declared before use" (VRFC 10-2989 expression form).
REM   NOT covered: undeclared nets in expression form are LEGAL Verilog (a typo in
REM   the new bundle compiles silently) => see check_wu_words.py (targeted scan of
REM   the W61/W62 wiring) + check_window.py (assembly structure).
REM   Also NOT covered: port-connection silent truncation (VRFC 10-3091) -- that
REM   face needs xelab/synth over the full IP set (the round's unified build).
REM   All comments in this .bat are ASCII on purpose (project rule).
REM
REM   6 compile arms, all must compile:
REM     A) board/wrapper_p4.v under 4 macro sets:
REM        d0 (none) / d1 P7B_10G / d2 APP_MODE /
REM        d3 APP_MODE P7B_10G PCIE_OBS DEV_USP DP_156MHZ UDP_TX_OVL  = P7B-WU real
REM     B) rtl/tcp_tx_frame.v under 2 of those sets -- it is the file the
REM        DP_156MHZ / TCP_TX_OVL macros actually gate (wrapper_p4.v mentions
REM        TCP_TX_OVL only in comments => a wrapper arm with TCP_TX_OVL defined
REM        would be structurally always-pass = dummy arm, deliberately NOT added):
REM        t3 = d3 defs (DP_156MHZ on, TCP_TX_OVL off)
REM        t4 = d3 + TCP_TX_OVL                          = board build real config
REM        (added 2026-10-07 P7B-RETXFIX r5: before these arms NO standing gate
REM         compiled the board {DP_156MHZ+TCP_TX_OVL} combination --
REM         run_tx_ovl_gate.bat does not define DP_156MHZ.)
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
set TXF=%ROOT%\rtl\tcp_tx_frame.v
findstr /C:"SNAP_NW_P6E = 67" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 67-word version & exit /b 92 )
if not exist "%TXF%" ( echo [PATHGUARD FAIL] no rtl\tcp_tx_frame.v under %ROOT% & exit /b 93 )

set D3=-d APP_MODE -d P7B_10G -d PCIE_OBS -d DEV_USP -d DP_156MHZ -d UDP_TX_OVL

set NBAD=0
call :one "d0_default"      "" "%SRCFILE%"
call :one "d1_p7b"          "-d P7B_10G" "%SRCFILE%"
call :one "d2_app"          "-d APP_MODE" "%SRCFILE%"
call :one "d3_wu_full"      "%D3%" "%SRCFILE%"
call :one "t3_tx_dp"        "%D3%" "%TXF%"
call :one "t4_tx_board"     "%D3% -d TCP_TX_OVL" "%TXF%"

echo.
if %NBAD% NEQ 0 ( echo XVLOG_WRAPPER63_FAIL %NBAD% & exit /b 1 )
echo XVLOG_WRAPPER63_PASS 6/6
exit /b 0

:one
set TAG=%~1
set DEFS=%~2
set SRC=%~3
set LOG=%W%\xvlog_%TAG%.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%SRC%" > "%LOG%" 2>&1
set RC=%ERRORLEVEL%
set HIT=0
findstr /I /C:"VRFC 10-2989" /C:"not declared" /C:"ERROR:" "%LOG%" >NUL && set HIT=1
if "%RC%" NEQ "0" set HIT=1
if "%HIT%"=="1" ( echo [FAIL] %TAG% rc=%RC% & type "%LOG%" & set /a NBAD+=1 ) else ( echo [OK  ] %TAG% rc=0 )
exit /b 0
