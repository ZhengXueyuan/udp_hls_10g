@echo off
REM run_tb_app_udp.bat -- P5e-T3/T4 UDP demo app unit gate (self-checking TB, no Python)
REM chain: TB UDP frame stream -> udp_split -> app_udp_pattern (RX verify)
REM        udp_split.meta_* -> udp_tx_cfg.peer_wr (learn-on-RX) -> TX -> udp_tx_frame
REM        -> tx_arb -> capture.
REM usage: run_tb_app_udp.bat [pos|splitoff|portout|badcrc|nopeer]
REM exit 0 only when the TB prints "P5E UDP APP GATE: OK ...".
REM NOTE: keep this file ASCII-only (UTF-8 Chinese in REM lines breaks the GBK console
REM and the comment tail gets executed as a command -- project bat pitfall).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

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
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\checksum16.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\slow_rx_adp.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\tx_arb.v ^
  %RTL%\app_udp_pattern.v ^
  %TB%\tb_app_udp.v > xvlog_ua.log 2>&1 || (type xvlog_ua.log & exit /b 1)
findstr /I /C:"implicit" xvlog_ua.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"implicit" xvlog_ua.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ua.log 2>&1 || (type xvlog_ua.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_app_udp xil_defaultlib.glbl -s tb_app_udp -log xelab_ua.log > NUL 2>&1 || (type xelab_ua.log & exit /b 1)
findstr /I /C:"implicit" xelab_ua.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I /C:"implicit" xelab_ua.log & exit /b 1)
call %XV%\xsim.bat tb_app_udp -runall %TPA% -log xsim_ua_%MODE%.log > NUL 2>&1 || (type xsim_ua_%MODE%.log & exit /b 1)

findstr /C:"P5E UDP APP GATE: OK" xsim_ua_%MODE%.log > NUL
if errorlevel 1 (echo ---- FAIL detail [%MODE%]: & findstr /C:"FAIL" xsim_ua_%MODE%.log & exit /b 1)
findstr /C:"P5E UDP APP GATE" xsim_ua_%MODE%.log
exit /b 0
