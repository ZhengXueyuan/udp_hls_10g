@echo off
REM run_s3.bat -- P7b stage 3: generate + dump the IP example designs.
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s3_example
call %VIV% -mode batch -source s3_example.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S3_" ..\logs\s3_example_stdout.txt
exit /b %RC%
