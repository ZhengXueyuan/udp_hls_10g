@echo off
REM run_build_p7b_lat.bat -- P7b + P7B_LAT probes + VIO (own project: p7b_lat_prj)
REM   THIS SCRIPT DOES NOT PROGRAM THE BOARD (no program_hw_devices, no QSPI).
REM   from Git Bash: cmd //c '_proj_10g\p7b_lat\scripts\run_build_p7b_lat.bat'
setlocal
cd /d %~dp0
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VV%" -mode batch -source "%~dp0build_p7b_lat_ku5p.tcl" -nojournal -nolog > "%~dp0..\p7b_lat_build_stdout.txt" 2>&1
echo BUILD_EXIT=%ERRORLEVEL%

REM ---- hard gates (a hit is a FAILURE, not a note) --------------------------
findstr /I /C:"12-4739" "%~dp0..\p7b_lat_build_stdout.txt" >NUL && (echo DROPPED-CONSTRAINT-FAIL & findstr /I /C:"12-4739" "%~dp0..\p7b_lat_build_stdout.txt")
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" "%~dp0..\p7b_lat_build_stdout.txt" >NUL && (echo IMPLICIT-NET-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" "%~dp0..\p7b_lat_build_stdout.txt")
findstr /I /C:"NSTD-1" /C:"UCIO-1" /C:"AVAL-326" /C:"Opt 31-155" /C:"Opt 31-67" /C:"Route 35-7" /C:"LUTLP-1" /C:"MDRV-1" "%~dp0..\p7b_lat_build_stdout.txt" >NUL && (echo DRC-KEY-FAIL & findstr /I /C:"NSTD-1" /C:"UCIO-1" /C:"AVAL-326" /C:"Opt 31-155" /C:"Opt 31-67" /C:"Route 35-7" /C:"LUTLP-1" /C:"MDRV-1" "%~dp0..\p7b_lat_build_stdout.txt")

REM ---- readings (must be present in the log, not merely in a report file) ---
findstr /B /C:"LAT_WNS" /C:"LAT_WHS" /C:"LAT_BIT" /C:"LAT_BIT_EXISTS" /C:"LAT_LTX" /C:"LAT_LTX_EXISTS" /C:"LAT_VERDICT" /C:"LAT_CONVERGED_AT_ROUND" /C:"LAT_SYNTH_STATUS" /C:"LAT_IMPL_STATUS" /C:"LAT DONE" "%~dp0..\p7b_lat_build_stdout.txt"

if not exist "..\..\..\vivado_prj\p7b_lat_prj.runs\impl_1\wrapper_p4.bit" (echo NO-BITSTREAM & exit /b 1)
echo BITSTREAM-OK
exit /b 0
