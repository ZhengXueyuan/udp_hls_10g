@echo off
REM run_program_pcie_min.bat - JTAG program the P6e minimal bitstream (1 MHz, never touches QSPI)
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source program_pcie_min.tcl -log program_pcie_min.log -nojournal
