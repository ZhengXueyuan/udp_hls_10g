@echo off
REM run_tb_p4_chain_vlan.bat -- P4e VLAN gate: same chain gate but every
REM   conn0 TCP data frame (data7a/data7b/burst) carries a single 802.1Q tag
REM   (vlan.memh=1, read by BOTH gen_stim and the checker). Echo/ACK/stats
REM   expectations are UNCHANGED (fast TX sends no tag); only stat_stripped
REM   > 0 is added.
REM run_tb_p4_chain.bat -- P4a full chain (with the real HLS udp_echo) in one xsim run
REM self-generated stimulus; from Git Bash run the matrix entry point:
cd /d %~dp0
call "%~dp0..\p4gates\p4env.bat" || exit /b 1
if not "%P4_WORKDIR%"=="" cd /d "%P4_WORKDIR%"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --path "%CD%" --quiet || exit /b 1
if exist txdrop.memh del /q txdrop.memh
REM P4b-7-P6: chain gate never truncates -- make sure no trunc.memh leaks in
REM from a previous run_tb_p4_burst.bat TRUNC run (TB/gen both read it).
if exist trunc.memh del /q trunc.memh
REM P4b-7-P6: same for the HALFDROP half-frame abort injection (halfdrop.memh).
if exist halfdrop.memh del /q halfdrop.memh
REM P4e VLAN injection switch for gen_stim/check (file channel: the xsim
REM loader splits -testplusarg args containing '='). Always rewritten so a
REM stale file never leaks; the default gates delete vlan.memh.
> vlan.memh echo 1
REM P1-2: the slow-peer gate leaves pcslow.memh behind -- delete it so this
REM gate runs with the default fast-peer model.
if exist pcslow.memh del /q pcslow.memh

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

"%PY%" "%TOOLS%\gen_stim_p4_chain.py" "%CD%" || exit /b 1

"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GATES%\chain_src.f" --path "%CD%" --quiet || exit /b 1
call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib ^
  %REPO_ROOT%\rtl\crc32_8b.v ^
  %REPO_ROOT%\rtl\fifo_sync.v ^
  %REPO_ROOT%\rtl\checksum16.v ^
  %REPO_ROOT%\rtl\frame_fifo.v ^
  %REPO_ROOT%\rtl\mac_rx_64.v ^
  %REPO_ROOT%\rtl\mac_tx_64.v ^
  %REPO_ROOT%\rtl\tcp_cam.v ^
  %REPO_ROOT%\rtl\tcb.v ^
  %REPO_ROOT%\rtl\tcp_rx.v ^
  %REPO_ROOT%\rtl\tcp_tx_frame.v ^
  %REPO_ROOT%\rtl\retx_ram.v ^
  %REPO_ROOT%\rtl\tcp_echo.v ^
  %REPO_ROOT%\rtl\axis_pipe.v ^
  %REPO_ROOT%\rtl\rx_classify.v ^
  %REPO_ROOT%\rtl\vlan_strip.v ^
  %REPO_ROOT%\rtl\slow_cfg_adp.v ^
  %REPO_ROOT%\rtl\slow_rx_adp.v ^
  %REPO_ROOT%\rtl\slow_tx_adp.v ^
  %REPO_ROOT%\rtl\tx_arb.v ^
  %REPO_ROOT%\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

REM P4b-7-P6: frame_fifo instantiates RAMB36E1/RAMB18E1 -> xelab needs -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

"%PY%" "%TOOLS%\gen_stim_p4_chain.py" "%CD%" check
