@echo off
REM run_tb_udprx.bat -- independent high-load RX byte-fidelity gate (tb_udprx_rate.v)
REM usage: run_tb_udprx.bat PLEN-WSP-NFRM-IPG   (default 1472-8-200-12)
REM   1472-8-200-12   = board line-rate word cadence (1 word / 8 cyc) + 12 cyc IPG
REM   1472-8-200-0    = pure back-to-back at line rate (no IPG)
REM   1472-27-200-0   = ~400 Mbps equivalent (1 word / 27 cyc)
REM   1472-1-200-0    = 1 word/cycle = 8x line rate (FIFO stress)
REM   1473-8-200-12   = non-8B-aligned payload (frame tail offset 1)
REM   1480-8-200-12   = payload ends one full word past a word boundary
REM Own xsim.dir (project rule 7). ASCII only (GBK console).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

set CFG=%1
if "%CFG%"=="" set CFG=1472-8-200-12
for /f "tokens=1-4 delims=-" %%a in ("%CFG%") do set PL=%%a& set WS=%%b& set NF=%%c& set IG=%%d
if "%PL%"=="" set PL=1472
if "%WS%"=="" set WS=8
if "%NF%"=="" set NF=200
if "%IG%"=="" set IG=12

set DM=
if "%PL%"=="512"  set DM=%DM% -d PL512
if "%PL%"=="996"  set DM=%DM% -d PL996
if "%PL%"=="1471" set DM=%DM% -d PL1471
if "%PL%"=="1473" set DM=%DM% -d PL1473
if "%PL%"=="1480" set DM=%DM% -d PL1480
if "%WS%"=="1"    set DM=%DM% -d WSP1
if "%WS%"=="2"    set DM=%DM% -d WSP2
if "%WS%"=="4"    set DM=%DM% -d WSP4
if "%WS%"=="16"   set DM=%DM% -d WSP16
if "%WS%"=="27"   set DM=%DM% -d WSP27
if "%NF%"=="8"    set DM=%DM% -d NFRM8
if "%NF%"=="64"   set DM=%DM% -d NFRM64
if "%NF%"=="1000" set DM=%DM% -d NFRM1000
if "%IG%"=="0"    set DM=%DM% -d NOIPG
echo [run_tb_udprx] cfg=%CFG% defines=%DM%

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DM% ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\udp_rx.v ^
  %RTL%\udp_split.v %RTL%\app_udp_pattern.v ^
  %TB%\tb_udprx_rate.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"implicit" xvlog_run.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire: & findstr /I /C:"implicit" xvlog_run.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver %DM% xil_defaultlib.tb_udprx_rate xil_defaultlib.glbl -s tb_udprx_run -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)

call %XV%\xsim.bat tb_udprx_run -runall -log xsim_run.log > NUL 2>&1
findstr /C:"UDPRX RATE GATE" xsim_run.log > NUL
if errorlevel 1 (type xsim_run.log & exit /b 1)
findstr /C:"[cfg]" xsim_run.log
findstr /C:"[dbg]" xsim_run.log
findstr /C:"[FAIL]" xsim_run.log
findstr /C:"UDPRX RATE GATE" xsim_run.log
findstr /C:"UDPRX RATE GATE: OK" xsim_run.log > NUL
if errorlevel 1 exit /b 1
exit /b 0
