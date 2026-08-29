@echo off
rem tb_rx_classify xsim 回归: 生成刺激 -> 编译 -> 三模式仿真 -> Python 比对
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_rxclass.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\p4sim
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_rxclass.py . > gen_rc.log 2>&1
if errorlevel 1 exit /b 1
rmdir /s /q xsim.dir 2>nul
del /q tb_rx_classify.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\rx_classify.v ..\..\tb\tb_rx_classify.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_rx_classify -s tb_rx_classify
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_rx_classify -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_rx_classify -tclbatch run.tcl -testplusarg STALL
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_rx_classify -tclbatch run.tcl -testplusarg HARD
if errorlevel 1 exit /b 1
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_rxclass.py . --check
exit /b %errorlevel%
