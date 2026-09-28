@echo off
REM run_mut2_no_latch.bat - mutation check: the "no latch" mutant (dout_a <= din_b) must be CAUGHT
REM   Same TB (tb/tb_snap_cdc.v) compiled against the mutant DUT (mut2/snap_cdc.v, module name kept
REM   as snap_cdc so the TB needs no change).
REM   EXPECTED RESULT: criterion 8a FAILs (naive/direct sampling mixes generations) => exit /b 0 here.
REM   If this script prints MUTANT-NOT-CAUGHT and exits 1, the gate is vacuous for the one thing
REM   snap_cdc exists to do -- do not "fix" the mutant, fix the gate.
REM   ASCII only (project rule for .bat).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib snap_cdc.v %ROOT%\tb\tb_snap_cdc.v > xvlog_mut2.log 2>&1 || (type xvlog_mut2.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_mut2.log 2>&1 || (type xvlog_mut2.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_snap_cdc xil_defaultlib.glbl -s tb_snap_cdc -log xelab_mut2.log > NUL 2>&1 || (type xelab_mut2.log & exit /b 1)
call %XV%\xsim.bat tb_snap_cdc -runall -log xsim_mut2.log > NUL 2>&1
findstr /C:"FAIL" /C:"PASS_ALL" xsim_mut2.log
findstr /C:"PASS_ALL" xsim_mut2.log >NUL && (echo MUTANT-NOT-CAUGHT & exit /b 1)
echo MUTANT-CAUGHT-OK
exit /b 0
