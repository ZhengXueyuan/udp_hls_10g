@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p1_wizard.tcl -log p1_vivado.log -journal p1_vivado.jou > p1_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p1_stdout.txt
