@echo off
REM run_tb_p5_wrapper.bat -- wrapper-level APP_MODE gate (P5a review W1)
REM instantiates wrapper_p4 with -d APP_MODE, presets TCB/CAM by hierarchical
REM assign, forces one CONN_UP event, and byte-checks the app pattern captured
REM on the wrapper's INTERNAL gmii (mac_tx_64 -> u_rgmii). This is the only
REM gate that exercises the wrapper's APP_MODE app-TX wiring.
REM
REM Step 1 (static):  xvlog/xelab with -d APP_MODE, log warnings grepped for
REM                   multi-driven / undriven / unconnected evidence.
REM Step 2 (dynamic): simulate + checkwrapper.
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set TOOL=D:\repo\ECO\udp_hls_10g\tools
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5c_t4reg
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog

if exist resp_p5_wrapper.memh del /q resp_p5_wrapper.memh
copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files_w.f

call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -f hls_files_w.f > xvlog_w_hls.log 2>&1 || (type xvlog_w_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_rx_adp.v %RTL%\slow_cfg_adp.v %RTL%\slow_tx_adp.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\tx_arb.v ^
  %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_udp_pattern.v %RTL%\app_status_uart.v ^
  %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v ^
  %TB%\tb_p5_wrapper.v > xvlog_w.log 2>&1 || (type xvlog_w.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_w.log 2>&1 || (type xvlog_w.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5_wrapper xil_defaultlib.glbl -s tb_p5_wrapper -log xelab_w.log > NUL 2>&1 || (type xelab_w.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_w.log > warn_w.txt
call %XV%\xsim.bat tb_p5_wrapper -runall -log xsim_w.log > NUL 2>&1 || (type xsim_w.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_app.py %SIM% checkwrapper
