@echo off
rem tcp_cam + tcb 合并 TB
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\p3sim
rmdir /s /q xsim.dir 2>nul
del /q tb_cam_tcb.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\tcp_cam.v ..\..\rtl\tcb.v ..\..\tb\tb_tcp_cam_tcb.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tcp_cam_tcb -s tb_cam_tcb
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_cam_tcb -tclbatch run.tcl
if errorlevel 1 exit /b 1
