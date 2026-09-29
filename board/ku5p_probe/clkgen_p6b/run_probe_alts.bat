@echo off
REM run_probe_alts.bat -- verify the ALTERNATE MMCM parameter sets actually place
REM   alt1     : 100 MHz, M=25.000 D=2 O=8.000 -> VCO 1250.0 MHz, PFD  50 MHz
REM   alt2     : 100 MHz, M=9.375  D=1 O=6.000 -> VCO  937.5 MHz, PFD 100 MHz
REM   alt125   : 125 MHz, M=10.000 D=1 O=8.000 -> VCO 1250.0 MHz, PFD 125 MHz  (i_rxc fallback)
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\board\ku5p_probe\clkgen_p6b

set PROBE_IOSTD=DIFF_SSTL12
set PROBE_PIN_P=T25
set PROBE_PIN_N=U25
set PROBE_FLOW=place

set PROBE_TAG=alt1_m25d2o8
set PROBE_INPER=10.000
set PROBE_MULT=25.000
set PROBE_OUTDIV=8.000
set PROBE_DIVD=2
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source probe.tcl -log probe_alt1.log -nojournal

set PROBE_TAG=alt2_m9375d1o6
set PROBE_INPER=10.000
set PROBE_MULT=9.375
set PROBE_OUTDIV=6.000
set PROBE_DIVD=1
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source probe.tcl -log probe_alt2.log -nojournal

set PROBE_TAG=alt125_m10d1o8
set PROBE_INPER=8.000
set PROBE_MULT=10.000
set PROBE_OUTDIV=8.000
set PROBE_DIVD=1
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source probe.tcl -log probe_alt125.log -nojournal

echo ==== ALT PROBES DONE ====
endlocal
