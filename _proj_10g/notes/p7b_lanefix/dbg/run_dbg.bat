@echo off
REM run_dbg.bat - scratch debug run for the lane4 re-alignment work (NOT a gate).
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set MACD=%ROOT%\_proj_10g\p7b_mac\rtl
if not "%P7B_MUT%"=="" set MACD=%P7B_MUT%
if exist xsim.dir rmdir /s /q xsim.dir
del /q xsim_dbg.log 2>NUL
call %XV%\xvlog.bat -work xil_defaultlib -i %MACD% %MACD%\crc32_64.v %MACD%\mac_rx_10g.v %ROOT%\rtl\fifo_sync.v tb_lane4_dbg.v > xvlog_dbg.log 2>&1 || (type xvlog_dbg.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_dbg.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_dbg.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_lane4_dbg -s tb_lane4_dbg -log xelab_dbg.log > NUL 2>&1 || (type xelab_dbg.log & exit /b 1)
call %XV%\xsim.bat tb_lane4_dbg -runall -log xsim_dbg.log > NUL 2>&1
type xsim_dbg.log
exit /b 0
