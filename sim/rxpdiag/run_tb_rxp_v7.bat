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

REM run_tb_rxp_v7.bat -- RXP_DIAG v7 FUNCTIONAL gate.
REM   A: rtl/udp_rx.v IP-identification sequence checker (IV/IS/IA/IB/IW)
REM   B: rtl/udp_split.v v6 section: "IPv4/UDP only" gate + NB (skipped bytes)
REM (ISSUE_RX_BYTE_CORRUPTION sections 18.14 / 18.15 / 18.16)
REM Drives real IPv4/UDP frames through udp_split (real player + real rollback)
REM into app_udp_pattern (real checker), then asserts:
REM   A-part (udp_rx, v7_id_*):
REM     - P1 positive: consecutive ids then ONE jump => IV=1 IS=4 and the
REM       latched {IA,IB} == the constructed pair, bit for bit; the payload
REM       checkers must stay clean (the ID test is orthogonal to corruption)
REM     - P2 zero: strictly +1 (6 frames) => IV=0 IW=0 while IS=6 and
REM       v6_cnt == 6*1472 (anti-dead-zero)
REM     - P3 field position / byte order: the two ids are byte-swaps of each
REM       other (0xA5C3 / 0x3C5A) => IA/IB must decode to the constructed
REM       values; P3b (0x3C5A -> 0x3C5B) must be clean in the SAME domain
REM     - P4 scope: a NON-matching UDP frame between two matching ones must
REM       not participate (IS=2, IV=0; "all frames" would give IS=3, IV=2)
REM   B-part (udp_split, v7_nb):
REM     - P5: ICMP + ARP frames whose payload is the BITWISE COMPLEMENT of the
REM       expected pattern (guaranteed mismatch if compared) => CM=0 CZ=0 CV=0
REM       and NB == the skipped byte count exactly; the following UDP frame
REM       must still be clean (the LFSR must not have been pushed out of phase)
REM     - P6: clean data frames + a trailing non-UDP frame (the exact shape of
REM       the 100 Mbps board round, where CM was 560) => CM=0 while NB == 560
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
  tb_rxp_v7.v > xvlog_v7.log 2>&1 || (type xvlog_v7.log & exit /b 1)
findstr /I /C:"implicit" xvlog_v7.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"implicit" xvlog_v7.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_v7.log > warn_v7.txt
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_v7.log 2>&1 || (type xvlog_v7.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rxp_v7 xil_defaultlib.glbl -s tb_rxp_v7 -log xelab_v7.log > NUL 2>&1 || (type xelab_v7.log & exit /b 1)
findstr /I /C:"implicit" xelab_v7.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"implicit" xelab_v7.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_v7.log >> warn_v7.txt

call %XV%\xsim.bat tb_rxp_v7 -runall -log xsim_v7.log > NUL 2>&1
type xsim_v7.log | findstr /C:"RXPV7" /C:"RXP-V7 GATE" /C:"FAIL"
findstr /C:"RXP-V7 GATE: OK" xsim_v7.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
