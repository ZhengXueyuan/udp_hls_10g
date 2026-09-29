@echo off
REM run_probe.bat -- P6b pin/MMCM legality probes (all read-only, no board)
REM   variant list: tag | iostd | inper | mult | outdiv | divd | pinP | pinN | flow
setlocal
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g\board\ku5p_probe\clkgen_p6b

call :one pod12dci  DIFF_POD12_DCI 10.000 12.500 8.000 1 T25   U25   full
call :one sstl12    DIFF_SSTL12    10.000 12.500 8.000 1 T25   U25   full
call :one pod12     DIFF_POD12     10.000 12.500 8.000 1 T25   U25   place
call :one lvds      LVDS           10.000 12.500 8.000 1 T25   U25   place
call :one lvcmos33  LVCMOS33       10.000 12.500 8.000 1 T25   U25   place
call :one notgc     DIFF_POD12_DCI 10.000 12.500 8.000 1 NOTGC NOTGC place
call :one vcolow    DIFF_POD12_DCI 10.000 1.000  8.000 1 T25   U25   place
call :one vcohigh   DIFF_POD12_DCI 10.000 64.000 2.000 1 T25   U25   place
echo ==== ALL PROBES DONE ====
endlocal
exit /b 0

:one
set PROBE_TAG=%~1
set PROBE_IOSTD=%~2
set PROBE_INPER=%~3
set PROBE_MULT=%~4
set PROBE_OUTDIV=%~5
set PROBE_DIVD=%~6
set PROBE_PIN_P=%~7
set PROBE_PIN_N=%~8
set PROBE_FLOW=%~9
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source probe.tcl -log probe_%~1.log -nojournal
exit /b 0
