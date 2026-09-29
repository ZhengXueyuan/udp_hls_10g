@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p7_readback2.tcl -log p7_vivado.log -journal p7_vivado.jou > p7_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p7_stdout.txt
