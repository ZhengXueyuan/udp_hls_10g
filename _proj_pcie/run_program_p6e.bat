@echo off
REM run_program_p6e.bat - JTAG program the P6e integrated bitstream (1 MHz, never touches QSPI)
REM   WARNING: do NOT run while the build is still running (board measurement precondition).
REM   After programming: REBOOT the host before checking lspci / the register window.
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source program_p6e.tcl -log program_p6e.log -nojournal
