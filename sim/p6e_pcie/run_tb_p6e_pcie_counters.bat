@echo off
REM run_tb_p6e_pcie_counters.bat - P6e W16/W17 increment-logic gate (review F2 fix)
REM   The full-chain gate forces every snapshot word to a constant, so "what the two NEW
REM   counters actually count, and under which condition" had no gate at all. This one
REM   drives the REAL wrapper handshake / watchdog wire and asserts the delta is EXACTLY
REM   the number of driven cycles (N_RX / N_HR are localparams in the TB), plus negative
REM   controls (tvalid-only and tready-only must NOT count -> catches an OR-style bug).
REM   Compile defines MUST match the real build: PCIE_OBS + DEV_USP + APP_MODE
REM   NOTE: cmd does not glob *.v -- the file list is generated into files.f
REM   NOTE: log names are *_cnt.* on purpose: this gate shares the work dir with
REM         run_tb_p6e_pcie.bat, whose logs are the F1 evidence and must not be clobbered.
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p6e_pcie\run_tb_p6e_pcie_counters.bat'
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
echo %~dp0tb_p6e_pcie_counters.v                              >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_p6e_cnt.log 2>&1 || (type xvlog_p6e_cnt.log & exit /b 1)
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_p6e_cnt.log 2>&1 || (type xvlog_p6e_cnt.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e_cnt.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e_cnt.log & exit /b 1)
findstr /C:"10-3091" xvlog_p6e_cnt.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"10-3091" xvlog_p6e_cnt.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_p6e_cnt.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_p6e_cnt.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p6e_pcie_counters xil_defaultlib.glbl -s tb_p6e_pcie_counters -log xelab_p6e_cnt.log > NUL 2>&1 || (type xelab_p6e_cnt.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p6e_cnt.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p6e_cnt.log & exit /b 1)
call %XV%\xsim.bat tb_p6e_pcie_counters -runall -log xsim_p6e_cnt.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"INFO" /C:"TIMEOUT" xsim_p6e_cnt.log
findstr /C:"PASS_ALL" xsim_p6e_cnt.log >NUL || exit /b 1
