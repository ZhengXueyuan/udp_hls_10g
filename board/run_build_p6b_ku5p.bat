@echo off
REM run_build_p6b_ku5p.bat -- P6b build: data plane 125MHz -> 156.25MHz (KU5P, dual clock domain)
REM   product: vivado_prj\p6b_ku5p_prj.runs\impl_1\wrapper_p4.bit
REM   success criteria = bitstream file exists (Vivado batch may exit 0 even on errors)
REM   AFTER the build: python board\check_p6b_timing.py board\p6b_ku5p_timing.rpt --expect dual
REM                    must exit 0 (dual-domain report + 0 failing endpoints + the 16 HDIO
REM                    Min-Period violations of gate G must be GONE), and the log must NOT
REM                    contain "Vivado 12-4739" (set_clock_groups silently dropped).
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p6b_ku5p.bat'
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g
echo ==== P6b KU5P build (dual clock domain: FE 125MHz + DP 156.25MHz) ====
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\board\build_p6b_ku5p.tcl -log vivado_build_p6b.log -nojournal
if exist D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p6b_ku5p_prj.runs\impl_1\wrapper_p4.bit (
    echo BITSTREAM-OK
) else (
    echo BITSTREAM-MISSING -- build failed, see vivado_build_p6b.log
)
findstr /C:"12-4739" D:\repo\XCKU5PMini\udp_hls_10g\vivado_build_p6b.log >NUL && (echo CLOCK-GROUPS-DROPPED-12-4739)
