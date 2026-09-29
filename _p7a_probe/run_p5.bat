@echo off
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_p7a_probe
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p5_final.tcl -log p5_vivado.log -journal p5_vivado.jou > p5_stdout.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> p5_stdout.txt
