@echo off
REM run_build_pcie_min.bat - P6e minimal: our own XDMA observation channel (no datapath)
REM success criterion = the bitstream exists (Vivado batch does NOT reliably return nonzero)
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
set PY=C:\Users\zhxue\anaconda3\python.exe
set BIT=vivado_prj\pcie_min_prj.runs\impl_1\pcie_min_top.bit
cd /d D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie
if exist %BIT% del /q %BIT%
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source build_pcie_min.tcl -log build_pcie_min.log -nojournal
if not exist %BIT% (echo BUILD-FAIL: bitstream not generated & exit /b 1)
echo BUILD-OK: %BIT%
%PY% check_xci.py
exit /b %ERRORLEVEL%
