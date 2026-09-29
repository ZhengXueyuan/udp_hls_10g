@echo off
REM run_program_p6b_final.bat - JTAG program the P6b FINAL frozen bitstream (1 MHz, never QSPI)
REM   New file added by the P6b final-acceptance agent; does not modify any existing script.
REM   WARNING: do NOT run while a Vivado build is running (board measurement precondition).
REM   After programming: REBOOT the host before checking the endpoint / register window.
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\p6b_accept_final
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source program_p6b_final.tcl -log program_p6b_final.log -nojournal
