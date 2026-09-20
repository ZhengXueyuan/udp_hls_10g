@echo off
REM run_route_check.bat -- P5e-T3 private gate: synth + opt + place + ROUTE timing,
REM plus a cell-count probe proving the UDP app cone is NO LONGER trimmed
REM (T1/T2 both had "no consumer => cone trimmed => input-side paths not covered").
REM File list mirrors board/build_p5.tcl (incl. app_udp_pattern.v).
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\sim\p5e_udp\route_check.tcl -log vivado_route_check_t3.log -nojournal
