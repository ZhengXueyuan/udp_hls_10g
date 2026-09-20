@echo off
REM run_tb_p5_app.bat -- P5a app interface full-chain gate (tb_p5_app, APP_MODE data plane)
REM one line: gen stim -> xvlog -> xelab -> xsim -> check. Own sim dir (sim\p5sim),
REM never shares xsim.dir with sim\p4sim (define/unit reuse hazard).
REM
REM Fault injection (env vars, written to memh before gen_stim reads them):
REM   P5BAD=N    : app sends its Nth frame with a 2000B payload (over-length guard gate)
REM   P5RX=N     : inject the PC->FPGA 100B pattern data segment after the Nth TX frame
REM                (default 200; set P5RX=0 or huge to disable)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set TOOL=D:\repo\ECO\udp_hls_10g\tools
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5b_ind2

if exist p5bad.memh del /q p5bad.memh
if exist p5rx.memh del /q p5rx.memh
if not "%P5BAD%"=="" > p5bad.memh echo %P5BAD%
if not "%P5RX%"=="" > p5rx.memh echo %P5RX%

%PY% %TOOL%\gen_stim_p5_app.py %SIM% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\crc32_8b.v ^
  %RTL%\fifo_sync.v ^
  %RTL%\checksum16.v ^
  %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v ^
  %RTL%\mac_tx_64.v ^
  %RTL%\tcp_cam.v ^
  %RTL%\tcb.v ^
  %RTL%\tcp_rx.v ^
  %RTL%\tcp_tx_frame.v ^
  %RTL%\retx_ram.v ^
  %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v ^
  %RTL%\rx_classify.v ^
  %RTL%\vlan_strip.v ^
  %RTL%\slow_cfg_adp.v ^
  %RTL%\tx_arb.v ^
  %RTL%\app_ctrl.v ^
  %RTL%\app_pattern.v ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
  %TB%\tb_p5_app.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1/RAMB18E1 primitives -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5_app xil_defaultlib.glbl -s tb_p5_app -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p5_app -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_app.py %SIM% check
