@echo off
REM run_torture.bat - review scratch: torture gate for snap_cdc (own sim dir, read-only review)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\snap_cdc.v tb_torture.v > xvlog_tor.log 2>&1 || (type xvlog_tor.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_tor.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_tor.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_torture -s tb_torture -log xelab_tor.log > NUL 2>&1 || (type xelab_tor.log & exit /b 1)
call %XV%\xsim.bat tb_torture -runall -log xsim_tor.log > NUL 2>&1
findstr /C:"TOR_PASS" /C:"TOR_FAIL" /C:"FAIL" /C:"INFO" /C:"ok" /C:"TIMEOUT" xsim_tor.log
