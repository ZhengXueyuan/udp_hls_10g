@echo off
set "REPO_ROOT=%~dp0..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)
rem --- pathguard tripwire: refuse to run if a LIVE line points outside ---
set "P4PY=C:\Users\zhxue\anaconda3\python.exe"
if exist "%P4PY%" goto :pg_py_ok
set "P4PY="
for %%P in (python.exe) do if not defined P4PY set "P4PY=%%~$PATH:P"
:pg_py_ok
if not defined P4PY goto :pg_sc_done
if not exist "%REPO_ROOT%\sim\p4gates\p4gate.py" goto :pg_sc_done
"%P4PY%" "%REPO_ROOT%\sim\p4gates\p4gate.py" selfcheck --root "%REPO_ROOT%" --bat "%~f0" --quiet || exit /b 1
:pg_sc_done

REM run_tb_rxp_diag.bat -- RXP_DIAG first-mismatch snapshot INSTRUMENT gate.
REM (ISSUE_RX_BYTE_CORRUPTION) Self-check of the diagnostic: clean phase must
REM report zero mismatch; injected phases must report exact idx/got/exp/prev,
REM exact 64-bit got/expected WORD (v2) and exact frame-offset bucket counts
REM (v2). ASCII-only + CRLF (project bat rules).
REM Phase 7 also decodes the app_status_uart line CHARACTER BY CHARACTER in the
REM RXP_DIAG config (470 chars) -- that layout is the only part of the instrument
REM no functional sim otherwise covers (at 9600 baud one line takes 142ms and the
REM full-chain gate only runs ~10ms).
REM NOTE: log files must NOT be named xvlog.log/xelab.log -- those are the tools'
REM own default log names; holding them open via redirection makes the tool fail
REM with CRITICAL WARNING [Common 17-183] 'Failed to open handle xvlog.log'.
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set BD=%REPO_ROOT%\board

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d RXP_DIAG -d APP_MODE ^
  %RTL%\fifo_sync.v %RTL%\app_udp_pattern.v %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v %TB%\tb_rxp_diag.v > xvlog_diag.log 2>&1 || (type xvlog_diag.log & exit /b 1)
findstr /I /C:"implicit" xvlog_diag.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"implicit" xvlog_diag.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_diag.log > warn_diag.txt

call %XV%\xelab.bat -L unisims_ver xil_defaultlib.tb_rxp_diag -s tb_rxp_diag -log xelab_diag.log > NUL 2>&1 || (type xelab_diag.log & exit /b 1)
findstr /I /C:"implicit" xelab_diag.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"implicit" xelab_diag.log & exit /b 1)

call %XV%\xsim.bat tb_rxp_diag -runall -log xsim_diag.log > NUL 2>&1
type xsim_diag.log | findstr /C:"RXPDIAG" /C:"RXP-DIAG GATE" /C:"FAIL"
findstr /C:"RXP-DIAG GATE: OK" xsim_diag.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
