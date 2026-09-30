@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\XCKU5PMini\udp_hls_10g\rtl
cd /d %~dp0\run_dbg
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d UDP_TX_OVL "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\udp_tx_frame.v" "%~dp0tb_ovl_dbg.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_ovl_dbg -s tb_ovl_dbg -log xelab_tb.log > NUL 2>&1 || (type xelab_tb.log & exit /b 1)
call %XV%\xsim.bat tb_ovl_dbg -runall -log xsim.log > NUL 2>&1
type xsim.log
exit /b 0
