@echo off
setlocal
REM =====================================================================
REM run_flood_probe.bat -- production-legal repro attempt (trivial session + FIN +1)
REM   A = OVL fixed RTL      (macro on)
REM   B = OVL mut_c6         (macro on)
REM   C = default serial RTL (macro off, ARM_SERIAL)
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "TB=%HERE%\tb_ovl_flood_probe.v"
set "MUT=%ROOT%\sim\p7b_stagec_tx\mut\mut_c6.v"
cd /d "%HERE%"

call :run A "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL"
call :run B "%MUT%" "-d TCP_TX_OVL"
call :run C "%RTL%\tcp_tx_frame.v" "-d ARM_SERIAL"
call :run D "%RTL%\tcp_tx_frame.v" "-d ARM_SERIAL -d FINPUSH_SYNC"
echo ==================== FLOOD PROBE SUMMARY ====================
for %%M in (A B C D) do (
  echo   [%%M]:
  findstr /C:"FLOODPROBE " "run%%M\xs.log"
  findstr /C:"PROBE" "run%%M\xs.log"
  findstr /C:"FRAME" "run%%M\xs.log"
)
exit /b 0

:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "%RTL%\tcb.v" "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\retx_ram.v" "%TB%" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_ovl_flood_probe -s flood -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" flood -runall -log xs.log > xs_out.log 2>&1
popd
exit /b 0
