@echo off
REM run_atk_x.bat - adversarial gate E: X propagation
REM   usage: run_atk_x.bat HA HB
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\sim\snapcdc\atk
set HA=%1
if "%1"=="" set HA=2000
set HB=%2
if "%2"=="" set HB=4000
echo [E] HA=%HA% HB=%HB%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\snap_cdc.v %ROOT%\tb_atk_x.v > xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_atk.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_atk.log & exit /b 1)
findstr /C:"10-3091" xvlog_atk.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_atk.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_atk_x xil_defaultlib.glbl -s tb_atk_x -log xelab_atk.log > NUL 2>&1 || (type xelab_atk.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_atk.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_atk.log & exit /b 1)
call %XV%\xsim.bat tb_atk_x -runall -log xsim_atk.log -testplusarg "HA=%HA%" -testplusarg "HB=%HB%" > NUL 2>&1
findstr /C:"X-RESULT" /C:"FAIL" /C:"PASS" /C:"NOTE" /C:"INFO" /C:"TIMEOUT" xsim_atk.log
