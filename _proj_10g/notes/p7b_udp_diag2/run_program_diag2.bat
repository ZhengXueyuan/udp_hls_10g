@echo off
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_udp_diag2\program_p7b_diag2.tcl -nojournal -nolog > D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_udp_diag2\raw\program_stdout.txt 2>&1
echo DIAG2_PROG_EXIT=%ERRORLEVEL%
