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

REM run_tb_p4_chain_active_slow.bat -- P1-2 PCACTIVE slow-peer gate: same active
REM   netlist (+PCACTIVE) but the TB withholds the SYN+ACK after the 1st board SYN
REM   (pcslow.memh=1) until the RTO-retransmitted SYN appears (scaled
REM   TCP_RTO_MIN=100000 via hls/run_hls_active.tcl). check_active asserts
REM   syn_cnt >= 2 (T_SYN_SENT retransmit path really executed) + full connect.
REM run_tb_p4_chain_active.bat -- P5 PCACTIVE: TCP active-connect (client) gate
REM   Board-side HLS netlist must be the ACTIVE_CONNECT=1 build
REM   (hls\run_hls_active.tcl -> slowstack_prj\solution1\syn\verilog), with
REM   ACTIVE_IP=0xC0A86463 (192.168.100.99) to force the ARP who-has path.
REM   Static stimulus = the P4 chain stream (unchanged); the active SYN is
REM   emitted by the HLS at a cycle-level-unpredictable pass, so the TB
REM   (+PCACTIVE) reacts instead: it captures the board active frames on GMII
REM   TX and injects ARP reply / SYN+ACK / 100B data segment in RX frame gaps.
REM   Criteria (tools/gen_stim_p4_chain.py activecheck): active SYN captured
REM   (seq=ACTIVE_ISS) -> SYN+ACK -> pure ACK -> ESTABLISHED slot with the
REM   right CAM 4-tuple -> data echo on the fast path; passive conn0 coexists.
REM   From Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain_active.bat'
cd /d %~dp0
REM no TXDROP / TRUNC / HALFDROP fault injection in this gate (stale files
REM must not leak in -- the TB and the generator both read them)
if exist txdrop.memh del /q txdrop.memh
if exist trunc.memh del /q trunc.memh
if exist halfdrop.memh del /q halfdrop.memh
REM P4e: delete vlan.memh so this gate never inherits VLAN tagging from a
REM previous run_tb_p4_*_vlan.bat (gen_stim/apply both read that file).
if exist vlan.memh del /q vlan.memh
REM P1-2 slow-peer switch for the TB and check_active (same file channel as
REM TRUNC: the xsim loader splits -testplusarg args containing '=').
> pcslow.memh echo 1
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% %REPO_ROOT%\tools\gen_stim_p4_chain.py %REPO_ROOT%\sim\p4sim || exit /b 1

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
  %REPO_ROOT%\rtl\tx_arb.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
REM The TB PROBE debug binds to the HLS top-level ap_CS_fsm, which exists in
REM every netlist, so no per-netlist xvlog -d define is needed here.
call %XV%\xvlog.bat -work xil_defaultlib ^
  %REPO_ROOT%\tb\tb_p4_chain.v >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall -testplusarg PCACTIVE -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% %REPO_ROOT%\tools\gen_stim_p4_chain.py %REPO_ROOT%\sim\p4sim activecheck
