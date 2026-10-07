@echo off
setlocal
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VV%" -mode batch -source "%~dp0newcone_query.tcl" -nojournal -nolog > "%~dp0newcone_query_out.txt" 2>&1
echo QUERY_EXIT=%ERRORLEVEL%
