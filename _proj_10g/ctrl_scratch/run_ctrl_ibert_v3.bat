@echo off
setlocal
set VIV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VIV%" -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\ctrl_ibert_v3.tcl -log D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\logs\ctrl_ibert_v3.log -journal D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\logs\ctrl_ibert_v3.jou
echo BAT_EXIT=%ERRORLEVEL%
