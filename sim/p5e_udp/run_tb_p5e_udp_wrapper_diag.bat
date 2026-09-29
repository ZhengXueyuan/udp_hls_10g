@echo off
set "REPO_ROOT=%~dp0..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)
rem --- pathguard tripwire: refuse to run if a LIVE line points outside ---
set "P4PY=C:\Users\zhxue\anaconda3\python.exe"
if exist "%P4PY%" goto :pg_py_ok
set "P4PY="
for %%P in (python.exe) do if not defined P4PY set "P4PY=%%~$PATH:P"
:pg_py_ok
if not defined P4PY goto :pg_sc_done
if not exist "%REPO_ROOT%\sim\p4gates\p4gate.py" goto :pg_sc_done
"%P4PY%" "%REPO_ROOT%\sim\p4gates\p4gate.py" selfcheck --root "%REPO_ROOT%" --bat "%~f0" --quiet || exit /b 1
:pg_sc_done

REM run_tb_p5e_udp_wrapper_diag.bat -- SAME gate, but APP_MODE + RXP_DIAG config.
REM Project rule: every ifdef build config needs a real-wrapper full-chain gate.
REM RXP_DIAG only adds the first-mismatch snapshot outputs (constants/regs),
REM so the functional chain MUST still pass identically; this run also proves
REM the new wrapper wiring has no implicit/multi-driven/undriven nets.
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
REM   "8-11241/10-3091" -- a missing declaration silently becomes a 1-bit net and the
REM   multi/driver/unconnected checks do NOT catch it).
REM NOTE: keep this file ASCII-only (UTF-8 Chinese in REM lines is eaten by the GBK
REM console and the comment tail gets executed as a command -- project bat pitfall).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set BD=%REPO_ROOT%\board
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog

if exist xsim.dir_diag rmdir /s /q xsim.dir_diag
copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files_w.f

call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d RXP_DIAG -f hls_files_w.f > xvlog_uw_hls.log 2>&1 || (type xvlog_uw_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d RXP_DIAG ^
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
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_uw.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_uw.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_uw.log > warn_uw.txt

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5e_udp_wrapper xil_defaultlib.glbl -s tb_p5e_udp_wrapper -log xelab_uw.log > NUL 2>&1 || (type xelab_uw.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_uw.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_uw.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_uw.log >> warn_uw.txt
call %XV%\xsim.bat tb_p5e_udp_wrapper -runall -log xsim_uw.log > NUL 2>&1 || (type xsim_uw.log & exit /b 1)

REM ---- default-build (NO APP_MODE) static wiring check: the other ifdef config ----
if exist xsim.dir_diag_def rmdir /s /q xsim.dir_diag_def
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
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_ud.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in default build: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_ud.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xvlog_ud.log > warn_ud.txt
call %XV%\xvlog.bat -work xil_defaultlib_def "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ud.log 2>&1 || (type xvlog_ud.log & exit /b 1)
call %XV%\xelab.bat -L unisims_ver xil_defaultlib_def.wrapper_p4 xil_defaultlib_def.glbl -s wrapper_def -log xelab_ud.log > NUL 2>&1 || (type xelab_ud.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ud.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration found in default xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ud.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_ud.log >> warn_ud.txt
echo default-build elab OK

findstr /C:"P5E-T5 UDP WRAPPER GATE: OK" xsim_uw.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"FAIL" xsim_uw.log & exit /b 1)
findstr /C:"P5E-T5 UDP WRAPPER" xsim_uw.log
exit /b 0
