@echo off
REM P7b WU measurement round: program the FIXED bitstream sha256 1076e50e...1160 via JTAG (never QSPI)
set TCPREG_BIT=D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4.bit
call "D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat"
