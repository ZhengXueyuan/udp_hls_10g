@echo off
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
set D=C:\Users\zhxue\AppData\Local\Temp\p7b_0x1C_query
call "%VV%" -mode batch -nojournal -nolog -source "%D%\q_0x1C.tcl" -tclargs "D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4_routed.dcp" "%D%\out" > "%D%\q_stdout.txt" 2>&1
echo QUERY_EXIT=%ERRORLEVEL%
