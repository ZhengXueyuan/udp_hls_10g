@echo off
REM run_tb_snap_cdc.bat - unit gate for snap_cdc (coherent snapshot CDC, gmii_clk -> axi_aclk)
REM   hard failures: implicit nets and bit-width mismatches (project rule, trap 24)
REM   runs in its own sim dir (trap 7: parallel gates must not share xsim.dir)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\snap_cdc.v %ROOT%\tb\tb_snap_cdc.v > xvlog_snap.log 2>&1 || (type xvlog_snap.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_snap.log 2>&1 || (type xvlog_snap.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_snap.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_snap.log & exit /b 1)
findstr /C:"10-3091" xvlog_snap.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_snap.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_snap_cdc xil_defaultlib.glbl -s tb_snap_cdc -log xelab_snap.log > NUL 2>&1 || (type xelab_snap.log & exit /b 1)
call %XV%\xsim.bat tb_snap_cdc -runall -log xsim_snap.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"WARN" /C:"INFO" /C:"TIMEOUT" xsim_snap.log
REM exit code: PASS_ALL => 0, anything else => 1 (same convention as the other gates here)
findstr /C:"PASS_ALL" xsim_snap.log >NUL || exit /b 1
