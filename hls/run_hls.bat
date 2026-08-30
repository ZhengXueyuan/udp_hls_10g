@echo off
REM udp_hls_10g\hls\run_hls.bat — 慢路径协议栈 HLS 综合 (csynth)
REM 产物: hls\slowstack_prj\solution1\syn\verilog\udp_echo.v (+ 全部子模块)
REM 从 Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\hls\run_hls.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g\hls
C:\AMDDesignTools\2025.2\Vitis\bin\vitis-run.bat --mode hls --tcl --part xc7k325tffg676-2 --freqhz 125000000 run_hls.tcl
