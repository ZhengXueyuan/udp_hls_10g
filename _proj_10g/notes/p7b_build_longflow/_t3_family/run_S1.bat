@echo off
setlocal
set OUT=D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\S1
if not exist "%OUT%" mkdir "%OUT%"
cd /d "%OUT%"
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -nojournal -nolog -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\t3_query.tcl" -tclargs S1 "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_archive\20261009_053203\wrapper_p4_routed.dcp" "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\S1" > "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\S1\t3_stdout_S1.txt" 2>&1
echo BAT_RC=%ERRORLEVEL%
