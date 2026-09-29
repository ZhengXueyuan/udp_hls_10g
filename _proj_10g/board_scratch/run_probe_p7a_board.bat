@echo off
REM run_probe_p7a_board.bat -- P7a BOARD acceptance run (PROGRAMS THE FPGA, volatile only)
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\board_scratch\run_probe_p7a_board.bat'
REM   Optional env: P7A_SECS P7A_SHORT P7A_BIT P7A_HWURL P7A_ALLOW_SHORT_ERR
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
if not exist logs mkdir logs
if "%P7A_SECS%"=="" set P7A_SECS=600
if "%P7A_SHORT%"=="" set P7A_SHORT=60
echo P7A_SECS=%P7A_SECS% P7A_SHORT=%P7A_SHORT%
call %VIV% -mode batch -source probe_p7a_board.tcl -log logs\p7a_board.log -journal logs\p7a_board.jou > logs\p7a_board_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
type logs\p7a_board_stdout.txt
exit /b %RC%
