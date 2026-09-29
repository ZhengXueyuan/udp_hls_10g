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

REM run_tb_rxp_v6.bat -- RXP_DIAG v6 FUNCTIONAL gate: the THIRD LFSR byte
REM checker, on the INPUT PORT SIDE of udp_split (the stream entering u_pre).
REM (ISSUE_RX_BYTE_CORRUPTION sections 18.9 / 18.10 / 18.13)
REM Drives real IPv4/UDP frames through udp_split (real player + real
REM rollback) into app_udp_pattern (real checker), then asserts:
REM   A-part (udp_split, v6_*): CV/CG/CE/CO/CM/CZ/CS
REM     - V1 positive: one KNOWN injected byte => exact CV/CG/CE/CO, CO == CV%paylen
REM     - V1/V3b/V4/V5/V6 cross-anchor: CV == app ds_idx AND == v5 DV,
REM       CM == app stat_mismatch AND == v5 DM (three independent mechanisms)
REM     - V2 zero: CM=0 CZ=0 while hierarchical v6_cnt == 4*1472 (not a dead zero)
REM     - V3 42-byte skip boundary (frame bytes 41/42/43 with known values)
REM     - V4 partial tail word (paylen 1471, 1-byte last word)
REM     - V5/V6 two mismatches: same engine phase and cross-phase
REM     - V7 over-speed (back-to-back words): CS MUST go non-zero (live indicator)
REM ASCII-only + CRLF (project bat rules).
REM NOTE: never redirect to xvlog.log / xelab.log (the tools' own default log
REM names; holding them open fails with a misleading 'directory not writable').
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d RXP_DIAG ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\udp_rx.v %RTL%\udp_split.v ^
  %RTL%\app_udp_pattern.v ^
  tb_rxp_v6.v > xvlog_v6.log 2>&1 || (type xvlog_v6.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_v6.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_v6.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_v6.log > warn_v6.txt
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_v6.log 2>&1 || (type xvlog_v6.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rxp_v6 xil_defaultlib.glbl -s tb_rxp_v6 -log xelab_v6.log > NUL 2>&1 || (type xelab_v6.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_v6.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_v6.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_v6.log >> warn_v6.txt

call %XV%\xsim.bat tb_rxp_v6 -runall -log xsim_v6.log > NUL 2>&1
type xsim_v6.log | findstr /C:"RXPV6" /C:"RXP-V6 GATE" /C:"FAIL"
findstr /C:"RXP-V6 GATE: OK" xsim_v6.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
