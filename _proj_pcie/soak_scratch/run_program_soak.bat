@echo off
REM run_program_soak.bat - JTAG program the P6b FINAL bitstream (1 MHz TCK, never QSPI).
REM   New file added by the P6b long-soak probe agent; does not modify any existing script.
REM   WARNING: do NOT run while a Vivado build is running (board measurement precondition).
REM   After programming, the host MUST be rebooted before checking the endpoint.
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\soak_scratch
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source program_soak.tcl -log program_soak.log -nojournal
