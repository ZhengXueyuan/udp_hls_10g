@echo off
rem tb_tx_arb xsim 回归: 生成刺激 -> 编译 -> 三模式仿真 -> Python 比对
cd /d %~dp0
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_txarb.py . > gen_ta.log 2>&1
if errorlevel 1 (type gen_ta.log & exit /b 1)
rmdir /s /q xsim.dir 2>nul
del /q tb_tx_arb.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\tx_arb.v ..\..\tb\tb_tx_arb.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tx_arb -s tb_tx_arb -log xelab_run.log > NUL 2>&1
if errorlevel 1 (type xelab_run.log & exit /b 1)
call "%VIV_BIN%\xsim.bat" tb_tx_arb -tclbatch run.tcl -log xsim_run.log > NUL 2>&1
if errorlevel 1 (type xsim_run.log & exit /b 1)
call "%VIV_BIN%\xsim.bat" tb_tx_arb -tclbatch run.tcl -testplusarg STALL -log xsim_run.log > NUL 2>&1
if errorlevel 1 (type xsim_run.log & exit /b 1)
call "%VIV_BIN%\xsim.bat" tb_tx_arb -tclbatch run.tcl -testplusarg HARD -log xsim_run.log > NUL 2>&1
if errorlevel 1 (type xsim_run.log & exit /b 1)
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_txarb.py . --check
exit /b %errorlevel%
