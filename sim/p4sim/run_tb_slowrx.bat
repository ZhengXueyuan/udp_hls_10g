@echo off
rem tb_slow_rx xsim 回归: 生成刺激 -> 编译 -> 三模式仿真 -> Python 比对
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\p4sim
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_slowrx.py . > gen_sr.log 2>&1
if errorlevel 1 exit /b 1
rmdir /s /q xsim.dir 2>nul
del /q tb_slow_rx.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\fifo_sync.v ..\..\rtl\frame_fifo.v ..\..\rtl\slow_rx_adp.v ..\..\tb\tb_slow_rx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_slow_rx -s tb_slow_rx
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl -testplusarg STALL
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl -testplusarg HARD
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl -testplusarg WD
if errorlevel 1 exit /b 1
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_slowrx.py . --check
exit /b %errorlevel%
