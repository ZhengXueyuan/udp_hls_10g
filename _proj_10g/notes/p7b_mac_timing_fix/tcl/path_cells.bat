@echo off
set B=D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_mac_timing_fix
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -nojournal -nolog -source "%B%\tcl\path_cells.tcl" > "%B%\logs\path_cells_stdout.txt" 2>&1
echo EXIT=%ERRORLEVEL%
