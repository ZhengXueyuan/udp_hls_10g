@echo off
REM run_s1.bat -- P7b stage 1: create the two xxv_ethernet probe projects + dump metadata.
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\xxv_probe\tcl\run_s1.bat'
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s1_prepare
call %VIV% -mode batch -source s1_prepare.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S1_" /C:"CFG_pcs64" /C:"CFG_macpcs64" /C:"Fatal" /C:"ERROR" ..\logs\s1_prepare_stdout.txt
exit /b %RC%
