@echo off
@echo off
REM negctl: ctlfix TB + K7-noinv front end
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\sim\p6a_ku5p\negctl\tb_rgmii_phy_model_ctlfix.v %ROOT%\sim\p6a_ku5p\negctl\util_gmii_to_rgmii_k7_noinv.v %ROOT%\board\util_gmii_to_rgmii_us.v > xvlog_ctlfix_k7noinv.log 2>&1 || (type xvlog_ctlfix_k7noinv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib %XV%\..\data\verilog\src\glbl.v >> xvlog_ctlfix_k7noinv.log 2>&1 || (type xvlog_ctlfix_k7noinv.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rgmii_phy_model xil_defaultlib.glbl -s tb_phyctl_k7noinv -log xelab_ctlfix_k7noinv.log > NUL 2>&1 || (type xelab_ctlfix_k7noinv.log & exit /b 1)
call %XV%\xsim.bat tb_phyctl_k7noinv -runall -log xsim_ctlfix_k7noinv.log > NUL 2>&1
findstr /C:"[TX]" /C:"[RX]" /C:"RESULT" /C:"VERDICT" /C:"TIMEOUT" xsim_ctlfix_k7noinv.log
