@echo off
cd /d %~dp0
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %~dp0program_rate_ku5p.tcl -nojournal -nolog > %~dp0rate_program_stdout.txt 2>&1
echo RATE_PROG_EXIT=%ERRORLEVEL%
