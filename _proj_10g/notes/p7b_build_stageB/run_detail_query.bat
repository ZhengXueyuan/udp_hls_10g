@echo off
setlocal
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VV%" -mode batch -source "%~dp0detail_query.tcl" -nojournal -nolog > "%~dp0detail_query_out.txt" 2>&1
echo DETAIL_EXIT=%ERRORLEVEL%
