@echo off
REM T1 semantics probe: RAMB36E2 (UltraScale+) port semantics
REM   (implicit nets and bit-width mismatches are hard failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\tb\tb_ramb36e2_sem.v > xvlog_sem.log 2>&1 || (type xvlog_sem.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_sem.log 2>&1 || (type xvlog_sem.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_sem.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_sem.log & exit /b 1)
findstr /C:"10-3091" xvlog_sem.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_sem.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_ramb36e2_sem xil_defaultlib.glbl -s tb_ramb36e2_sem -log xelab_sem.log > NUL 2>&1 || (type xelab_sem.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_sem.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_sem.log & exit /b 1)
call %XV%\xsim.bat tb_ramb36e2_sem -runall -log xsim_sem.log > NUL 2>&1
type xsim_sem.log