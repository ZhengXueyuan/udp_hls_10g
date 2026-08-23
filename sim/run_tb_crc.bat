@echo off
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim
rmdir /s /q xsim.dir 2>nul
del /q tb_snap.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\rtl\crc32_8b.v ..\tb\tb_crc.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_crc -s tb_snap
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_snap -tclbatch run.tcl
