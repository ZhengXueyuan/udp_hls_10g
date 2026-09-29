@echo off
REM T2 frontend gate: behavioral RTL8211E model (RXDLY=1/TXDLY=1) round trip
REM   (implicit nets and bit-width mismatches are hard failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\board\util_gmii_to_rgmii_us.v %ROOT%\board\util_gmii_to_rgmii.v %ROOT%\tb\tb_rgmii_phy_model.v > xvlog_phym.log 2>&1 || (type xvlog_phym.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_phym.log 2>&1 || (type xvlog_phym.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_phym.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_phym.log & exit /b 1)
findstr /C:"10-3091" xvlog_phym.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_phym.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rgmii_phy_model xil_defaultlib.glbl -s tb_rgmii_phy_model -log xelab_phym.log > NUL 2>&1 || (type xelab_phym.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_phym.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_phym.log & exit /b 1)
call %XV%\xsim.bat tb_rgmii_phy_model -runall -log xsim_phym.log > NUL 2>&1
findstr /C:"---" /C:"[TX]" /C:"[RX]" /C:"RESULT" /C:"VERDICT" xsim_phym.log