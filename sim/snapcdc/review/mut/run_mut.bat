@echo off
REM run_mut.bat <mutant.v> - run the ORIGINAL tb/tb_snap_cdc.v against a mutated DUT (review scratch)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %1 %ROOT%\tb\tb_snap_cdc.v > xvlog_m.log 2>&1 || (type xvlog_m.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_m.log 2>&1 || (type xvlog_m.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_snap_cdc xil_defaultlib.glbl -s tb_snap_cdc -log xelab_m.log > NUL 2>&1 || (type xelab_m.log & exit /b 1)
call %XV%\xsim.bat tb_snap_cdc -runall -log xsim_m.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"NEG-OK" /C:"INFO" /C:"TIMEOUT" xsim_m.log
