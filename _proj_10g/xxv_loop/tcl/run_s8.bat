@echo off
REM run_s4.bat -- READ-ONLY interface interrogation of the routed xxv_loop design.
REM   Opens the project + routed checkpoint only. No build, no programming.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s8_rst
call %VIV% -mode batch -source s8_rst_clk.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S4_" ..\logs\s8_rst_stdout.txt
exit /b %RC%
