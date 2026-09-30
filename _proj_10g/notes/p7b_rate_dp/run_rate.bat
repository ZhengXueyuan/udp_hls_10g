@echo off
setlocal enabledelayedexpansion
rem ===========================================================================
rem run_rate.bat -- P7B 10G data-path RATE accounting harness (independent).
rem   READ-ONLY: compiles pre-existing RTL from rtl/ and _proj_10g/p7b_mac/rtl/.
rem   Nothing under rtl/ or tb/ is modified.
rem   usage:  run_rate.bat chain [NW] [CYCLES]
rem           run_rate.bat mac   [L]  [CYCLES]
rem           run_rate.bat rxc   [FW] [CYCLES] [TCP]
rem   Self-locating (refuses to run if this checkout cannot be located).
rem NOTE: ASCII only, CRLF line endings.
rem ===========================================================================
set "REPO_ROOT=%~dp0..\..\.."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)
if not exist "%REPO_ROOT%\rtl\rx_classify.v" (
  echo [PATHGUARD FAIL] rtl\ not under %REPO_ROOT%
  exit /b 1
)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set MACRTL=%REPO_ROOT%\_proj_10g\p7b_mac\rtl

set MODE=%1
if "%MODE%"=="" set MODE=chain

if /I "%MODE%"=="chain" goto :chain
if /I "%MODE%"=="mac"   goto :mac
if /I "%MODE%"=="rxc"   goto :rxc
if /I "%MODE%"=="tcp"   goto :tcp
echo [FAIL] unknown mode %MODE%
exit /b 1

:tcp
set P1=183
if not "%2"=="" set P1=%2
set P2=200000
if not "%3"=="" set P2=%3
set TBNAME=tb_rate_tcp_chain
if exist xsim_tcp rmdir /s /q xsim_tcp
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_tx_frame.v ^
  %RTL%\tx_arb.v %MACRTL%\crc32_64.v %MACRTL%\mac_tx_10g.v ^
  tb_rate_tcp_chain.v > xvlog_tcp.log 2>&1 || (type xvlog_tcp.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.%TBNAME% -s %TBNAME% ^
  -log xelab_tcp.log > NUL 2>&1 || (type xelab_tcp.log & exit /b 1)
call %XV%\xsim.bat %TBNAME% -runall -log xsim_tcp.log ^
  -testplusarg "NW=%P1%" -testplusarg "CYCLES=%P2%" > NUL 2>&1
findstr /C:"TCPRATE " xsim_tcp.log
exit /b 0

:chain
set P1=184
if not "%2"=="" set P1=%2
set P2=200000
if not "%3"=="" set P2=%3
set P3=8
if not "%4"=="" set P3=%4
set P4=183
if not "%5"=="" set P4=%5
set TBNAME=tb_rate_udp_chain
if exist xsim_chain rmdir /s /q xsim_chain
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\udp_tx_frame.v %RTL%\udp_tx_cfg.v ^
  %RTL%\tx_arb.v %MACRTL%\crc32_64.v %MACRTL%\mac_tx_10g.v ^
  tb_rate_udp_chain.v > xvlog_chain.log 2>&1 || (type xvlog_chain.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.%TBNAME% -s %TBNAME% ^
  -log xelab_chain.log > NUL 2>&1 || (type xelab_chain.log & exit /b 1)
call %XV%\xsim.bat %TBNAME% -runall -log xsim_chain.log ^
  -testplusarg "NW=%P1%" -testplusarg "CYCLES=%P2%" -testplusarg "LASTK=%P3%" -testplusarg "TNW=%P4%" > NUL 2>&1
findstr /C:"RATE " xsim_chain.log
exit /b 0

:mac
set P1=60
if not "%2"=="" set P1=%2
set P2=20000
if not "%3"=="" set P2=%3
set TBNAME=tb_rate_mac
if exist xsim_mac rmdir /s /q xsim_mac
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %MACRTL%\crc32_64.v %MACRTL%\mac_tx_10g.v ^
  tb_rate_mac.v > xvlog_mac.log 2>&1 || (type xvlog_mac.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.%TBNAME% -s %TBNAME% ^
  -log xelab_mac.log > NUL 2>&1 || (type xelab_mac.log & exit /b 1)
call %XV%\xsim.bat %TBNAME% -runall -log xsim_mac.log ^
  -testplusarg "L=%P1%" -testplusarg "CYCLES=%P2%" > NUL 2>&1
findstr /C:"MAC " xsim_mac.log
exit /b 0

:rxc
set P1=8
if not "%2"=="" set P1=%2
set P2=20000
if not "%3"=="" set P2=%3
set P3=1
if not "%4"=="" set P3=%4
set TBNAME=tb_rate_rxc
if exist xsim_rxc rmdir /s /q xsim_rxc
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %RTL%\rx_classify.v ^
  tb_rate_rxc.v > xvlog_rxc.log 2>&1 || (type xvlog_rxc.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.%TBNAME% -s %TBNAME% ^
  -log xelab_rxc.log > NUL 2>&1 || (type xelab_rxc.log & exit /b 1)
call %XV%\xsim.bat %TBNAME% -runall -log xsim_rxc.log ^
  -testplusarg "FW=%P1%" -testplusarg "CYCLES=%P2%" -testplusarg "TCP=%P3%" > NUL 2>&1
findstr /C:"RXC " xsim_rxc.log
exit /b 0
