@echo off
REM regression agent scratch entry -- matrix, isolated work dirs (default)
cd /d "%~dp0..\.."
call sim\p4gates\run_matrix_p4dfix.bat > "%~dp0matrix_stdout.log" 2>&1
echo MATRIX_BAT_EXITCODE=%errorlevel% >> "%~dp0matrix_stdout.log"
exit /b %errorlevel%
