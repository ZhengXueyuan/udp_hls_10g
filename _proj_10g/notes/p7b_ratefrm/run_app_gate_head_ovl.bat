@echo off
set "REPO_ROOT=D:\repo\XCKU5PMini\udp_hls_10g"
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

REM run_tb_app_udp.bat -- P5e-T3/T4 UDP demo app unit gate (self-checking TB, no Python)
REM chain: TB UDP frame stream -> udp_split -> app_udp_pattern (RX verify)
REM        udp_split.meta_* -> udp_tx_cfg.peer_wr (learn-on-RX) -> TX -> udp_tx_frame
REM        -> tx_arb -> capture.
REM usage: run_tb_app_udp.bat [pos|splitoff|portout|badcrc|nopeer]
REM exit 0 only when the TB prints "P5E UDP APP GATE: OK ...".
REM NOTE: keep this file ASCII-only (UTF-8 Chinese in REM lines breaks the GBK console
REM and the comment tail gets executed as a command -- project bat pitfall).
cd /d %~dp0\run_app_ovl
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb

set MODE=%1
if "%MODE%"=="" set MODE=pos
set TPA=
if /i "%MODE%"=="splitoff" set TPA=-testplusarg SPLITOFF
if /i "%MODE%"=="portout"  set TPA=-testplusarg PORTOUT
if /i "%MODE%"=="badcrc"   set TPA=-testplusarg BADCRC
if /i "%MODE%"=="nopeer"   set TPA=-testplusarg NOPEER
REM neglearn: P5d-style negative control -- peer learn source tied to 0
REM (reproduces the T2 config where UDP can never learn a peer).
REM EXPECTED RESULT: gate FAILS (exit 1). A pass here means the positive
REM criteria are not actually gated by learn-on-RX => zero discriminating power.
if /i "%MODE%"=="neglearn" set TPA=-testplusarg NEGLEARN

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d UDP_TX_OVL ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\checksum16.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\slow_rx_adp.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\tx_arb.v ^
  %HERE%\scratch\app_udp_pattern_head.v ^
  %TB%\tb_app_udp.v > xvlog_ua.log 2>&1 || (type xvlog_ua.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_ua.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_ua.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ua.log 2>&1 || (type xvlog_ua.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_app_udp xil_defaultlib.glbl -s tb_app_udp -log xelab_ua.log > NUL 2>&1 || (type xelab_ua.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ua.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ua.log & exit /b 1)
call %XV%\xsim.bat tb_app_udp -runall %TPA% -log xsim_ua_%MODE%.log > NUL 2>&1 || (type xsim_ua_%MODE%.log & exit /b 1)

findstr /C:"P5E UDP APP GATE: OK" xsim_ua_%MODE%.log > NUL
if errorlevel 1 (echo ---- FAIL detail [%MODE%]: & findstr /C:"FAIL" xsim_ua_%MODE%.log & exit /b 1)
findstr /C:"P5E UDP APP GATE" xsim_ua_%MODE%.log
exit /b 0
