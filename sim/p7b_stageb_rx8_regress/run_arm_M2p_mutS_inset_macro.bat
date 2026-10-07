@echo off
REM arm M2p_mutS_inset_macro
cd /d "%~dp0mirror"
call sim\p4gates\run_matrix_p4dfix.bat -only chain > "%~dp0arm_M2p_mutS_inset_macro.log" 2>&1
echo ARM_BAT_EXITCODE=%errorlevel% >> "%~dp0arm_M2p_mutS_inset_macro.log"
exit /b %errorlevel%
