@echo off
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_mac_synth\tcl\vd2.tcl" -nojournal -nolog
echo VD2_EXITCODE=%ERRORLEVEL%
