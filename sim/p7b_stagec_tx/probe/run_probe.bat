@echo off
setlocal
REM Flood-probe arms: A=OVL fixed (NOFLOOD) B=mut_f1 (FLOOD) C=default serial (NOFLOOD)
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
cd /d "%HERE%"
call :run A "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL"
call :run B "%ROOT%\sim\p7b_stagec_tx\mut\mut_f1.v" "-d TCP_TX_OVL"
call :run C "%RTL%\tcp_tx_frame.v" ""
echo ==================== FLOOD PROBE SUMMARY ====================
for %%M in (A B C) do (
  echo   [%%M]:
  findstr /C:"FLOODPROBE" "run%%M\xs.log"
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
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "%RTL%\tcb.v" "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\retx_ram.v" "%HERE%\tb_flood_probe.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_flood_probe -s flood -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" flood -runall -log xs.log > xs_out.log 2>&1
popd
exit /b 0
