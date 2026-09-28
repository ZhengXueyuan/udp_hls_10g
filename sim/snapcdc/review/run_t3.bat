@echo off
REM run_t3.bat - review scratch: flip/update pairing diagnostic (own sim dir)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\snap_cdc.v tb_t3.v > xvlog_t3.log 2>&1 || (type xvlog_t3.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_t3 -s tb_t3 -log xelab_t3.log > NUL 2>&1 || (type xelab_t3.log & exit /b 1)
call %XV%\xsim.bat tb_t3 -runall -log xsim_t3.log > NUL 2>&1
findstr /C:"[t]" /C:"!!" /C:"PAIR" /C:"结果" /C:"---" /C:"===" /C:"TIMEOUT" xsim_t3.log
