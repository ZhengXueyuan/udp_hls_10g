@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\XCKU5PMini\udp_hls_10g\rtl
cd /d %~dp0\run_mut_eq
if exist xsim.dir rmdir /s /q xsim.dir
del /q xsim.log eq_frames.txt eq_busy.txt eq_events.txt 2>NUL
call %XV%\xvlog.bat -work xil_defaultlib -d DUMP_TRACE -d UDP_TX_OVL "%~dp0mut_single_bank\udp_tx_frame.v" "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\udp_tx_cfg.v" "%~dp0tb_ovl_eq.v" > xvlog_meq.log 2>&1 || (type xvlog_meq.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_ovl_eq -s tb_ovl_eq -log xelab_meq.log > NUL 2>&1 || (type xelab_meq.log & exit /b 1)
call %XV%\xsim.bat tb_ovl_eq -runall > NUL 2>&1
echo ---- MUTANT EQ (字节输出是否仍与默认一致) ----
findstr /C:"WIRE frames" /C:"BUSY VIOL" /C:"DENY" /C:"TOTAL CYCLES" /C:"OVL EQ GATE" xsim.log
exit /b 0
