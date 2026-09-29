@echo off
REM run_s2.bat -- P7b stage 2: create the two xxv_ethernet probes and nail the config.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s2_config
call %VIV% -mode batch -source s2_config.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S2_" /C:"  RB " /C:"  GT " /C:"ENUM " ..\logs\s2_config_stdout.txt
exit /b %RC%
