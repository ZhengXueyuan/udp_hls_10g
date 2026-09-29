@echo off
REM run_readback_p7a.bat -- P7a static criteria 1/2/3, read from the routed checkpoint
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\tcl\run_readback_p7a.bat'
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
call %VIV% -mode batch -source readback_p7a.tcl -log ..\reports\p7a_readback.log -journal ..\reports\p7a_readback.jou > ..\reports\p7a_readback_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
exit /b %RC%
