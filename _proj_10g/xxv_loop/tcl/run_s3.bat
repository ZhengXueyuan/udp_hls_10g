@echo off
REM run_s3.bat -- P7b gate-1 xxv_loop stage 3: program over JTAG + take readings.
REM   Volatile JTAG programming only -- NEVER the on-board QSPI.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s3_probe
call %VIV% -mode batch -source s3_probe.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S3_" /C:"ERROR:" /C:"Fatal" ..\logs\s3_probe_stdout.txt
exit /b %RC%
