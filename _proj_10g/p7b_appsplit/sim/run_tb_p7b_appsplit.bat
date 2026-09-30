@echo off
REM run_tb_p7b_appsplit.bat - P7b app-UDP split-path root-cause probe.
REM   Same compile defines as the real P7b bitstream build plus the two
REM   simulation-only ones (P6B_SIM_CLKGEN / P7B_SIM_NOPCS).
REM   from Git Bash: cmd //c '_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
REM   P7B_MUT: optional override for the MAC rtl dir (mutation / pre-fix A-B testing),
REM            same convention as _proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat.
set "MACD=%ROOT%\_proj_10g\p7b_mac\rtl"
if not "%P7B_MUT%"=="" set "MACD=%P7B_MUT%"
if not exist "%MACD%\mac_rx_10g.v" (echo [PATHGUARD FAIL] no mac_rx_10g.v in %MACD% & exit /b 1)
echo [P7B APPSPLIT GATE] MAC RTL = %MACD%
if exist xsim.dir rmdir /s /q xsim.dir
if exist xsim_appsplit.log del /q xsim_appsplit.log
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                                 >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\board\p7b_pcs_stub.v                              >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
echo %MACD%\crc32_64.v                                        >> files.f
echo %MACD%\mac_rx_10g.v                                      >> files.f
echo %MACD%\mac_tx_10g.v                                      >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                    >> files.f
echo %~dp0tb_p7b_appsplit.v                                   >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_appsplit.log 2>&1 || (type xvlog_appsplit.log & exit /b 1)
call %XV%\xvlog.bat -d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_appsplit.log 2>&1 || (type xvlog_appsplit.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_appsplit.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_appsplit.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p7b_appsplit xil_defaultlib.glbl -s tb_p7b_appsplit -log xelab_appsplit.log > NUL 2>&1 || (type xelab_appsplit.log & exit /b 1)
call %XV%\xsim.bat tb_p7b_appsplit -runall -log xsim_appsplit.log > NUL 2>&1
type xsim_appsplit.log
findstr /C:"FAIL" xsim_appsplit.log >NUL && exit /b 1
exit /b 0
