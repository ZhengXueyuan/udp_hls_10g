@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p2_wizard.tcl -log p2_vivado.log -journal p2_vivado.jou > p2_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p2_stdout.txt
