@echo off
setlocal
cd /d "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\S3"
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -nojournal -nolog -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\t3_diag_count.tcl" -tclargs S3 "D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4_routed.dcp" > "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out\S3\diag_S3.txt" 2>&1
echo BAT_RC=%ERRORLEVEL%
