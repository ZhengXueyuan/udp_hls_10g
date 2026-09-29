@echo off
setlocal
rem ===========================================================================
rem run_tb_rxcls_v2.bat -- P7B rx_classify v2 unit gate (throughput + fidelity)
rem   compile: rx_classify_v2.v (v2) + rx_classify_ref.v (v1 golden copy)
rem            + repo rtl/fifo_sync.v + tb_rxcls_v2.v
rem   verdict: TB prints "VERDICT = PASS"
rem   P7B_RXCLS_RTL overrides the v2 RTL dir (mutation runs point it at a copy)
rem NOTE: ASCII only (project bat pitfall: non-ASCII comments break GBK console).
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
if defined P7B_RXCLS_RTL set RTLDIR=%P7B_RXCLS_RTL%
echo [P7B RXCLS GATE] v2 RTL = %RTLDIR%
rem fail-closed: a mistyped/trailing-space P7B_RXCLS_RTL must not fall through to a
rem confusing xvlog error (and must never silently compile some other tree)
if not exist "%RTLDIR%\rx_classify_v2.v" (
  echo [PATHGUARD FAIL] no rx_classify_v2.v under "%RTLDIR%"
  exit /b 1
)
if exist xsim.dir rmdir /s /q xsim.dir
rem a stale xsim log would let a non-started/failed xsim pass the findstr below
if exist xsim_rxcls.log del xsim_rxcls.log
set IMPKEY=/C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared"
call %XV%\xvlog.bat -work xil_defaultlib %RTLDIR%\rx_classify_v2.v %~dp0rx_classify_ref.v %REPO_ROOT%\rtl\fifo_sync.v tb_rxcls_v2.v > xvlog_rxcls.log 2>&1 || (type xvlog_rxcls.log & exit /b 1)
findstr /I %IMPKEY% xvlog_rxcls.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xvlog: & findstr /I %IMPKEY% xvlog_rxcls.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_rxcls_v2 -s tb_rxcls_v2 -log xelab_rxcls.log > NUL 2>&1 || (type xelab_rxcls.log & exit /b 1)
findstr /I %IMPKEY% xelab_rxcls.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I %IMPKEY% xelab_rxcls.log & exit /b 1)
call %XV%\xsim.bat tb_rxcls_v2 -runall -log xsim_rxcls.log > NUL 2>&1
findstr /C:"VERDICT = PASS" xsim_rxcls.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"[FAIL]" /C:"VERDICT" /C:"Error" xsim_rxcls.log & exit /b 1)
findstr /C:"=== tb_rxcls_v2 done" xsim_rxcls.log
exit /b 0
