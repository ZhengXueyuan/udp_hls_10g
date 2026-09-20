@echo off
REM run_tb_p5e_t2_wrapper.bat -- P5e-T2 UDP app TX REAL-WRAPPER full-chain gate (pitfall 8)
REM Instantiates wrapper_p4 with -d APP_MODE (same config as board/build_p5.tcl), drives
REM the app UDP TX port by force (T2 has no app consumer yet), and decodes the wrapper
REM INTERNAL gmii: 0 UDP frames while no peer is learned (default no-send), exactly 1
REM correct UDP frame after forcing the peer-learn event, and the TCP fast path still
REM running (shared u_tx_arb). Self-checking TB (no Python).
REM +NOUDP variant (xsim -testplusarg NOUDP): UDP path silent all along (control run).
REM NOTE: keep this file ASCII-only -- UTF-8 Chinese in REM lines is eaten by the GBK
REM console and the comment tail gets executed as a command (project bat pitfall).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5e_t2
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog

if exist xsim.dir rmdir /s /q xsim.dir
copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files_w.f

call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -f hls_files_w.f > xvlog_wh_hls.log 2>&1 || (type xvlog_wh_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_rx_adp.v %RTL%\slow_cfg_adp.v %RTL%\slow_tx_adp.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\tx_arb.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v ^
  %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_udp_pattern.v %RTL%\app_status_uart.v ^
  %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v ^
  %TB%\tb_p5e_t2_wrapper.v > xvlog_wh.log 2>&1 || (type xvlog_wh.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_wh.log 2>&1 || (type xvlog_wh.log & exit /b 1)

REM ---- static wiring checks (pitfall 8) ----
REM 1) implicit declaration: a missing declaration silently becomes a 1-bit net,
REM    truncating 64/8-bit connections (upper bits = Z into the downstream => mac_tx
REM    stores a Z word => cw_len=X => permanent stall). The multi/driver/unconnected
REM    checks do NOT catch it => checked separately here.
REM 2) multi-driver / undriven / unconnected: recorded in warn_wh.txt for review.
findstr /I /C:"implicit" xvlog_wh.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"implicit" xvlog_wh.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_wh.log > warn_wh.txt

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5e_t2_wrapper xil_defaultlib.glbl -s tb_p5e_t2_wrapper -log xelab_wh.log > NUL 2>&1 || (type xelab_wh.log & exit /b 1)
findstr /I /C:"implicit" xelab_wh.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"implicit" xelab_wh.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_wh.log >> warn_wh.txt
call %XV%\xsim.bat tb_p5e_t2_wrapper -runall -log xsim_wh.log > NUL 2>&1 || (type xsim_wh.log & exit /b 1)

REM ---- default-build (NO APP_MODE) static wiring check: the other ifdef config ----
REM must be elaborated too (pitfall 8: every ifdef config needs its own check).
if exist xsim.dir_def rmdir /s /q xsim.dir_def
call %XV%\xvlog.bat -work xil_defaultlib_def -f hls_files_w.f > xvlog_wd_hls.log 2>&1 || (type xvlog_wd_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib_def ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_rx_adp.v %RTL%\slow_cfg_adp.v %RTL%\slow_tx_adp.v ^
  %RTL%\tx_arb.v ^
  %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_udp_pattern.v %RTL%\app_status_uart.v ^
  %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v ^
  > xvlog_wd.log 2>&1 || (type xvlog_wd.log & exit /b 1)
findstr /I /C:"implicit" xvlog_wd.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in default build: & findstr /I /C:"implicit" xvlog_wd.log & exit /b 1)
findstr /C:"multi" /C:"driv" xvlog_wd.log > warn_wd.txt
call %XV%\xvlog.bat -work xil_defaultlib_def "%XV%\..\data\verilog\src\glbl.v" >> xvlog_wd.log 2>&1 || (type xvlog_wd.log & exit /b 1)
call %XV%\xelab.bat -L unisims_ver xil_defaultlib_def.wrapper_p4 xil_defaultlib_def.glbl -s wrapper_def -log xelab_wd.log > NUL 2>&1 || (type xelab_wd.log & exit /b 1)
findstr /I /C:"implicit" xelab_wd.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in default xelab: & findstr /I /C:"implicit" xelab_wd.log & exit /b 1)
findstr /C:"multi" /C:"driv" xelab_wd.log >> warn_wd.txt
echo default-build elab OK

findstr /C:"P5E-T2 WRAPPER GATE: OK" xsim_wh.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"FAIL" xsim_wh.log & exit /b 1)
findstr /C:"P5E-T2 WRAPPER" xsim_wh.log
exit /b 0
