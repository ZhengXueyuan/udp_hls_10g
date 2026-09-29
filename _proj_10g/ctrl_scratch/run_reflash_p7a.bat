@echo off
setlocal
set VIV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VIV%" -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\reflash_p7a.tcl -log D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\logs\reflash_p7a.log -journal D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\logs\reflash_p7a.jou
echo BAT_EXIT=%ERRORLEVEL%
