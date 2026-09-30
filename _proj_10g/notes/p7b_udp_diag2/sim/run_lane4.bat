@echo off
REM run_lane4.bat - P7B_LANEFIX: /S/ @ lane4 focused variant of the real-wrapper gate.
REM   Same compile defines / file list as _proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat
REM   (that is the canonical two-lane gate; this one exists as the permanent lane4
REM   regression + the pre-fix reproduction recipe).
REM   P7B_MUT=<dir>  -> take the MAC rtl from that dir instead (pre-fix A/B testing);
REM                     pre-fix copy lives in _proj_10g\notes\p7b_lanefix\mut_prefix\
REM   from Git Bash: cmd //c '_proj_10g\notes\p7b_udp_diag2\sim\run_lane4.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set "MACD=%ROOT%\_proj_10g\p7b_mac\rtl"
if not "%P7B_MUT%"=="" set "MACD=%P7B_MUT%"
if not exist "%MACD%\mac_rx_10g.v" (echo [PATHGUARD FAIL] no mac_rx_10g.v in %MACD% & exit /b 1)
echo [P7B LANE4 GATE] MAC RTL = %MACD%
if exist xsim.dir rmdir /s /q xsim.dir
if exist xsim_lane4.log del /q xsim_lane4.log
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
echo %~dp0tb_lane4.v                                          >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_lane4.log 2>&1 || (type xvlog_lane4.log & exit /b 1)
call %XV%\xvlog.bat -d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_lane4.log 2>&1 || (type xvlog_lane4.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_lane4.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_lane4.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_lane4.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_lane4.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p7b_appsplit xil_defaultlib.glbl -s tb_p7b_appsplit -log xelab_lane4.log > NUL 2>&1 || (type xelab_lane4.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_lane4.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_lane4.log & exit /b 1)
call %XV%\xsim.bat tb_p7b_appsplit -runall -log xsim_lane4.log > NUL 2>&1
type xsim_lane4.log
findstr /C:"FAIL" xsim_lane4.log >NUL && exit /b 1
exit /b 0
