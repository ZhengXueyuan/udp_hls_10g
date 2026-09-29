@echo off
REM run_read_state_only.bat -- READ-ONLY P7a state dump (never programs)
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\board_scratch\run_read_state_only.bat'
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
call %VIV% -mode batch -source read_state_only.tcl -log logs\p7a_readstate.log -journal logs\p7a_readstate.jou > logs\p7a_readstate_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
type logs\p7a_readstate_stdout.txt
exit /b %RC%
