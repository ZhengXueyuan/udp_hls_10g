@echo off
REM run_s4.bat -- P7b stage 4: full synth + impl + write_bitstream for BOTH cores.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s4_build
call %VIV% -mode batch -source s4_build.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S4_VERDICT" /C:"S4_LICLINE" /C:"S4_TIMING " /C:"S4_UTIL " /C:"S4_BIT " /C:"S4_SYNTH_STATUS" /C:"S4_IMPL_STATUS" /C:"S4_IMPL_PROGRESS" /C:"Fatal" /C:"ERROR:" ..\logs\s4_build_stdout.txt
exit /b %RC%
