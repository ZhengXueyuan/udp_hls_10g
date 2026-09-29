@echo off
REM run_negctrl_2rst.bat - scratch falsification test: do two independent domain resets
REM   deadlock the toggle handshake? (validates the claim in rtl/snap_cdc.v header)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib snap_cdc_2rst.v tb_negctrl_2rst.v > xvlog_neg.log 2>&1 || (type xvlog_neg.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_neg.log 2>&1 || (type xvlog_neg.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_neg.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_neg.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_negctrl_2rst xil_defaultlib.glbl -s tb_negctrl_2rst -log xelab_neg.log > NUL 2>&1 || (type xelab_neg.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_neg.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_neg.log & exit /b 1)
call %XV%\xsim.bat tb_negctrl_2rst -runall -log xsim_neg.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"INFO" /C:"RESULT" /C:"NEGCTRL" /C:"TIMEOUT" xsim_neg.log
