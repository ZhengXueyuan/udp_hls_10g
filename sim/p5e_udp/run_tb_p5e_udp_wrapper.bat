@echo off
REM run_tb_p5e_udp_wrapper.bat -- P5e-T3/T5 UDP app REAL-WRAPPER full-chain gate (pitfall 8)
REM Instantiates wrapper_p4 with -d APP_MODE (same config as board/build_p5.tcl),
REM force-injects ONE UDP frame on the wrapper-internal GMII RX side
REM (u_dut.e_rxd/e_rxdv/e_rxer), then checks the whole chain:
REM   mac_rx_64 -> rx_classify -> u_udp_split -> app RX + meta_*  ->
REM   u_udp_tx_cfg (learn-on-RX) -> u_udp_tx -> u_tx_udp_arb -> u_tx_arb -> mac_tx_64
REM and decodes the outgoing UDP frame on the wrapper-internal GMII TX.
REM +NOUDP variant (xsim -testplusarg NOUDP): no injection => zero UDP frames.
REM
REM DRC-level static checks on xvlog AND xelab logs, for BOTH ifdef configs:
REM   implicit / multi-driven / undriven / unconnected  (T2 recommendation: keep
REM   "implicit" -- a missing declaration silently becomes a 1-bit net and the
REM   multi/driver/unconnected checks do NOT catch it).
REM NOTE: keep this file ASCII-only (UTF-8 Chinese in REM lines is eaten by the GBK
REM console and the comment tail gets executed as a command -- project bat pitfall).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog

if exist xsim.dir rmdir /s /q xsim.dir
copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files_w.f

call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -f hls_files_w.f > xvlog_uw_hls.log 2>&1 || (type xvlog_uw_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_rx_adp.v %RTL%\slow_cfg_adp.v %RTL%\slow_tx_adp.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\tx_arb.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\app_udp_pattern.v ^
  %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_status_uart.v ^
  %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v ^
  %TB%\tb_p5e_udp_wrapper.v > xvlog_uw.log 2>&1 || (type xvlog_uw.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_uw.log 2>&1 || (type xvlog_uw.log & exit /b 1)

REM ---- static wiring checks (pitfall 8) ----
findstr /I /C:"implicit" xvlog_uw.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"implicit" xvlog_uw.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_uw.log > warn_uw.txt

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5e_udp_wrapper xil_defaultlib.glbl -s tb_p5e_udp_wrapper -log xelab_uw.log > NUL 2>&1 || (type xelab_uw.log & exit /b 1)
findstr /I /C:"implicit" xelab_uw.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"implicit" xelab_uw.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_uw.log >> warn_uw.txt
call %XV%\xsim.bat tb_p5e_udp_wrapper -runall -log xsim_uw.log > NUL 2>&1 || (type xsim_uw.log & exit /b 1)

REM ---- default-build (NO APP_MODE) static wiring check: the other ifdef config ----
if exist xsim.dir_def rmdir /s /q xsim.dir_def
call %XV%\xvlog.bat -work xil_defaultlib_def -f hls_files_w.f > xvlog_ud_hls.log 2>&1 || (type xvlog_ud_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib_def ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_rx_adp.v %RTL%\slow_cfg_adp.v %RTL%\slow_tx_adp.v ^
  %RTL%\tx_arb.v ^
  %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_status_uart.v ^
  %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v ^
  > xvlog_ud.log 2>&1 || (type xvlog_ud.log & exit /b 1)
findstr /I /C:"implicit" xvlog_ud.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in default build: & findstr /I /C:"implicit" xvlog_ud.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_ud.log > warn_ud.txt
call %XV%\xvlog.bat -work xil_defaultlib_def "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ud.log 2>&1 || (type xvlog_ud.log & exit /b 1)
call %XV%\xelab.bat -L unisims_ver xil_defaultlib_def.wrapper_p4 xil_defaultlib_def.glbl -s wrapper_def -log xelab_ud.log > NUL 2>&1 || (type xelab_ud.log & exit /b 1)
findstr /I /C:"implicit" xelab_ud.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in default xelab: & findstr /I /C:"implicit" xelab_ud.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_ud.log >> warn_ud.txt
echo default-build elab OK

findstr /C:"P5E-T5 UDP WRAPPER GATE: OK" xsim_uw.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"FAIL" xsim_uw.log & exit /b 1)
findstr /C:"P5E-T5 UDP WRAPPER" xsim_uw.log
exit /b 0
