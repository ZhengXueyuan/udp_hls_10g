@echo off
REM run_tb_axi_regs.bat - unit gate for the P6e register block (axi_regs)
REM   hard failures: implicit nets and bit-width mismatches
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\axi_regs.v %ROOT%\tb\tb_axi_regs.v > xvlog_axr.log 2>&1 || (type xvlog_axr.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_axr.log 2>&1 || (type xvlog_axr.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_axr.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_axr.log & exit /b 1)
findstr /C:"10-3091" xvlog_axr.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_axr.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_axi_regs xil_defaultlib.glbl -s tb_axi_regs -log xelab_axr.log > NUL 2>&1 || (type xelab_axr.log & exit /b 1)
call %XV%\xsim.bat tb_axi_regs -runall -log xsim_axr.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"TIMEOUT" xsim_axr.log
