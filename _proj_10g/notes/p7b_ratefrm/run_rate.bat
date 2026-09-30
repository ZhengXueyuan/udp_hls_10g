@echo off
REM =====================================================================
REM run_rate.bat -- frame-period gate for both builds (default / UDP_TX_OVL)
REM   tb_rate_frame.v = verbatim copy of _proj_10g\notes\p7b_rate\tb_lvl_frame.v
REM   tb_rate_chain.v = same source + real tx_arb + real mac_tx_10g
REM Usage: run_rate.bat [def|ovl]
REM =====================================================================
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "MAC=%ROOT%\_proj_10g\p7b_mac\rtl"
set "MODE=%1"
if "%MODE%"=="" goto :both
if /i "%MODE%"=="def" goto :def
if /i "%MODE%"=="ovl" goto :ovl
echo usage: run_rate.bat [def^|ovl] & exit /b 97

:both
call "%~f0" def || exit /b 1
call "%~f0" ovl || exit /b 1
exit /b 0

:def
cd /d "%HERE%\run_rate_def"
if exist xsim.dir rmdir /s /q xsim.dir
del /q xsim_f.log xsim_c.log 2>NUL
call "%XV%\xvlog.bat" -work xil_defaultlib "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" ^
  "%RTL%\udp_tx_frame.v" "%RTL%\tx_arb.v" ^
  "%MAC%\crc32_64.v" "%MAC%\mac_tx_10g.v" ^
  "%HERE%\tb_rate_frame.v" "%HERE%\tb_rate_chain.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_lvl_frame -s tb_lvl_frame -log xelab_f.log > NUL 2>&1 || (type xelab_f.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_rate_chain -s tb_rate_chain -log xelab_c.log > NUL 2>&1 || (type xelab_c.log & exit /b 1)
call "%XV%\xsim.bat" tb_lvl_frame -runall -log xsim_f.log > NUL 2>&1
call "%XV%\xsim.bat" tb_rate_chain -runall -log xsim_c.log > NUL 2>&1
echo ---- RATE [DEFAULT build] : tb_rate_frame ----
findstr /C:"clk period" /C:"frames measured" /C:"MEAN FRAME" /C:"PAYLOAD RATE" /C:"WIRE-CONTENT" /C:"DONE" xsim_f.log
echo ---- RATE [DEFAULT build] : tb_rate_chain (framer+arb+mac) ----
findstr /C:"clk period" /C:"XGMII frames" /C:"mac tx_words" /C:"MEAN FRAME" /C:"PAYLOAD RATE" /C:"WIRE-CONTENT" /C:"DONE" xsim_c.log
exit /b 0

:ovl
cd /d "%HERE%\run_rate_ovl"
if exist xsim.dir rmdir /s /q xsim.dir
del /q xsim_f.log xsim_c.log 2>NUL
call "%XV%\xvlog.bat" -work xil_defaultlib -d UDP_TX_OVL "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" ^
  "%RTL%\udp_tx_frame.v" "%RTL%\tx_arb.v" ^
  "%MAC%\crc32_64.v" "%MAC%\mac_tx_10g.v" ^
  "%HERE%\tb_rate_frame.v" "%HERE%\tb_rate_chain.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_lvl_frame -s tb_lvl_frame -log xelab_f.log > NUL 2>&1 || (type xelab_f.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_rate_chain -s tb_rate_chain -log xelab_c.log > NUL 2>&1 || (type xelab_c.log & exit /b 1)
call "%XV%\xsim.bat" tb_lvl_frame -runall -log xsim_f.log > NUL 2>&1
call "%XV%\xsim.bat" tb_rate_chain -runall -log xsim_c.log > NUL 2>&1
echo ---- RATE [UDP_TX_OVL build] : tb_rate_frame ----
findstr /C:"clk period" /C:"frames measured" /C:"MEAN FRAME" /C:"PAYLOAD RATE" /C:"WIRE-CONTENT" /C:"DONE" xsim_f.log
echo ---- RATE [UDP_TX_OVL build] : tb_rate_chain (framer+arb+mac) ----
findstr /C:"clk period" /C:"XGMII frames" /C:"mac tx_words" /C:"MEAN FRAME" /C:"PAYLOAD RATE" /C:"WIRE-CONTENT" /C:"DONE" xsim_c.log
exit /b 0
