@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p6_readback.tcl -log p6_vivado.log -journal p6_vivado.jou > p6_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p6_stdout.txt
