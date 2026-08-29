@echo off
rem tb_slow_tx xsim 回归: 生成刺激 -> 编译 -> 三模式仿真 -> Python 比对
cd /d %~dp0
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_slowtx.py . > gen_st.log 2>&1
if errorlevel 1 (type gen_st.log & exit /b 1)
rmdir /s /q xsim.dir 2>nul
del /q tb_slow_tx.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\fifo_sync.v ..\..\rtl\frame_fifo.v ..\..\rtl\slow_tx_adp.v ..\..\tb\tb_slow_tx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_slow_tx -s tb_slow_tx -log xelab_run.log > NUL 2>&1
if errorlevel 1 (type xelab_run.log & exit /b 1)
call "%VIV_BIN%\xsim.bat" tb_slow_tx -tclbatch run.tcl -log xsim_run.log > NUL 2>&1
if errorlevel 1 (type xsim_run.log & exit /b 1)
call "%VIV_BIN%\xsim.bat" tb_slow_tx -tclbatch run.tcl -testplusarg STALL -log xsim_run.log > NUL 2>&1
if errorlevel 1 (type xsim_run.log & exit /b 1)
call "%VIV_BIN%\xsim.bat" tb_slow_tx -tclbatch run.tcl -testplusarg HARD -log xsim_run.log > NUL 2>&1
if errorlevel 1 (type xsim_run.log & exit /b 1)
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_slowtx.py . --check
exit /b %errorlevel%
