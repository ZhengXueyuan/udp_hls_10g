@echo off
REM run_p6e_verify.bat -- read-only verification of the routed P6e design (timing / CDC / util)
REM   Run AFTER the build has reached route_design. Does not modify the project.
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\board\p6e_verify.tcl -log vivado_p6e_verify.log -nojournal
