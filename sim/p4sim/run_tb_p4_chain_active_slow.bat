@echo off
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
  D:\repo\ECO\udp_hls_10g\rtl\vlan_strip.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_cfg_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
REM The TB PROBE debug binds to the HLS top-level ap_CS_fsm, which exists in
REM every netlist, so no per-netlist xvlog -d define is needed here.
call %XV%\xvlog.bat -work xil_defaultlib ^
  D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall -testplusarg PCACTIVE -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim activecheck
