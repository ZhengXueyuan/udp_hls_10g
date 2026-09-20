@echo off
REM run_tb_p5_multi.bat -- P5d D5 multi-connection gate (tb_p5_multi.v)
REM
REM Criteria (tools/gen_stim_p5_multi.py):
REM   1 pool split: winq[c] == WIN_POOL/N (app writes app_ctrl reg 0x0C before ADD)
REM   2 per-cycle  SUM(winq) + pool == WIN_POOL
REM   3 mac_rx_64.stat_drop == 0
REM   4 occ + SUM(winq) + N*ACC_MARGIN + delta + U + SEG_MAX <= 65536 (H-fix)
REM   5 two connections close concurrently: exactly one FIN each / no RST /
REM     no FIN dst-MAC cross-talk
REM   6 no WAIT timeout   7 drift: tcp_rx stat_drop_seq == 0 && peer rewind == 0
REM   8 sink per-tid byte continuity STRICT (miss == 0) + byte conservation
REM   9 wrapper/TB ACC_MARGIN table mirror (parsed from source)
REM
REM Usage: run_tb_p5_multi.bat [case]  case = main(default)/neg_wq/neg_mgn/neg_mgn0/known_idle_fifo
REM   neg_wq   : app writes 0xC000 back (old default, no split)  => criterion 1 must FAIL
REM   neg_mgn  : TB mirror forces margin 4096 (N=3 over by 1738) => criterion 4 must FAIL
REM   neg_mgn0 : TB mirror forces margin 0 (cannot cover drift)  => criterion 7 must FAIL
REM   known_idle_fifo : long write-only -> first read must be byte-exact (positive guard;
REM     used to be the "pre-existing frame_fifo defect" probe -- refuted: the 8B slip was
REM     a TB stimulus race (blocking write of sink_rate at the clock edge) -- see the
REM     staging section comment in tb/tb_p5_multi.v and sim/p5d_multi/p5dmech/
REM Each case uses its OWN work dir (project rule: leftover xsim procs lock xsim.dir)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set TOOL=D:\repo\ECO\udp_hls_10g\tools
set SIM=%~dp0
set CASE=%1
if "%CASE%"=="" set CASE=main
set WORK=%SIM%%CASE%
if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

set DEFS=
if /I "%CASE%"=="neg_mgn"  set DEFS=-d P5D_NEG_MGN
if /I "%CASE%"=="neg_mgn0" set DEFS=-d P5D_NEG_MGN0

%PY% %TOOL%\gen_stim_p5_multi.py %WORK% %CASE% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib %DEFS% ^
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
  %TB%\tb_p5_multi.v > xvlog_multi.log 2>&1 || (type xvlog_multi.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_multi.log 2>&1 || (type xvlog_multi.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5_multi xil_defaultlib.glbl -s tb_p5_multi -log xelab_multi.log > NUL 2>&1 || (type xelab_multi.log & exit /b 1)
call %XV%\xsim.bat tb_p5_multi -runall -log xsim_multi.log > NUL 2>&1 || (type xsim_multi.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_multi.py %WORK% %CASE% check
exit /b %ERRORLEVEL%
