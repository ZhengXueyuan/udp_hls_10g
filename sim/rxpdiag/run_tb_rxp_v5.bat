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

REM run_tb_rxp_v5.bat -- RXP_DIAG v5 write-side (din) LFSR checker + parser-counter
REM FUNCTIONAL gate (ISSUE_RX_BYTE_CORRUPTION section 14.6 / 18.8).
REM Drives real IPv4/UDP frames through udp_split (real player + real rollback)
REM into app_udp_pattern (real checker), then asserts:
REM   A-part (udp_split, on the u_uf write data port): DV/DG/DE/DO/DM/VZ
REM     - one positive phase per field with a KNOWN injected byte (exact values),
REM     - a clean phase where DM and VZ must stay 0 while the byte counter
REM       (hierarchical v5_cnt) must equal the number of bytes fed -- so the
REM       zeros are "ran and saw nothing", not "dead checker",
REM     - DV == app ds_idx and DM == app stat_mismatch on the SAME injection
REM       (this is the dynamic proof that both LFSRs agree byte by byte).
REM   B-part (udp_split's udp_rx counters, previously dangling/unused):
REM     PS/NM/IC/DC/SB -- positive and zero phase each.
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
  tb_rxp_v5.v > xvlog_v5.log 2>&1 || (type xvlog_v5.log & exit /b 1)
findstr /I /C:"implicit" xvlog_v5.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"implicit" xvlog_v5.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_v5.log > warn_v5.txt
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_v5.log 2>&1 || (type xvlog_v5.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rxp_v5 xil_defaultlib.glbl -s tb_rxp_v5 -log xelab_v5.log > NUL 2>&1 || (type xelab_v5.log & exit /b 1)
findstr /I /C:"implicit" xelab_v5.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"implicit" xelab_v5.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_v5.log >> warn_v5.txt

call %XV%\xsim.bat tb_rxp_v5 -runall -log xsim_v5.log > NUL 2>&1
type xsim_v5.log | findstr /C:"RXPV5" /C:"RXP-V5 GATE" /C:"FAIL"
findstr /C:"RXP-V5 GATE: OK" xsim_v5.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
