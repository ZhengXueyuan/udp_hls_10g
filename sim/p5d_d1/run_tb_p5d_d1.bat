@echo off
REM ============================================================
REM p5d_d1 -- P5d-D1 directed gate: TX start/accept gate gaps
REM   Unit level (tcp_tx_frame only). Judges the AXIS frame stream only:
REM   D1a baseline data frame (no request) / D1b abort window (rst_req=1,
REM   before the RST hits the wire: tready must stay 0, no data frame) /
REM   D1c release (clear rst_req + cfg_up -> frame resumes, bytes exact) /
REM   D2 residual window (clear fin_req[1] AT the fin_push beat + rb_state=0:
REM   no data frame before the FIN) / D2b release (rb_state=1 + cfg_up).
REM   Two negative controls live in sim\p5d_d1neg\<neg>\ (mkneg.py):
REM     neg_rst : remove the rst_req term from tx_blk  -> D1b must FAIL
REM     neg_st  : force the ESTAB term to constant 1   -> D2 must FAIL
REM Usage: cmd //c "D:\repo\ECO\udp_hls_10g\sim\p5d_d1\run_tb_p5d_d1.bat"
REM Exit : 0 = GATE PASS, 1 = GATE FAIL, 2 = tool error / no verdict
REM NOTE: must be compiled with -d APP_MODE (board P5 build) -- the fix-2
REM       ESTAB gate only exists in that build (see rtl\tcp_tx_frame.v).
REM NOTE: ASCII only on purpose (UTF-8 comments in a .bat get re-paired as
REM       GBK and eat the CR -- the comment line is then run as a command).
REM ============================================================
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set T5=D:\repo\ECO\udp_hls_10g\sim\p5d_d1
cd /d %T5%
rmdir /s /q xsim.dir 2>nul
del /q tb_p5d_d1.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib -d APP_MODE %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_tx_frame.v %T5%\tb_p5d_d1.v > xvlog_p5d.log 2>&1
if errorlevel 1 (type xvlog_p5d.log & exit /b 2)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_p5d_d1 -s tb_p5d_d1 -log xelab_p5d.log
if errorlevel 1 (type xelab_p5d.log & exit /b 2)
call "%VIV_BIN%\xsim.bat" tb_p5d_d1 -runall -log xsim_p5d.log
if errorlevel 1 (type xsim_p5d.log & exit /b 2)
findstr /c:"GATE tb_p5d_d1: PASS" xsim_p5d.log >nul
if not errorlevel 1 (echo P5D-D1 GATE PASS & exit /b 0)
findstr /c:"GATE tb_p5d_d1: FAIL" xsim_p5d.log >nul
if not errorlevel 1 (echo P5D-D1 GATE FAIL & findstr /c:"FAIL" xsim_p5d.log & exit /b 1)
echo no verdict line in xsim_p5d.log & type xsim_p5d.log & exit /b 2
