@echo off
rem #48 tcp chain 全链 xsim 回归: 生成刺激 -> 编译 -> 快照 -> 仿真 -> python check
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\p3sim\run_tb_tcp_chain.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set PY=C:\Users\zhxue\anaconda3\python.exe
cd /d D:\repo\ECO\udp_hls_10g\sim\p3sim
"%PY%" D:\repo\ECO\udp_hls_10g\tools\gen_stim_tcp_chain.py D:\repo\ECO\udp_hls_10g\sim\p3sim
if errorlevel 1 exit /b 1
rmdir /s /q xsim.dir 2>nul
del /q tb_tcp_chain.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\checksum16.v ..\..\rtl\fifo_sync.v ..\..\rtl\mac_rx_64.v ..\..\rtl\mac_tx_64.v ..\..\rtl\tcp_cam.v ..\..\rtl\tcb.v ..\..\rtl\tcp_rx.v ..\..\rtl\tcp_synp.v ..\..\rtl\tcp_tx_frame.v ..\..\tb\tb_tcp_chain.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tcp_chain -s tb_tcp_chain
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_tcp_chain -tclbatch run.tcl
if errorlevel 1 exit /b 1
"%PY%" D:\repo\ECO\udp_hls_10g\tools\gen_stim_tcp_chain.py D:\repo\ECO\udp_hls_10g\sim\p3sim check
exit /b %errorlevel%
