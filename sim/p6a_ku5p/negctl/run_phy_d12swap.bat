@echo off
@echo off
REM negctl rgmii mutation d12swap (TB=%ROOT%\tb\tb_rgmii_phy_model.v)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\tb\tb_rgmii_phy_model.v %ROOT%\sim\p6a_ku5p\negctl\util_gmii_to_rgmii_us_d12swap.v %ROOT%\board\util_gmii_to_rgmii.v > xvlog_d12swap.log 2>&1 || (type xvlog_d12swap.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib %XV%\..\data\verilog\src\glbl.v >> xvlog_d12swap.log 2>&1 || (type xvlog_d12swap.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rgmii_phy_model xil_defaultlib.glbl -s tb_phy_d12swap -log xelab_d12swap.log > NUL 2>&1 || (type xelab_d12swap.log & exit /b 1)
call %XV%\xsim.bat tb_phy_d12swap -runall -log xsim_d12swap.log > NUL 2>&1
findstr /C:"[TX]" /C:"[RX]" /C:"RESULT" /C:"VERDICT" /C:"TIMEOUT" xsim_d12swap.log
