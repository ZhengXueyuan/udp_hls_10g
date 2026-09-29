@echo off
REM run_xxv_mac.bat -- P7b MAC timing probe part 2 (PCS baseline + PCS+MAC)
REM ASCII only, CRLF only.  Nothing is programmed here.
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_mac_synth\tcl\run_xxv_mac.tcl" -nojournal -nolog
echo XXVMAC_VIVADO_EXITCODE=%ERRORLEVEL%
