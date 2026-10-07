@echo off
setlocal
REM =====================================================================
REM run_mc6_probe.bat -- adversarial review (C): targeted M-C6 stimulus
REM   A = current rtl/tcp_tx_frame.v     (fixed; expect data_seqF_1B = 0)
REM   B = mut_c6.v (rewind gate removed; expect data_seqF_1B >= 1)
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "TB=%HERE%\tb_mc6b_probe.v"
set "MUT=%ROOT%\sim\p7b_stagec_tx\mut\mut_c6.v"
if not exist "%MUT%" (echo [FAIL] mut_c6.v missing & exit /b 1)
cd /d "%HERE%"

call :run A "%RTL%\tcp_tx_frame.v"
set RCA=%errorlevel%
call :run B "%MUT%"
set RCB=%errorlevel%
echo ==================== MC6 PROBE SUMMARY ====================
echo   A fixed RTL RC=%RCA%   B M-C6 mutant RC=%RCB%
exit /b 0

:run
set "NAME=%~1"
set "RSRC=%~2"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib -d TCP_TX_OVL "%RSRC%" "%RTL%\tcb.v" "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\retx_ram.v" "%TB%" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_mc6b_probe -s mc6b -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" mc6b -runall -log xs.log > xs_out.log 2>&1
echo   ---- [%NAME%] ----
findstr /C:"MC6BPROBE" xs.log
findstr /C:"PROBE" xs.log
findstr /C:"FRAME" xs.log
findstr /C:"SVC" xs.log
findstr /C:"RING" xs.log
findstr /C:"TCBW" xs.log
findstr /C:"STACK" xs.log
popd
exit /b 0
