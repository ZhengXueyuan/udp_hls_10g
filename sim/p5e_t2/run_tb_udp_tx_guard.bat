@echo off
REM run_tb_udp_tx_guard.bat -- P5e-T2 UDP app TX unit gate (self-checking TB, no Python)
REM chain: app AXIS -> udp_tx_cfg (peer latch + enable gate) -> udp_tx_frame
REM        (PLEN_MAX length guard) -> tx_arb (reused as-is)
REM criteria: default-no-send, 1500 pass / 1501 abort / 4096 (>FIFO 2048B) abort with
REM            no lockup, cfg latch stable-in-frame & variable-between-frames,
REM            byte/checksum exactness, zero-length datagram, and a built-in
REM            NEGATIVE CONTROL (same 4096B frame on an unguarded instance
REM            = defparam PLEN_MAX=4095 must deadlock: payload FIFO full, no tlast).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\udp_tx_frame.v %RTL%\udp_tx_cfg.v ^
  %RTL%\tx_arb.v ^
  %TB%\tb_udp_tx_guard.v > xvlog_g.log 2>&1 || (type xvlog_g.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_udp_tx_guard -s tb_udp_tx_guard -log xelab_g.log > NUL 2>&1 || (type xelab_g.log & exit /b 1)
call %XV%\xsim.bat tb_udp_tx_guard -runall -log xsim_g.log > NUL 2>&1 || (type xsim_g.log & exit /b 1)

findstr /C:"P5E-T2 GUARD GATE: OK" xsim_g.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"FAIL" xsim_g.log & exit /b 1)
findstr /C:"P5E-T2 GUARD GATE" xsim_g.log
exit /b 0
