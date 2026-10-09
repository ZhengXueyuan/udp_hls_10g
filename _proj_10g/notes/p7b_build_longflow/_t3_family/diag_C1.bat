@echo off
setlocal
cd /d "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\C1"
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -nojournal -nolog -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\t3_diag_count.tcl" -tclargs C1 "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_archive\20261009_045518\wrapper_p4_routed.dcp" > "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\C1\diag_C1.txt" 2>&1
echo BAT_RC=%ERRORLEVEL%
