@echo off
REM run_tb_p6e_pcie.bat - P6e integrated design: REAL-wrapper full-chain gate (project trap 8)
REM   compile defines MUST match the real build: PCIE_OBS + DEV_USP + APP_MODE + DP_156MHZ
REM   P6B_SIM_CLKGEN: P6b only -- makes clk_gen_p6b use its behavioural clock model in sim
REM   (the real build never defines it, so IBUFDS/MMCME4_BASE is what gets synthesised)
REM   NOTE: cmd does not glob *.v -- the file list is generated into files.f
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p6e_pcie\run_tb_p6e_pcie.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                                >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
echo %~dp0xdma_0_sim_stub.v                                   >> files.f
echo %~dp0tb_p6e_pcie_wrapper.v                               >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_p6e.log 2>&1 || (type xvlog_p6e.log & exit /b 1)
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_p6e.log 2>&1 || (type xvlog_p6e.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e.log & exit /b 1)
findstr /C:"10-3091" xvlog_p6e.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"10-3091" xvlog_p6e.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_p6e.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_p6e.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p6e_pcie_wrapper xil_defaultlib.glbl -s tb_p6e_pcie -log xelab_p6e.log > NUL 2>&1 || (type xelab_p6e.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p6e.log & exit /b 1)
call %XV%\xsim.bat tb_p6e_pcie -runall -log xsim_p6e.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"INFO" /C:"TIMEOUT" xsim_p6e.log
findstr /C:"PASS_ALL" xsim_p6e.log >NUL || exit /b 1
