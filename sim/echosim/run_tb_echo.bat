@echo off
rem 全链 echo 闭环 xsim 回归
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\echosim\run_tb_echo.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\echosim
rmdir /s /q xsim.dir 2>nul
del /q tb_echo.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\rtl\checksum16.v ..\..\rtl\frame_fifo.v ..\..\rtl\mac_rx_64.v ..\..\rtl\mac_tx_64.v ..\..\rtl\udp_rx.v ..\..\rtl\udp_echo.v ..\..\rtl\udp_tx_frame.v ..\..\tb\tb_udp_echo.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_udp_echo -s tb_echo
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_echo -tclbatch run.tcl
if errorlevel 1 exit /b 1
