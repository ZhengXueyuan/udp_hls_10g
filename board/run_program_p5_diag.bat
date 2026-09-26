@echo off
REM run_program_p5_diag.bat - JTAG 1MHz program of the RXP_DIAG diagnostic bitstream.
REM Reprogramming == reset (mandatory before every measurement: the app RX LFSR
REM never resyncs and UMM/DS* counters are sticky -> stale phase gives fake ~99.6%).
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
REM -log/-nojournal MUST precede -tclargs (Vivado -tclargs is greedy and swallows
REM the rest -> -log silently ignored, no log file, see run_program_p5_keep.bat).
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\program_p4.tcl -log vivado_program_p5diag.log -nojournal -tclargs D:/repo/ECO/udp_hls_10g/vivado_prj/p5diag_prj.runs/impl_1/wrapper_p4.bit