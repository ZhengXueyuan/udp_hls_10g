@echo off
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
set D=%~dp0
call "%VV%" -mode batch -nojournal -nolog -source "%D%query_cones.tcl" -tclargs "D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4_routed.dcp" F "%D%query_F" > "%D%query_F_stdout.txt" 2>&1
echo QUERY_F_EXIT=%ERRORLEVEL%
call "%VV%" -mode batch -nojournal -nolog -source "%D%query_cones.tcl" -tclargs "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_archive\20261010_091536\wrapper_p4_routed.dcp" E "%D%query_E" > "%D%query_E_stdout.txt" 2>&1
echo QUERY_E_EXIT=%ERRORLEVEL%
