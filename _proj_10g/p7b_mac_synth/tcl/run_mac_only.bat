@echo off
REM run_mac_only.bat -- P7b MAC timing probe part 1 (two out-of-context builds)
REM ASCII only, CRLF only.  Nothing is programmed here.
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_mac_synth\tcl\run_mac_only.tcl" -nojournal -nolog
echo MACONLY_VIVADO_EXITCODE=%ERRORLEVEL%
