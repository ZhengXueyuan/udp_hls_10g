@echo off
REM arm M0p_pristine_inset_macro
cd /d "%~dp0mirror"
call sim\p4gates\run_matrix_p4dfix.bat -only chain > "%~dp0arm_M0p_pristine_inset_macro.log" 2>&1
echo ARM_BAT_EXITCODE=%errorlevel% >> "%~dp0arm_M0p_pristine_inset_macro.log"
exit /b %errorlevel%
