@echo off
REM run_t2.bat - review scratch: cycle-by-cycle trace when requests stop (own sim dir)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\snap_cdc.v tb_t2.v > xvlog_t2.log 2>&1 || (type xvlog_t2.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_t2 -s tb_t2 -log xelab_t2.log > NUL 2>&1 || (type xelab_t2.log & exit /b 1)
call %XV%\xsim.bat tb_t2 -runall -log xsim_t2.log > NUL 2>&1
type xsim_t2.log
