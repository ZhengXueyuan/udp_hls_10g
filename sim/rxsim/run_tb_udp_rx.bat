@echo off
rem udp_rx 全链 xsim 回归: 编译 -> 快照 -> 三模式仿真 (nostall/stall/hard)
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\rxsim\run_tb_udp_rx.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\rxsim
rmdir /s /q xsim.dir 2>nul
del /q tb_snap.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\rtl\mac_rx_64.v ..\..\rtl\udp_rx.v ..\..\tb\tb_udp_rx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_udp_rx -s tb_udp_rx
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_rx -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_rx -tclbatch run.tcl -testplusarg STALL
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_rx -tclbatch run.tcl -testplusarg HARD
if errorlevel 1 exit /b 1
