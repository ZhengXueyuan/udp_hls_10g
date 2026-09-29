@echo off
REM run_s4.bat -- READ-ONLY interface interrogation of the routed xxv_loop design.
REM   Opens the project + routed checkpoint only. No build, no programming.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s9_fan
call %VIV% -mode batch -source s9_fanout.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S4_" ..\logs\s9_fan_stdout.txt
exit /b %RC%
