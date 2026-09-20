@echo off
REM run_tb_udp_split.bat -- P5e-T1 udp_split unit gate (tb_udp_split.v)
REM Self-checking: last line "P5 UDP SPLIT UNIT OK" / "... FAIL n".
REM Own xsim.dir here (project rule 7: never share xsim.dir across gates).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\frame_fifo.v ^
  %RTL%\udp_rx.v ^
  %RTL%\udp_split.v ^
  %TB%\tb_udp_split.v > xvlog_split.log 2>&1 || (type xvlog_split.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_split.log 2>&1 || (type xvlog_split.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_udp_split xil_defaultlib.glbl -s tb_udp_split -log xelab_split.log > NUL 2>&1 || (type xelab_split.log & exit /b 1)
call %XV%\xsim.bat tb_udp_split -runall -log xsim_split.log > NUL 2>&1 || (type xsim_split.log & exit /b 1)

findstr /C:"P5 UDP SPLIT UNIT OK" xsim_split.log > NUL
if errorlevel 1 (findstr /C:"P5US " xsim_split.log & findstr /C:"FAIL" xsim_split.log & exit /b 1)
findstr /C:"P5US " xsim_split.log
echo P5 UDP SPLIT UNIT GATE PASS
