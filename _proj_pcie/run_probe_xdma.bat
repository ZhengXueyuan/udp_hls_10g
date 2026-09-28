@echo off
REM run_probe_xdma.bat - generate an XDMA IP in 2025.2 and dump its params/ports
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source probe_xdma.tcl -log probe_xdma.log -nojournal
