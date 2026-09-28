@echo off
REM run_p6a_verify.bat - read-only P6a (KU5P) verification of the routed checkpoint
REM input : vivado_prj/p6a_ku5p_<tag>_prj.runs/impl_1/wrapper_p4_routed.dcp (t8p0/t6p4)
REM output: p6a_ku5p_verify/p6a_<tag>_*.rpt + p6a_<tag>_failing_endpoints.txt
REM from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\p6a_ku5p_verify\run_p6a_verify.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\XCKU5PMini\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\XCKU5PMini\udp_hls_10g\p6a_ku5p_verify\p6a_verify.tcl -log vivado_p6a_verify.log -nojournal
