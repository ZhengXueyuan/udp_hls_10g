@echo off
REM run_probe_p7a.bat -- P7a board observation over JTAG (PROGRAMS THE FPGA)
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\obs\run_probe_p7a.bat'
REM   Optional: set P7A_SECS / P7A_BIT / P7A_HWURL before calling.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
if "%P7A_SECS%"=="" set P7A_SECS=30
call %VIV% -mode batch -source probe_p7a.tcl -log ..\reports\p7a_probe.log -journal ..\reports\p7a_probe.jou > ..\reports\p7a_probe_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
type ..\reports\p7a_probe_stdout.txt
exit /b %RC%
