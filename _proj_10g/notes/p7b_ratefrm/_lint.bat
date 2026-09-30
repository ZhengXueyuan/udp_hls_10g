@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\XCKU5PMini\udp_hls_10g\rtl
cd /d %~dp0
if exist xsim.dir rmdir /s /q xsim.dir
echo === DEFAULT (no macro) ===
call %XV%\xvlog.bat -work xil_defaultlib "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\udp_tx_frame.v" > logs\lint_def.log 2>&1
echo default xvlog exit=%errorlevel%
echo === OVL (-d UDP_TX_OVL) ===
call %XV%\xvlog.bat -work xil_defaultlib_ovl -d UDP_TX_OVL "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\udp_tx_frame.v" > logs\lint_ovl.log 2>&1
echo ovl xvlog exit=%errorlevel%
findstr /I /C:"ERROR" /C:"implicitly declared" /C:"10-3091" /C:"10-2989" /C:"8-11241" logs\lint_def.log logs\lint_ovl.log
echo ---- def tail ----
type logs\lint_def.log
echo ---- ovl tail ----
type logs\lint_ovl.log
