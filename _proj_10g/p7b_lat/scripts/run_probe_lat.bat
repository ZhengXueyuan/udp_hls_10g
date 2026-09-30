@echo off
REM run_probe_lat.bat -- board phase of the P7b segmented latency measurement.
REM   PROGRAMS THE FPGA over JTAG (volatile only; never QSPI).
REM   from Git Bash: cmd //c '_proj_10g\p7b_lat\scripts\run_probe_lat.bat'
setlocal
cd /d %~dp0
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VV%" -mode batch -source "%~dp0probe_lat.tcl" -nojournal -nolog > "%~dp0..\p7b_lat_probe_stdout.txt" 2>&1
echo PROBE_EXIT=%ERRORLEVEL%
findstr /B /C:"LAT" "%~dp0..\p7b_lat_probe_stdout.txt"
exit /b 0
