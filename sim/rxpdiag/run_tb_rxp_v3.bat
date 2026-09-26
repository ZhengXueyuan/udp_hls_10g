@echo off
REM run_tb_rxp_v3.bat -- RXP_DIAG v3 frame-boundary accounting FUNCTIONAL gate.
REM (ISSUE_RX_BYTE_CORRUPTION) Drives real IPv4/UDP frames through udp_split
REM (real player + real frame_fifo rollback) into app_udp_pattern (real checker
REM + ds_cap), then asserts the v3 snapshot fields against the TB's own
REM interface-side model (app RX handshake beat counts + known frame geometry).
REM ASCII-only + CRLF (project bat rules).
REM NOTE: never redirect to xvlog.log / xelab.log (the tools' own default log
REM names; holding them open fails with a misleading 'directory not writable').
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d RXP_DIAG ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\udp_rx.v %RTL%\udp_split.v ^
  %RTL%\app_udp_pattern.v ^
  tb_rxp_v3.v > xvlog_v3.log 2>&1 || (type xvlog_v3.log & exit /b 1)
findstr /I /C:"implicit" xvlog_v3.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"implicit" xvlog_v3.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_v3.log > warn_v3.txt
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_v3.log 2>&1 || (type xvlog_v3.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rxp_v3 xil_defaultlib.glbl -s tb_rxp_v3 -log xelab_v3.log > NUL 2>&1 || (type xelab_v3.log & exit /b 1)
findstr /I /C:"implicit" xelab_v3.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"implicit" xelab_v3.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_v3.log >> warn_v3.txt

call %XV%\xsim.bat tb_rxp_v3 -runall -log xsim_v3.log > NUL 2>&1
type xsim_v3.log | findstr /C:"RXPV3" /C:"RXP-V3 GATE" /C:"FAIL"
findstr /C:"RXP-V3 GATE: OK" xsim_v3.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
