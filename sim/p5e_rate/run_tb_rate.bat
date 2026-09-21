@echo off
REM run_tb_rate.bat -- app UDP TX path line-rate measurement gate (P5f)
REM chain: app_udp_pattern -> udp_tx_cfg -> udp_tx_frame -> mac_tx_64 (no tx_arb)
REM usage: run_tb_rate.bat [cfg]      cfg in {g0,g1380,g2760,g5000,g58000} x {p1472,p996,p512}
REM        examples: run_tb_rate.bat g0p1472 (default) / g0p996 / g58000p1472
REM NOTE: keep this file ASCII-only (GBK console chokes on UTF-8 in REM lines).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

set CFG=%1
if "%CFG%"=="" set CFG=g0p1472
set DM=
set DPL=
echo %CFG% | findstr /I /C:"g58000" > NUL && set DM=-d GAP58000
echo %CFG% | findstr /I /C:"g5000"  > NUL && set DM=-d GAP5000
echo %CFG% | findstr /I /C:"g2760"  > NUL && set DM=-d GAP2760
echo %CFG% | findstr /I /C:"g1380"  > NUL && set DM=-d GAP1380
echo %CFG% | findstr /I /C:"p996"   > NUL && set DPL=-d PL996
echo %CFG% | findstr /I /C:"p512"   > NUL && set DPL=-d PL512

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DM% %DPL% ^
  %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\crc32_8b.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\mac_tx_64.v ^
  %RTL%\app_udp_pattern.v ^
  %TB%\tb_app_udp_rate.v > xvlog_%CFG%.log 2>&1 || (type xvlog_%CFG%.log & exit /b 1)
findstr /I /C:"implicit" xvlog_%CFG%.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"implicit" xvlog_%CFG%.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver %DM% %DPL% xil_defaultlib.tb_app_udp_rate -s tb_rate_%CFG% -log xelab_%CFG%.log > NUL 2>&1 || (type xelab_%CFG%.log & exit /b 1)
findstr /I /C:"implicit" xelab_%CFG%.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I /C:"implicit" xelab_%CFG%.log & exit /b 1)

call %XV%\xsim.bat tb_rate_%CFG% -runall -log xsim_%CFG%.log > NUL 2>&1
findstr /C:"RATE TB DONE" xsim_%CFG%.log > NUL
if errorlevel 1 (echo RATE TB DID NOT FINISH & type xsim_%CFG%.log & exit /b 1)
findstr /C:"[pre" xsim_%CFG%.log & findstr /C:"--- tb_app_udp_rate" xsim_%CFG%.log
findstr /C:"frames on wire" xsim_%CFG%.log
findstr /C:"mean frame period" xsim_%CFG%.log
findstr /C:"mean wire len" xsim_%CFG%.log
findstr /C:"PAYLOAD RATE" xsim_%CFG%.log
findstr /C:"WIRE RATE" xsim_%CFG%.log
findstr /C:"app tx_frames" xsim_%CFG%.log
exit /b 0
