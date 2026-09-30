@echo off
setlocal
cd /d %~dp0
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source "%~dp0t_exec.tcl" -nojournal -nolog > "%~dp0t_exec.log" 2>&1
echo TEXEC_EXIT=%ERRORLEVEL%
findstr /B /C:"PATH_SSH" /C:"TESTTCL" "%~dp0t_exec.log"
exit /b 0
