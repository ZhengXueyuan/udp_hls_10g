@echo off
REM run_atk_req.bat - adversarial gate D: extreme req usage
REM   usage: run_atk_req.bat HA HB STEP NB2B
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\sim\snapcdc\atk
set HA=%1
if "%1"=="" set HA=2000
set HB=%2
if "%2"=="" set HB=4000
set STEP=%3
if "%3"=="" set STEP=100
set NB2B=%4
if "%4"=="" set NB2B=200
echo [D] HA=%HA% HB=%HB% STEP=%STEP% NB2B=%NB2B%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\snap_cdc.v %ROOT%\tb_atk_req.v > xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_atk.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_atk.log & exit /b 1)
findstr /C:"10-3091" xvlog_atk.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_atk.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_atk_req xil_defaultlib.glbl -s tb_atk_req -log xelab_atk.log > NUL 2>&1 || (type xelab_atk.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_atk.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_atk.log & exit /b 1)
call %XV%\xsim.bat tb_atk_req -runall -log xsim_atk.log -testplusarg "HA=%HA%" -testplusarg "HB=%HB%" -testplusarg "STEP=%STEP%" -testplusarg "NB2B=%NB2B%" > NUL 2>&1
findstr /C:"REQ-RESULT" /C:"FAIL" /C:"PASS" /C:"INFO" /C:"TIMEOUT" xsim_atk.log
