@echo off
setlocal
cd /d %~dp0
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VV%" -mode batch -source "%~dp0probe_link_check.tcl" -nojournal -nolog > "%~dp0..\link_check_stdout.txt" 2>&1
echo LNK_EXIT=%ERRORLEVEL%
findstr /B /C:"LNK" "%~dp0..\link_check_stdout.txt"
findstr /C:"ERROR" "%~dp0..\link_check_stdout.txt" | findstr /V /C:"12-4739" | head -10
exit /b 0
