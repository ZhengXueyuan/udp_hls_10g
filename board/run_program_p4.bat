@echo off
REM run_program_p4.bat - JTAG 1MHz program wrapper_p4.bit
REM from Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p4.bat'
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\program_p4.tcl -log vivado_program_p4.log -nojournal
