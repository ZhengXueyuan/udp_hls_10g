@echo off
REM run_build_p5a0.bat - P5a-0 experiment: APP_MODE=1 => cfg_suppress_data_ack=0
REM unique difference vs P4 bitstream = pure per-segment ACK (app mode ACK contract)
REM product: D:\repo\ECO\udp_hls_10g\vivado_prj\p5a0_prj.runs\impl_1\wrapper_p4.bit
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\build_p5a0.tcl -log vivado_build_p5a0.log -nojournal
