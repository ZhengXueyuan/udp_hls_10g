@echo off
REM run_xdc_probe.bat -- raw evidence for the XDC command-support defect (20-1307)
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
call %VIV% -mode batch -source xdc_cmd_support_probe.tcl -log ..\reports\p7a_xdc_probe.log -journal ..\reports\p7a_xdc_probe.jou > ..\reports\p7a_xdc_probe_stdout.txt 2>&1
echo ---- vivado exit=%ERRORLEVEL% ----
findstr /C:"20-1307" ..\reports\p7a_xdc_probe_stdout.txt
exit /b 0
