@echo off
setlocal
rem ===========================================================================
rem run_tb_mac_10g.bat -- P7b 64-bit XGMII MAC unit gate (self-checking TB)
rem   compile: crc32_64.v + mac_rx_10g.v + mac_tx_10g.v (+ rtl/fifo_sync.v) + tb
rem   verdict: TB prints "VERDICT = PASS"
rem   P7B_RTL env var overrides the RTL dir (mutation runs point it at a copy)
rem NOTE: ASCII only (project bat pitfall: non-ASCII comments break the GBK console).
rem ===========================================================================
set REPO_ROOT=%~dp0..\..\..
for %%I in ("%REPO_ROOT%") do set REPO_ROOT=%%~fI
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  exit /b 1
)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTLDIR=%~dp0..\rtl
if defined P7B_RTL set RTLDIR=%P7B_RTL%
echo [P7B MAC GATE] RTL = %RTLDIR%
if exist xsim.dir rmdir /s /q xsim.dir
set IMPKEY=/C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared"
call %XV%\xvlog.bat -work xil_defaultlib -i %RTLDIR% ^
  %RTLDIR%\crc32_64.v %RTLDIR%\mac_rx_10g.v %RTLDIR%\mac_tx_10g.v ^
  %REPO_ROOT%\rtl\fifo_sync.v ^
  tb_mac_10g.v > xvlog_m10g.log 2>&1 || (type xvlog_m10g.log & exit /b 1)
findstr /I %IMPKEY% xvlog_m10g.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xvlog: & findstr /I %IMPKEY% xvlog_m10g.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_mac_10g -s tb_mac_10g -log xelab_m10g.log > NUL 2>&1 || (type xelab_m10g.log & exit /b 1)
findstr /I %IMPKEY% xelab_m10g.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I %IMPKEY% xelab_m10g.log & exit /b 1)
call %XV%\xsim.bat tb_mac_10g -runall -log xsim_m10g.log > NUL 2>&1
findstr /C:"VERDICT = PASS" xsim_m10g.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"[FAIL]" /C:"VERDICT" /C:"Error" xsim_m10g.log & exit /b 1)
findstr /C:"=== tb_mac_10g done" /C:"VERDICT = PASS" xsim_m10g.log
exit /b 0
