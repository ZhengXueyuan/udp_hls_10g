@echo off
REM run_tb_p4_burst.bat -- P4b-5/6 debug: N x 1460B line-rate burst
REM   usage (Git Bash): cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat [N [pause_at pause_len [wnd_hex]]]'
REM   %1 = burst segment count (default 200)
REM   %2/%3 = pause_at/pause_len (cycles, optional; that segment becomes 352B,
REM           next segment gets the long pre-gap) -- PC send pause-resume
REM          (P4b-7 convention: %2==0 and %3==0 = no pause, same as -1 0;
REM          %2==0 with %3>0 still pauses at segment 0)
REM   %4 = burst advertised window in hex (default 4000); =10 also sets
REM        +PCWND1K (raw 0010 << wscale8 = effective 4096, gate stress)
REM   %5/%6 = forwarded gen_stim tail args (608 / dup), keeps positional layout
REM   %7/%8 = TXDROP/TXDROP2 (P4b-7 fault injection: drop conn0 data frame
REM           #%7 and #%8 from the GMII capture; 0/empty = no drop); also
REM           forwarded to burstcheck which asserts RETX == expected sessions
REM   TRUNC/TRUNCM = P4b-7-P6 truncated-frame injection (env vars, since %1..%8
REM           are taken): at conn0 data frame #TRUNC replace the frame with the
REM           same header (seq / IP total_len=1500 / TCP hdr / sport) but only
REM           TRUNCM payload bytes and a recomputed FCS -- the on-board PC/NIC
REM           truncation that froze the stack. TRUNC=0 = off, TRUNCM needs
REM           6..10 (60B min-frame padding below 6), default 8.
REM   P4b-6: always runs with +PCACK (window gating needs ACK injection to
REM          advance snd_una, otherwise the gate deadlocks the echo)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog
set NB=%1
if "%NB%"=="" set NB=200
set PAUSE=
if "%2"=="-1" set PAUSE=-1 0
if not "%2"=="" if not "%2"=="0" if not "%2"=="-1" set PAUSE=%2 %3
if "%2"=="0" if not "%3"=="" if not "%3"=="0" set PAUSE=0 %3
if "%2"=="0" if "%3"=="0" set PAUSE=-1 0
set WND=
if not "%4"=="" set WND=%4
set XTRA=
if not "%5"=="" set XTRA=%5 %6
set XPA=-testplusarg PCACK
if "%4"=="10" set XPA=-testplusarg PCACK -testplusarg PCWND1K
REM TXDROP/TXDROP2 reach the TB via txdrop.memh (%7/%8 written here):
REM xsim.bat's loader splits any arg containing '=' ("Expected a switch
REM but found 5"), so -testplusarg TXDROP=N never arrives. File channel
REM avoids '=' entirely; TB $fscanf reads the two indices (default 0).
if not "%7"=="" > txdrop.memh echo %7
if not "%8"=="" >> txdrop.memh echo %8
if "%7"=="" if "%8"=="" if exist txdrop.memh del /q txdrop.memh
REM P4b-7-P6 TRUNC/TRUNCM reach the TB and gen_stim via trunc.memh (same loader
REM reason); always rewritten so a stale file never leaks into a plain run.
if "%TRUNC%"=="" set TRUNC=0
if "%TRUNCM%"=="" set TRUNCM=8
> trunc.memh echo %TRUNC% %TRUNCM%
REM P4b-7-P6 HALFDROP/HALFDROPK = half-frame abort injection (env vars, same
REM file channel as TRUNC): at conn0 data frame #HALFDROP the line carries the
REM 54B header + only HALFDROPK payload bytes, then stops (no FCS, no tlast) --
REM the on-board PC/NIC TX-DMA half frame that froze the stack. The TB masks
REM that frame's tlast beat at the mac_rx output (halfdrop.memh "N K", also
REM read by gen_stim/burstcheck). K needs 6..plen-1 and (50+K)%8==0 (K=6 mod 8).
REM HALFDROP=0 = off. Always rewritten (stale file never leaks into a run).
if "%HALFDROP%"=="" set HALFDROP=0
if "%HALFDROPK%"=="" set HALFDROPK=0
> halfdrop.memh echo %HALFDROP% %HALFDROPK%

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim burst %NB% %PAUSE% %WND% %XTRA% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d RTOLIM_FAST ^
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
  D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_cfg_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v ^
  D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

REM P4b-7-P6: frame_fifo holds RAMB36E1/RAMB18E1 prims -> xelab needs -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall %XPA% -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)
if exist txdrop.memh del /q txdrop.memh

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_stim_p4_chain.py D:\repo\ECO\udp_hls_10g\sim\p4sim burstcheck %NB% %7 %8
