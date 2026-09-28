@echo off
REM run_build_p6e_ku5p.bat -- P6e build: data plane + PCIe/XDMA observation channel (KU5P, t8p0)
REM   product: vivado_prj\p6e_ku5p_prj.runs\impl_1\wrapper_p4.bit
REM   success criteria = bitstream file exists (Vivado batch may exit 0 even on errors)
REM   before running this, run run_lint_p6e.bat (seconds vs ~30 min)
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p6e_ku5p.bat'
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g
echo ==== P6e KU5P build (data plane + PCIe obs) ====
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\board\build_p6e_ku5p.tcl -log vivado_build_p6e.log -nojournal
if exist D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p6e_ku5p_prj.runs\impl_1\wrapper_p4.bit (
    echo BITSTREAM-OK
) else (
    echo BITSTREAM-MISSING -- build failed, see vivado_build_p6e.log
)
