@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
cd /d %~dp0
call %XV%\xvlog.bat -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\udp_rx.v %RTL%\udp_split.v > xvlog_chk.log 2>&1
exit /b %ERRORLEVEL%
