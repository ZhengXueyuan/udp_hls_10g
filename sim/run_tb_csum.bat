@echo off
rem 用法: run_tb_csum.bat   (工作目录必须为本 sim 目录)
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim
rmdir /s /q xsim.dir 2>nul
del /q tb_snap.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\rtl\checksum16.v ..\tb\tb_checksum16.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_checksum16 -s tb_snap
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_snap -tclbatch run.tcl
