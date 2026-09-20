@echo off
REM P5d-D6: csim logic check of the slot-rebuild fix. Own project dir; the
REM canonical HLS project (hls\slowstack_prj) is NOT touched.
REM Usage: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5dx_d6\run_csim_d6.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g\sim\p5dx_d6
C:\AMDDesignTools\2025.2\Vitis\bin\vitis-run.bat --mode hls --tcl --part xc7k325tffg676-2 --freqhz 125000000 csim_d6.tcl > csim_d6_stdout.log 2>&1
type csim_d6_stdout.log
exit /b %ERRORLEVEL%
