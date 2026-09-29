@echo off
REM verify_domains.bat -- read the clock domains back out of the routed design
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_mac_synth\tcl\verify_domains.tcl" -nojournal -nolog
echo VD_VIVADO_EXITCODE=%ERRORLEVEL%
