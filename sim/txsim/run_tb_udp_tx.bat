@echo off
rem udp_tx_frame 全链 xsim 回归: csum_en=1 与 CSUM0 两模式
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\txsim\run_tb_udp_tx.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\txsim
rmdir /s /q xsim.dir 2>nul
del /q tb_udp_tx.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\rtl\checksum16.v ..\..\rtl\mac_tx_64.v ..\..\rtl\udp_tx_frame.v ..\..\tb\tb_udp_tx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_udp_tx -s tb_udp_tx
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_tx -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_tx -tclbatch run.tcl -testplusarg CSUM0
if errorlevel 1 exit /b 1
