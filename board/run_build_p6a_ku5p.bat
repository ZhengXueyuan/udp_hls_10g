@echo off
REM run_build_p6a_ku5p.bat [t8p0|t6p4] -- P6a KU5P build (default t8p0 = 8.000ns real 1G)
REM   product: vivado_prj\p6a_ku5p_<tag>_prj.runs\impl_1\wrapper_p4.bit
REM   readings afterwards: p6a_ku5p_verify\run_p6a_verify.bat
REM from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p6a_ku5p.bat' t6p4
setlocal
set TAG=%~1
if "%TAG%"=="" set TAG=t8p0
set P6A_TAG=%TAG%
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g
echo ==== P6a KU5P build, tag=%TAG% ====
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\board\build_p6a_ku5p.tcl -log vivado_build_p6a_%TAG%.log -nojournal
