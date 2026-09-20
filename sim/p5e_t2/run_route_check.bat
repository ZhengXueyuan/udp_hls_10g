@echo off
REM run_route_check.bat -- P5e-T2 private gate: synth + opt + place + ROUTE timing.
REM Place-only hold numbers are pessimistic (T1 baseline: place-only WHS -0.159/718
REM endpoints vs routed +0.035) => this run resolves the routed WNS/WHS for the T2
REM design. File list mirrors board/build_p5.tcl (incl. udp_tx_cfg.v / udp_tx_frame.v).
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\sim\p5e_t2\route_check.tcl -log vivado_route_check_t2.log -nojournal
