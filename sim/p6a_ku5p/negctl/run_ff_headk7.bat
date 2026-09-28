@echo off
@echo off
REM negctl frame_fifo: frame_fifo_head.v + tb_frame_fifo.v
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\sim\p6a_ku5p\negctl\frame_fifo_head.v %ROOT%\tb\tb_frame_fifo.v > xvlog_headk7.log 2>&1 || (type xvlog_headk7.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib %XV%\..\data\verilog\src\glbl.v >> xvlog_headk7.log 2>&1 || (type xvlog_headk7.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_frame_fifo xil_defaultlib.glbl -s tb_ff_headk7 -log xelab_headk7.log > NUL 2>&1 || (type xelab_headk7.log & exit /b 1)
call %XV%\xsim.bat tb_ff_headk7 -runall -log xsim_headk7.log > NUL 2>&1
findstr /C:"PASS_ALL" /C:"FAIL" /C:"FATAL" /C:"TIMEOUT" xsim_headk7.log
