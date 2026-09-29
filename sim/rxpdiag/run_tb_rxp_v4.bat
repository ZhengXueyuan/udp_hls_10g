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

REM run_tb_rxp_v4.bat -- RXP_DIAG v4 exception-path-counter + run-structure FUNCTIONAL gate.
REM (ISSUE_RX_BYTE_CORRUPTION) Drives real IPv4/UDP frames through udp_split
REM (real player + real frame_fifo rollback) into app_udp_pattern (real checker),
REM then asserts the v4 counters by PHASE DELTA (they are round-cumulative):
REM   A-part (udp_split): CN/RD/NC/NP/WF/RL/WC  -- one positive phase each
REM                       plus a clean phase where every one of them must stay 0.
REM   B-part (app):       NE/NR/MR/EN/EO/QA..QH -- isolated vs contiguous runs,
REM                       event-FIFO enqueue + overflow (EO flagged, not silent).
REM ASCII-only + CRLF (project bat rules).
REM NOTE: never redirect to xvlog.log / xelab.log (the tools' own default log
REM names; holding them open fails with a misleading 'directory not writable').
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d RXP_DIAG ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\udp_rx.v %RTL%\udp_split.v ^
  %RTL%\app_udp_pattern.v ^
  tb_rxp_v4.v > xvlog_v4.log 2>&1 || (type xvlog_v4.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_v4.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_v4.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_v4.log > warn_v4.txt
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_v4.log 2>&1 || (type xvlog_v4.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rxp_v4 xil_defaultlib.glbl -s tb_rxp_v4 -log xelab_v4.log > NUL 2>&1 || (type xelab_v4.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_v4.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_v4.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_v4.log >> warn_v4.txt

call %XV%\xsim.bat tb_rxp_v4 -runall -log xsim_v4.log > NUL 2>&1
type xsim_v4.log | findstr /C:"RXPV4" /C:"RXP-V4 GATE" /C:"FAIL"
findstr /C:"RXP-V4 GATE: OK" xsim_v4.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
