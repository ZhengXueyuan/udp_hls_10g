@echo off
REM debug run
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
call %XV%\xvlog.bat -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\udp_rx.v %RTL%\udp_split.v %TB%\tb_udp_split.v > xvlog_dbg.log 2>&1 || exit /b 1
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_dbg.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_udp_split xil_defaultlib.glbl -s tb_dbg -log xelab_dbg.log > NUL 2>&1 || exit /b 1
call %XV%\xsim.bat tb_dbg -runall -log xsim_dbg.log -testplusarg DBG > NUL 2>&1
exit /b 0
