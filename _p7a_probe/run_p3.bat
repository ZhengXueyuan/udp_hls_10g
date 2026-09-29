@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p3_wizard.tcl -log p3_vivado.log -journal p3_vivado.jou > p3_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p3_stdout.txt
