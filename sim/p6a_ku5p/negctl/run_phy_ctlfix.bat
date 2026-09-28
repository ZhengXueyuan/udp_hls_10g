@echo off
@echo off
REM negctl rgmii variant ctlfix
REM sources: D:\repo\XCKU5PMini\udp_hls_10g\sim\p6a_ku5p\negctl\tb_rgmii_phy_model_ctlfix.v D:\repo\XCKU5PMini\udp_hls_10g\board\util_gmii_to_rgmii_us.v D:\repo\XCKU5PMini\udp_hls_10g\board\util_gmii_to_rgmii.v
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\sim\p6a_ku5p\negctl\tb_rgmii_phy_model_ctlfix.v %ROOT%\board\util_gmii_to_rgmii_us.v %ROOT%\board\util_gmii_to_rgmii.v > xvlog_ctlfix.log 2>&1 || (type xvlog_ctlfix.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib %XV%\..\data\verilog\src\glbl.v >> xvlog_ctlfix.log 2>&1 || (type xvlog_ctlfix.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rgmii_phy_model xil_defaultlib.glbl -s tb_phy_ctlfix -log xelab_ctlfix.log > NUL 2>&1 || (type xelab_ctlfix.log & exit /b 1)
call %XV%\xsim.bat tb_phy_ctlfix -runall -log xsim_ctlfix.log > NUL 2>&1
findstr /C:"---" /C:"[TX]" /C:"[RX]" /C:"RESULT" /C:"VERDICT" /C:"TIMEOUT" xsim_ctlfix.log
