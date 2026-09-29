@echo off
setlocal
set VIV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
call "%VIV%" -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\extra_gate_diag.tcl -log D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\logs\extra_gate_diag.log -journal D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\ctrl_scratch\logs\extra_gate_diag.jou
echo BAT_EXIT=%ERRORLEVEL%
