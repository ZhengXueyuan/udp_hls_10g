@echo off
rem tcp_rx 全链 xsim 回归: 编译 -> 快照 -> 三模式仿真 (nostall/stall/hard)
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\p3sim\run_tb_tcp_rx.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\p3sim
rem 自生成激励 (p3sim 内多个 TB 共享 stim_*.memh 文件名, 跑前必须重新生成)
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_tcp_rx.py . > gen_tcp_rx.log 2>&1
if errorlevel 1 exit /b 1
rmdir /s /q xsim.dir 2>nul
del /q tb_tcp_rx.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\rtl\mac_rx_64.v ..\..\rtl\tcp_cam.v ..\..\rtl\tcb.v ..\..\rtl\tcp_rx.v ..\..\tb\tb_tcp_rx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tcp_rx -s tb_tcp_rx
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_tcp_rx -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_tcp_rx -tclbatch run.tcl -testplusarg STALL
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_tcp_rx -tclbatch run.tcl -testplusarg HARD
if errorlevel 1 exit /b 1
