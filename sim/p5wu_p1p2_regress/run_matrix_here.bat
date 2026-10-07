@echo off
cd /d "%~dp0..\.."
set "LOG=%~dp0matrix_stdout.log"
call sim\p4gates\run_matrix_p4dfix.bat > "%LOG%" 2>&1
set RC=%ERRORLEVEL%
echo MATRIX_BAT_EXITCODE=%RC% >> "%LOG%"
exit /b %RC%
