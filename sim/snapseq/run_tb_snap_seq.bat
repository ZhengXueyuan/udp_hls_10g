@echo off
REM run_tb_snap_seq.bat - unit gate for snap_seq (P6b chained snapshot sequencer)
REM   hard failures: implicit nets and bit-width mismatches (project rule, trap 24)
REM   own sim dir (trap 7: parallel gates must not share xsim.dir)
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\snapseq\run_tb_snap_seq.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\snap_seq.v %ROOT%\rtl\snap_cdc.v %ROOT%\tb\tb_snap_seq.v > xvlog_sns.log 2>&1 || (type xvlog_sns.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_sns.log 2>&1 || (type xvlog_sns.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_sns.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_sns.log & exit /b 1)
findstr /C:"10-3091" xvlog_sns.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_sns.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_snap_seq xil_defaultlib.glbl -s tb_snap_seq -log xelab_sns.log > NUL 2>&1 || (type xelab_sns.log & exit /b 1)
call %XV%\xsim.bat tb_snap_seq -runall -log xsim_sns.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"INFO" /C:"TIMEOUT" xsim_sns.log
findstr /C:"PASS_ALL" xsim_sns.log >NUL || exit /b 1
