@echo off
REM =============================================================================
REM run_build.bat — Vivado 2025.2 批处理构建 (synth + impl + bitstream)
REM 产物: D:\repo\ECO\udp_hls_10g\vivado_prj\udp_loop_phy1.runs\impl_1\wrapper_1g.bit
REM 从 Git Bash 调用: cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build.bat'
REM 参照: udp_hls_eco\run_vivado_phy1g2.bat (全路径调用, cd /d 开头)
REM =============================================================================
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\build.tcl -log vivado_build.log -nojournal
