@echo off
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %~dp0program_s2_ku5p.tcl -nojournal -nolog > %~dp0s2_program_stdout.txt 2>&1
echo S2_PROG_EXIT=%ERRORLEVEL%
