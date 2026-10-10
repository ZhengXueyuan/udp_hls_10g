@echo off
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
set D=%~dp0
call "%VV%" -mode batch -nojournal -nolog -source "%D%query_fam2.tcl" -tclargs "D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4_routed.dcp" F "%D%query_F" > "%D%query_fam2_stdout.txt" 2>&1
echo QUERY_FAM2_EXIT=%ERRORLEVEL%
