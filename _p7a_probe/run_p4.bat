@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p4_matrix.tcl -log p4_vivado.log -journal p4_vivado.jou > p4_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p4_stdout.txt
