@echo off
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\board\p6b_extra_reports.tcl -log vivado_p6b_extra.log -nojournal
