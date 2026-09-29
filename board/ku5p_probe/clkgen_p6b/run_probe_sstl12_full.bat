@echo off
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\board\ku5p_probe\clkgen_p6b
set PROBE_TAG=sstl12
set PROBE_IOSTD=DIFF_SSTL12
set PROBE_INPER=10.000
set PROBE_MULT=12.500
set PROBE_OUTDIV=8.000
set PROBE_DIVD=1
set PROBE_PIN_P=T25
set PROBE_PIN_N=U25
set PROBE_FLOW=full
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source probe.tcl -log probe_sstl12.log -nojournal
endlocal
