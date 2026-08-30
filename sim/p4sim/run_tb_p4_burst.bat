@echo off
REM run_tb_p4_burst.bat -- P4b-5/6 debug: N x 1460B line-rate burst
REM   usage (Git Bash): cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat [N [pause_at pause_len [wnd_hex]]]'
REM   %1 = burst segment count (default 200)
REM   %2/%3 = pause_at/pause_len (cycles, optional; that segment becomes 352B,
REM           next segment gets the long pre-gap) -- PC send pause-resume
REM   %4 = burst advertised window in hex (default 4000); =10 also sets
REM        +PCWND1K (raw 0010 << wscale8 = effective 4096, gate stress)
REM   P4b-6: always runs with +PCACK (window gating needs ACK injection to
REM          advance snd_una, otherwise the gate deadlocks the echo)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog
set NB=%1
if "%NB%"=="" set NB=200
set PAUSE=
if not "%2"=="" set PAUSE=%2 %3
set WND=
if not "%4"=="" set WND=%4
set XPA=-testplusarg PCACK
if "%4"=="10" set XPA=-testplusarg PCACK -testplusarg PCWND1K

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim burst %NB% %PAUSE% %WND% || exit /b 1

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
  D:\repo\ECO\udp_hls_10g\rtl\tcp_echo.v ^
  D:\repo\ECO\udp_hls_10g\rtl\rx_classify.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_cfg_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v ^
  D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_p4_chain -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall %XPA% -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim burstcheck %NB%
