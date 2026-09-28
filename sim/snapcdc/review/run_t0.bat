@echo off
REM run_t0.bat - review scratch: measure real round-trip time of snap_cdc (own sim dir)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\snap_cdc.v tb_t0.v > xvlog_t0.log 2>&1 || (type xvlog_t0.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_t0 -s tb_t0 -log xelab_t0.log > NUL 2>&1 || (type xelab_t0.log & exit /b 1)
call %XV%\xsim.bat tb_t0 -runall -log xsim_t0.log > NUL 2>&1
findstr /C:"flip" /C:"update" /C:"valid #" /C:"[t]" /C:"===" /C:"TIMEOUT" xsim_t0.log
