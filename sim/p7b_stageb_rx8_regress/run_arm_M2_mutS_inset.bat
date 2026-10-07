@echo off
REM arm M2_mutS_inset -- run the MIRROR tree chain gate (isolated work dirs)
cd /d "%~dp0mirror"
call sim\p4gates\run_matrix_p4dfix.bat -only chain > "%~dp0arm_M2_mutS_inset.log" 2>&1
echo ARM_BAT_EXITCODE=%errorlevel% >> "%~dp0arm_M2_mutS_inset.log"
exit /b %errorlevel%
