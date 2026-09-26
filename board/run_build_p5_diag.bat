@echo off
REM run_build_p5_diag.bat - Vivado 2025.2 build of the RXP_DIAG diagnostic bitstream.
REM (ISSUE_RX_BYTE_CORRUPTION) APP_MODE + RXP_DIAG + eco_holdfix.xdc; project p5diag_prj
REM so the P5 bitstream/reports are NOT overwritten.
REM product: vivado_prj\p5diag_prj.runs\impl_1\wrapper_p4.bit
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\build_p5_diag.tcl -log vivado_build_p5diag.log -nojournal