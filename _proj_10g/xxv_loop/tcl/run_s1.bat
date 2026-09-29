@echo off
REM run_s1.bat -- P7b gate-1 xxv_loop stage 1: create the TWO-CHANNEL xxv_ethernet
REM   PCS/PMA-64 project, nail its configuration, dump ports + subcore readback.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s1_prepare
call %VIV% -mode batch -source s1_prepare.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S1_" /C:"  RB " /C:"ENUM " /C:"XCI " /C:"  GT " /C:"VEO " /C:"XDC " ..\logs\s1_prepare_stdout.txt
exit /b %RC%
