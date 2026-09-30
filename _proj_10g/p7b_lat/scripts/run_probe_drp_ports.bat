@echo off
REM run_probe_drp_ports.bat -- can the GT DRP ports be enabled on xxv_ethernet?
REM   Read-only w.r.t. the real build (own throwaway project dir).
setlocal
cd /d %~dp0
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VV%" -mode batch -source "%~dp0probe_drp_ports.tcl" -nojournal -nolog > "%~dp0drp_probe_stdout.txt" 2>&1
echo DRPPROBE_EXIT=%ERRORLEVEL%
findstr /B /C:"DRPP_" "%~dp0drp_probe_stdout.txt"
exit /b 0
