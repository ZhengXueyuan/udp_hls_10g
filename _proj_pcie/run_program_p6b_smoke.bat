@echo off
REM run_program_p6b_smoke.bat - JTAG program the P6b smoke-test bitstream (1 MHz, never QSPI)
REM   New file added by the P6b smoke-test agent; does not modify any existing script.
REM   WARNING: do NOT run while a Vivado build is running (board measurement precondition).
REM   After programming: REBOOT the host before checking the endpoint / register window.
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source p6b_smoke_program.tcl -log smoke_scratch\program_p6b_smoke.log -nojournal
