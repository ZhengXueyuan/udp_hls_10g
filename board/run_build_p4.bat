@echo off
REM run_build_p4.bat - Vivado 2025.2 build P4a (TCP fast + HLS slow path)
REM product: D:\repo\ECO\udp_hls_10g\vivado_prj\p4_prj.runs\impl_1\wrapper_p4.bit
REM from Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p4.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\build_p4.tcl -log vivado_build_p4.log -nojournal
