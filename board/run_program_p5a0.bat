@echo off
REM run_program_p5a0.bat - JTAG 1MHz program the P5a-0 experiment bitstream
REM (APP_MODE=1 => per-segment pure ACK); p4_prj bitstream is untouched
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\program_p4.tcl -tclargs D:/repo/ECO/udp_hls_10g/vivado_prj/p5a0_prj.runs/impl_1/wrapper_p4.bit -log vivado_program_p5a0.log -nojournal
