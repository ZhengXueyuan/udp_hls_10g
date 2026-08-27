@echo off
rem TCP echo 全链 xsim: 生成 -> 编译 -> 仿真 -> python 校验 (一条线)
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\p3sim\run_tb_tcp_echo.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d D:\repo\ECO\udp_hls_10g\sim\p3sim
rem 自生成激励 (p3sim 共享 stim 文件名, 跑前必须重新生成)
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_tcp_echo.py . > gen_tcp_echo.log 2>&1
if errorlevel 1 exit /b 1
rmdir /s /q xsim.dir 2>nul
del /q tb_tcp_echo.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\checksum16.v ..\..\rtl\fifo_sync.v ..\..\rtl\frame_fifo.v ..\..\rtl\mac_rx_64.v ..\..\rtl\mac_tx_64.v ..\..\rtl\tcp_cam.v ..\..\rtl\tcb.v ..\..\rtl\tcp_rx.v ..\..\rtl\tcp_echo.v ..\..\rtl\tcp_tx_frame.v ..\..\rtl\tcp_synp.v ..\..\tb\tb_tcp_echo.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tcp_echo -s tb_tcp_echo
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_tcp_echo -tclbatch run.tcl
if errorlevel 1 exit /b 1
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_tcp_echo.py . check
if errorlevel 1 exit /b 1
