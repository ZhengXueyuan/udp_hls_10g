@echo off
REM usage: set TCPREG_BIT=<path> then run_program_tcpreg.bat
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %~dp0program_tcpreg_ku5p.tcl -nojournal -nolog > %~dp0tcpreg_program_stdout.txt 2>&1
echo TCPREG_PROG_EXIT=%ERRORLEVEL%
