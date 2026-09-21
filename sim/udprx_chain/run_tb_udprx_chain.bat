@echo off
REM run_tb_udprx_chain.bat -- RX chain gate: GMII -> mac_rx_64 -> rx_classify
REM                           -> udp_split -> app_udp_pattern (tb_udprx_chain.v)
REM usage: run_tb_udprx_chain.bat PLEN-NFRM-IDLE   (default 1472-200-12)
REM   1472-200-12  = board line rate (1 byte/cycle, 12B IFG), MTU frames
REM   1472-200-64  = ~700 Mbps average (bursts at line rate)
REM   1472-200-120 = ~400 Mbps average
REM   512-200-12   = small payload
REM   1473-200-12  = non-8B-aligned payload
REM Own xsim.dir (project rule 7). ASCII only (GBK console).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

set CFG=%1
if "%CFG%"=="" set CFG=1472-200-12
for /f "tokens=1-3 delims=-" %%a in ("%CFG%") do set PL=%%a& set NF=%%b& set ID=%%c
if "%PL%"=="" set PL=1472
if "%NF%"=="" set NF=200
if "%ID%"=="" set ID=12

set DM=
if "%PL%"=="512"  set DM=%DM% -d PL512
if "%PL%"=="996"  set DM=%DM% -d PL996
if "%PL%"=="1473" set DM=%DM% -d PL1473
if "%NF%"=="8"    set DM=%DM% -d NFRM8
if "%NF%"=="64"   set DM=%DM% -d NFRM64
if "%ID%"=="64"   set DM=%DM% -d IDL64
if "%ID%"=="120"  set DM=%DM% -d IDL120
echo [run_tb_udprx_chain] cfg=%CFG% defines=%DM%

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DM% ^
  %RTL%\fifo_sync.v %RTL%\crc32_8b.v %RTL%\frame_fifo.v %RTL%\udp_rx.v ^
  %RTL%\mac_rx_64.v %RTL%\rx_classify.v %RTL%\udp_split.v %RTL%\app_udp_pattern.v ^
  %TB%\tb_udprx_chain.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"implicit" xvlog_run.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire: & findstr /I /C:"implicit" xvlog_run.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver %DM% xil_defaultlib.tb_udprx_chain xil_defaultlib.glbl -s tb_udprx_chain_run -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)

call %XV%\xsim.bat tb_udprx_chain_run -runall -log xsim_run.log > NUL 2>&1
findstr /C:"UDPRX CHAIN GATE" xsim_run.log > NUL
if errorlevel 1 (type xsim_run.log & exit /b 1)
findstr /C:"[cfg]" xsim_run.log
findstr /C:"[dbg]" xsim_run.log
findstr /C:"[AMM]" xsim_run.log
findstr /C:"[MMM]" xsim_run.log
findstr /C:"[FAIL]" xsim_run.log
findstr /C:"UDPRX CHAIN GATE" xsim_run.log
findstr /C:"UDPRX CHAIN GATE: OK" xsim_run.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
