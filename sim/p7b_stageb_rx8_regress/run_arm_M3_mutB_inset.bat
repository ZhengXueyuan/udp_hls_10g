@echo off
REM arm M3_mutB_inset
cd /d "%~dp0mirror"
call sim\p4gates\run_matrix_p4dfix.bat -only chain > "%~dp0arm_M3_mutB_inset.log" 2>&1
echo ARM_BAT_EXITCODE=%errorlevel% >> "%~dp0arm_M3_mutB_inset.log"
exit /b %errorlevel%
