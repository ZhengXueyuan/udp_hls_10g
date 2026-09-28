@echo off
REM run_probe_dev.bat - read-only: query the KU5P device state through hw_server
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_pcie
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source program_factory.tcl -log program_factory.log -nojournal
