@echo off
REM run_tb_p6e_pcie_mut2.bat -- M1 phase-B "must-go-red" gate: same p6e full-chain gate,
REM   but with the C2H ring's WRITE DATA pinned to 0 (see mut_bwire.py).
REM   expectation = the gate MUST go red (M1-B-2e / M1-B-3d content checks flip while the
REM   counter checks M1-B-1 / M1-B-3a stay green). If it still PASS_ALL =>
REM   MUTANT-NOT-CAUGHT (hard failure). Separate work dir from mut1 (trap 7).
REM   usage: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p6e_pcie\run_tb_p6e_pcie_mut2.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set PY=C:\Users\zhxue\anaconda3\python.exe
%PY% "%~dp0mut_bwire.py" --repo "%ROOT%" > mut_bwire_out.txt 2>&1
type mut_bwire_out.txt
findstr /C:"MUT_BWIRE_OK" mut_bwire_out.txt >NUL || (echo MUT-BWIRE-GENFAIL & exit /b 1)
set MUTW=%ROOT%\sim\p6e_pcie\mut\wrapper_p4_mut_bwire.v
if not exist "%MUTW%" (echo MUT-WRAPPER-MISSING & exit /b 1)
if not exist dir_mut2 mkdir dir_mut2
cd dir_mut2
if exist xsim.dir rmdir /s /q xsim.dir
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %MUTW%                                                   >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                    >> files.f
echo %ROOT%\sim\p6e_pcie\tb_p6e_pcie_wrapper.v                >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_mut2.log 2>&1 || (type xvlog_mut2.log & exit /b 1)
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_mut2.log 2>&1 || (type xvlog_mut2.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p6e_pcie_wrapper xil_defaultlib.glbl -s tb_p6e_pcie_mut2 -log xelab_mut2.log > NUL 2>&1 || (type xelab_mut2.log & exit /b 1)
call %XV%\xsim.bat tb_p6e_pcie_mut2 -runall -log xsim_mut2.log > NUL 2>&1
findstr /C:"FAIL" /C:"PASS_ALL" /C:"TIMEOUT" xsim_mut2.log
findstr /C:"TIMEOUT" xsim_mut2.log >NUL && (echo P6E-MUT2-TIMEOUT & exit /b 1)
findstr /C:"PASS_ALL" xsim_mut2.log >NUL && (echo P6E-MUT2-VERDICT: MUTANT-NOT-CAUGHT & exit /b 1)
echo P6E-MUT2-VERDICT: MUTANT-CAUGHT-as-expected
findstr /C:"[FAIL]" xsim_mut2.log
exit /b 0
