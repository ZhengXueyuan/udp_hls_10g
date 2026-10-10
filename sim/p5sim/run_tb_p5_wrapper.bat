@echo off
REM ---- repo root + pathguard (2026-10-10 aliasgate round) -------------------
REM   One source of truth, same as every other matrix gate: REPO_ROOT comes
REM   from sim\p4gates\p4env.bat.  The old bespoke header derived REPO_ROOT
REM   itself through a for-loop over its own directory, and p4gate.py
REM   manifestcheck read that back as an UNRESOLVED for-loop literal => every
REM   xvlog token stayed unresolved, the bat's file list compared as EMPTY,
REM   and the gate could not be registered in the matrix with a non-empty
REM   manifest.  (Measured 2026-10-10: manifestcheck against the old header
REM   with this manifest printed "bat carries 0".)
REM   NOTE FOR EDITORS: cmd expands percent-substitutions in REM lines too,
REM   and an invalid one (a tilde-form referencing a non-argument letter) is
REM   FATAL to the whole run -- keep percent-tilde patterns out of comments.
call "%~dp0..\p4gates\p4env.bat" || exit /b 1
rem --- pathguard tripwire: refuse to run if a LIVE line points outside ---
"%PY%" "%P4GATE_PY%" selfcheck --root "%REPO_ROOT%" --bat "%~f0" --quiet || exit /b 1

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
REM ---- matrix hook (2026-10-10 #19): private cwd + declared manifest --------
REM   The matrix runner exports P4_WORKDIR (its per-gate private directory, so
REM   stale xsim.dir locks / .memh files cannot cross-contaminate -- pit 7 of
REM   this project).  Standalone runs keep the historical behaviour (cwd =
REM   sim\p5sim).  checkpaths refuses a foreign/absent manifest entry.
if not "%P4_WORKDIR%"=="" cd /d "%P4_WORKDIR%"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GATES%\p5wrapper_src.f" --path "%CD%" --quiet || exit /b 1
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set BD=%REPO_ROOT%\board
set TOOL=%REPO_ROOT%\tools
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog

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
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v ^
  %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_udp_pattern.v %RTL%\app_status_uart.v ^
  %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v ^
  %TB%\tb_p5_wrapper.v > xvlog_w.log 2>&1 || (type xvlog_w.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_w.log 2>&1 || (type xvlog_w.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5_wrapper xil_defaultlib.glbl -s tb_p5_wrapper -log xelab_w.log > NUL 2>&1 || (type xelab_w.log & exit /b 1)
findstr /C:"multi" /C:"driv" /C:"unconnected" /C:"not connected" xelab_w.log > warn_w.txt
call %XV%\xsim.bat tb_p5_wrapper -runall -log xsim_w.log > NUL 2>&1 || (type xsim_w.log & exit /b 1)

REM   criteria read the CURRENT directory, not sim\p5sim: under the matrix the
REM   run happens in P4_WORKDIR, and a checker pointed at the historical
REM   sim\p5sim would read a stale resp_p5_wrapper.memh from an earlier run (a
REM   silent wrong-file read).  Standalone, both are the same directory.
%PY% %TOOL%\gen_stim_p5_app.py "%CD%" checkwrapper
