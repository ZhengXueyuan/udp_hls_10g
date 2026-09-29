@echo off
REM analyze_ooc.bat -- classify the hold failures of the two MAC-only OOC runs
REM ASCII only, CRLF only.  Nothing is programmed here.
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_mac_synth\tcl\analyze_ooc.tcl" -nojournal -nolog
echo ANALYZE_VIVADO_EXITCODE=%ERRORLEVEL%
