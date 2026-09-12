@echo off
REM run_tb_p4_chain.bat — P4a 全链 (含真 HLS udp_echo) xsim 一条线
REM 自生成刺激; 从 Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain.bat'
cd /d %~dp0
if exist txdrop.memh del /q txdrop.memh
REM P4b-7-P6: chain gate never truncates -- make sure no trunc.memh leaks in
REM from a previous run_tb_p4_burst.bat TRUNC run (TB/gen both read it).
if exist trunc.memh del /q trunc.memh
REM P4b-7-P6: same for the HALFDROP half-frame abort injection (halfdrop.memh).
if exist halfdrop.memh del /q halfdrop.memh
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib ^
  D:\repo\ECO\udp_hls_10g\rtl\crc32_8b.v ^
  D:\repo\ECO\udp_hls_10g\rtl\fifo_sync.v ^
  D:\repo\ECO\udp_hls_10g\rtl\checksum16.v ^
  D:\repo\ECO\udp_hls_10g\rtl\frame_fifo.v ^
  D:\repo\ECO\udp_hls_10g\rtl\mac_rx_64.v ^
  D:\repo\ECO\udp_hls_10g\rtl\mac_tx_64.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_cam.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcb.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_rx.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_tx_frame.v ^
  D:\repo\ECO\udp_hls_10g\rtl\retx_ram.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_echo.v ^
  D:\repo\ECO\udp_hls_10g\rtl\axis_pipe.v ^
  D:\repo\ECO\udp_hls_10g\rtl\rx_classify.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_cfg_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v ^
  D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

REM P4b-7-P6: frame_fifo 含 RAMB36E1/RAMB18E1 原语 -> xelab 需 -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim check
