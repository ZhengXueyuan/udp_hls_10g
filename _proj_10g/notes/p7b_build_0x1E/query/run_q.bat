@echo off
REM run_q.bat - 0x1E targeted timing query runner (ASCII + CRLF only)
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
set D=D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_0x1E\query
call "%VV%" -mode batch -nojournal -nolog -source "%D%\q_0x1E.tcl" -tclargs "%D%\..\wrapper_p4_routed.dcp" "%D%\out" > "%D%\q_stdout.txt" 2>&1
echo QUERY_EXIT=%ERRORLEVEL%
