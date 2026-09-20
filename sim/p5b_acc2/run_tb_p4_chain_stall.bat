@echo off
REM run_tb_p4_chain_stall.bat -- P4d-fix data-plane deadlock reproduction gate.
REM   Board root cause (48KB window + RTO rewind): the PC filled the window and
REM   stopped sending pure ACKs; the board RTO-rewound (snd_nxt := snd_una,
REM   high-water kept in retx_hi) and replayed the full window; the PC's
REM   "I got everything" ACK (ack = high-water) arrived DURING the replay ->
REM   old tcp_rx ack_ok bound used the rewound snd_nxt (below the high-water)
REM   -> the legal ACK was refused; TCP never re-sends ACKs -> snd_una frozen
REM   forever -> in-flight stays at the window cap -> win_open stays 0 -> the
REM   echo pipe backs up into tcp_rx -> whole fast path deadlocked.
REM
REM   TB model (+PCACK +PCSTALL, RTOLIM_FAST -> RTO = 125x256 = 32k cycles):
REM     1) inject ACKs exactly like PCACK until in-flight (wire high-water minus
REM        last injected ack) reaches PCSTALL_BYTES (pcstall.memh) -> freeze the
REM        ACK model permanently (= the PC going quiet);
REM     2) the board's gate closes, RTO fires, svc rewinds and the ring replay
REM        starts (TB watches u_tx.retx_active);
REM     3) PCSTALL_DELAY cycles into the session the TB injects ONE pure ACK
REM        with ack = high-water (the board-side retx_hi) and then stays quiet;
REM     4) criteria (tools/gen_stim_p4_chain.py stallcheck): the injection really
REM        landed mid-session with ack > current snd_nxt, and afterwards the
REM        board sends NEW data (echo frames with seq >= high-water, impossible
REM        for ring replay frames) with snd_una caught up to the high-water.
REM
REM   PCSTALL_BYTES defaults to 0xBFFE (49150 = RTL RING_CAP, the window cap the
REM   board hit); PCSTALL_DELAY defaults to 300 cycles. Both reach the TB and
REM   the checker through pcstall.memh (xsim.bat's loader splits -testplusarg
REM   args containing '=', same file channel as txdrop/trunc/halfdrop).
REM   Usage (Git Bash):
REM     cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5b_acc2\run_tb_p4_chain_stall.bat [N [BYTES [DELAY]]]'
cd /d %~dp0
REM no TXDROP / TRUNC / HALFDROP / VLAN / pcslow fault injection in this gate
REM (stale files must not leak in -- the TB and the generator both read them)
if exist txdrop.memh del /q txdrop.memh
if exist trunc.memh del /q trunc.memh
if exist halfdrop.memh del /q halfdrop.memh
if exist vlan.memh del /q vlan.memh
if exist pcslow.memh del /q pcslow.memh
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog
set NB=%1
if "%NB%"=="" set NB=200
set PB=%2
if "%PB%"=="" set PB=49150
set PD=%3
if "%PD%"=="" set PD=300
REM pcstall.memh: "THRESH DELAY" -- read by the TB (+PCSTALL) and by stallcheck
> pcstall.memh echo %PB% %PD%

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p5b_acc2 burst %NB% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d RTOLIM_STALL ^
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
  D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_cfg_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v ^
  D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

REM frame_fifo holds RAMB36E1/RAMB18E1 prims -> xelab needs -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall -testplusarg PCACK -testplusarg PCSTALL -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p5b_acc2 stallcheck %NB%
