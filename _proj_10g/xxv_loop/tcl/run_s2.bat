@echo off
REM run_s2.bat -- P7b gate-1 xxv_loop stage 2: synth + impl + write_bitstream.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s2_build
call %VIV% -mode batch -source s2_build.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S2_" /C:"ERROR:" /C:"Fatal" ..\logs\s2_build_stdout.txt
exit /b %RC%
