@echo off
REM run_fence_neg.bat -- counterfactual: run the READ-ONLY P5c-T3 fence TB
REM (sim\p5c_t3\tb_p5c_fence.v, never modified) against the P5d-D1
REM NEGATIVE RTL copy (rst_req term removed from tx_blk) to prove that the F5
REM failure of the canonical fence gate is caused by exactly that one term.
REM ASCII only. Exit: 0 = fence PASS, 1 = fence FAIL, 2 = tool error.
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\sim\p5d_d1neg\neg_rst\rtl
set T3=D:\repo\ECO\udp_hls_10g\sim\p5c_t3
set D1=D:\repo\ECO\udp_hls_10g\sim\p5d_d1\fenceneg
cd /d %D1%
rmdir /s /q xsim.dir 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_tx_frame.v %T3%\tb_p5c_fence.v > xvlog_fn.log 2>&1
if errorlevel 1 (type xvlog_fn.log & exit /b 2)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_p5c_fence -s tb_p5c_fence -log xelab_fn.log > NUL 2>&1
if errorlevel 1 (type xelab_fn.log & exit /b 2)
call "%VIV_BIN%\xsim.bat" tb_p5c_fence -runall -log xsim_fn.log > NUL 2>&1
if errorlevel 1 (type xsim_fn.log & exit /b 2)
findstr /c:"GATE tb_p5c_fence: PASS" xsim_fn.log >nul
if not errorlevel 1 (echo FENCE-NEG PASS & exit /b 0)
echo FENCE-NEG FAIL & findstr /c:"FAIL" xsim_fn.log & exit /b 1
