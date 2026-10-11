@echo off
REM run_tb_p6e_pcie_mut.bat -- M1 phase-A "must-go-red" gate: same p6e full-chain gate,
REM   but with a MUTATED wrapper (src_sel dp-domain select inverted, see mut_srcinv.py).
REM   expectation = the gate MUST go red (M1-10b/10c/10d flip). If it still PASS_ALL =>
REM   MUTANT-NOT-CAUGHT (hard failure). Separate work dir (trap 7).
REM   usage: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p6e_pcie\run_tb_p6e_pcie_mut.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set PY=C:\Users\zhxue\anaconda3\python.exe
%PY% "%~dp0mut_srcinv.py" --repo "%ROOT%" > mut_srcinv_out.txt 2>&1
type mut_srcinv_out.txt
findstr /C:"MUT_SRCINV_OK" mut_srcinv_out.txt >NUL || (echo MUT-SRCINV-GENFAIL & exit /b 1)
set MUTW=%ROOT%\sim\p6e_pcie\mut\wrapper_p4_mut_srcinv.v
if not exist "%MUTW%" (echo MUT-WRAPPER-MISSING & exit /b 1)
if not exist dir_mut mkdir dir_mut
cd dir_mut
if exist xsim.dir rmdir /s /q xsim.dir
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %MUTW%                                                   >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                    >> files.f
echo %ROOT%\sim\p6e_pcie\tb_p6e_pcie_wrapper.v                >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_mut.log 2>&1 || (type xvlog_mut.log & exit /b 1)
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_mut.log 2>&1 || (type xvlog_mut.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p6e_pcie_wrapper xil_defaultlib.glbl -s tb_p6e_pcie_mut -log xelab_mut.log > NUL 2>&1 || (type xelab_mut.log & exit /b 1)
call %XV%\xsim.bat tb_p6e_pcie_mut -runall -log xsim_mut.log > NUL 2>&1
findstr /C:"FAIL" /C:"PASS_ALL" /C:"TIMEOUT" xsim_mut.log
findstr /C:"TIMEOUT" xsim_mut.log >NUL && (echo P6E-MUT-TIMEOUT & exit /b 1)
findstr /C:"PASS_ALL" xsim_mut.log >NUL && (echo P6E-MUT-VERDICT: MUTANT-NOT-CAUGHT & exit /b 1)
echo P6E-MUT-VERDICT: MUTANT-CAUGHT-as-expected
findstr /C:"[FAIL]" xsim_mut.log
exit /b 0
