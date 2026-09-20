@echo off
REM run_tb_p5_adv.bat -- P5a adversarial cases (tb_p5_adv.v, built by the P5a
REM reviewer). Usage: run_tb_p5_adv.bat <case>   (case = len b2b wnd fin findrop
REM abort evfifo reconn_fast reconn_slow multi)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set TOOL=D:\repo\ECO\udp_hls_10g\tools
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5c_t5\g_adv
set CASE=%1
if "%CASE%"=="" set CASE=len

%PY% %TOOL%\gen_stim_p5_adv.py %SIM% %CASE% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib_a ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_cfg_adp.v %RTL%\tx_arb.v %RTL%\app_ctrl.v ^
  %TB%\tb_p5_adv.v > xvlog_adv.log 2>&1 || (type xvlog_adv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib_a "%XV%\..\data\verilog\src\glbl.v" >> xvlog_adv.log 2>&1 || (type xvlog_adv.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib_a.tb_p5_adv xil_defaultlib_a.glbl -s tb_p5_adv -log xelab_adv.log > NUL 2>&1 || (type xelab_adv.log & exit /b 1)
call %XV%\xsim.bat tb_p5_adv -runall -log xsim_adv_%CASE%.log > NUL 2>&1 || (type xsim_adv_%CASE%.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_adv.py %SIM% %CASE% check
