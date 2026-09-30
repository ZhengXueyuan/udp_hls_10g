@echo off
setlocal
rem run_ooc.bat -- parameterised MAC OOC probe (fix agent). ASCII + CRLF only.
rem usage: run_ooc.bat <rtl_dir> <tag> <strategy^|DEFAULT> <tx^|rx^|both^>
set B=D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_mac_timing_fix
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -nojournal -nolog -source "%B%\tcl\run_ooc.tcl" -tclargs %1 %2 %3 %4 > "%B%\logs\%2_stdout.txt" 2>&1
echo %2_VIVADO_EXITCODE=%ERRORLEVEL%
