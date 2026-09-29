@echo off
REM T1 behavioral A/B: frame_fifo on the DEV_USP branch (RAMB36E2)
REM   (implicit nets and bit-width mismatches are hard failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog
call %XV%\xvlog.bat -work xil_defaultlib -d DEV_USP %ROOT%\rtl\frame_fifo.v %ROOT%\tb\tb_frame_fifo.v > xvlog_ffus.log 2>&1 || (type xvlog_ffus.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ffus.log 2>&1 || (type xvlog_ffus.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_ffus.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_ffus.log & exit /b 1)
findstr /C:"10-3091" xvlog_ffus.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_ffus.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_frame_fifo xil_defaultlib.glbl -s tb_frame_fifo -log xelab_ffus.log > NUL 2>&1 || (type xelab_ffus.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ffus.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ffus.log & exit /b 1)
call %XV%\xsim.bat tb_frame_fifo -runall -log xsim_ffus.log > NUL 2>&1
findstr /C:"PASS_ALL" /C:"FAIL" /C:"FATAL" xsim_ffus.log