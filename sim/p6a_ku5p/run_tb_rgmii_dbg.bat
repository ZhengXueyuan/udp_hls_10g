@echo off
REM T2 frontend per-edge trace (debug aid, not a gate)
REM   (implicit nets and bit-width mismatches are hard failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\board\util_gmii_to_rgmii_us.v %ROOT%\tb\tb_rgmii_dbg.v > xvlog_dbg.log 2>&1 || (type xvlog_dbg.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_dbg.log 2>&1 || (type xvlog_dbg.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_dbg.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_dbg.log & exit /b 1)
findstr /C:"10-3091" xvlog_dbg.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_dbg.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rgmii_dbg xil_defaultlib.glbl -s tb_rgmii_dbg -log xelab_dbg.log > NUL 2>&1 || (type xelab_dbg.log & exit /b 1)
call %XV%\xsim.bat tb_rgmii_dbg -runall -log xsim_dbg.log > NUL 2>&1
type xsim_dbg.log