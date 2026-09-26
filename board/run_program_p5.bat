@echo off
REM run_program_p5.bat - JTAG 1MHz program the P5 app bitstream
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
REM -log/-nojournal MUST precede -tclargs (Vivado -tclargs is greedy and swallows
REM the rest -> -log silently ignored, no log file, see run_program_p5_keep.bat).
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\program_p4.tcl -log vivado_program_p5.log -nojournal -tclargs D:/repo/ECO/udp_hls_10g/vivado_prj/p5_prj.runs/impl_1/wrapper_p4.bit
