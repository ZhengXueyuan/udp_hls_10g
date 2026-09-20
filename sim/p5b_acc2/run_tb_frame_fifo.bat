@echo off
REM run_tb_frame_fifo.bat [frame_fifo_source.v] -- frame_fifo unit test (two-stage:
REM stage1 = sim\retxsim2\frame_fifo_old.v (reg-array RTL), stage2 = rtl\frame_fifo.v (BRAM).
REM Usage: run_tb_frame_fifo.bat <path-to-frame_fifo.v>
cd /d %~dp0
if "%~1"=="" (echo ERROR: pass frame_fifo source as %%1 & exit /b 1)
set SRC=%~f1
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set TB=D:\repo\ECO\udp_hls_10g\tb\tb_frame_fifo.v
echo == TB stage: %SRC% ==
call %XV%\xvlog.bat -work xil_defaultlib "%SRC%" "%TB%" > xvlog_ff.log 2>&1 || (type xvlog_ff.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ff.log 2>&1 || (type xvlog_ff.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_frame_fifo xil_defaultlib.glbl -s tb_frame_fifo -log xelab_ff.log > NUL 2>&1 || (type xelab_ff.log & exit /b 1)
call %XV%\xsim.bat tb_frame_fifo -runall -log xsim_ff.log > NUL 2>&1
type xsim_ff.log
