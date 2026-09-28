@echo off
REM run_atk_reset.bat - adversarial gate C: reset
REM   usage: run_atk_reset.bat HA HB STEP MODE NPULSE
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\sim\snapcdc\atk
set HA=%1
if "%1"=="" set HA=2000
set HB=%2
if "%2"=="" set HB=4000
set STEP=%3
if "%3"=="" set STEP=100
set MODE=%4
if "%4"=="" set MODE=0
set NPULSE=%5
if "%5"=="" set NPULSE=40
echo [C] HA=%HA% HB=%HB% STEP=%STEP% MODE=%MODE%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\snap_cdc.v %ROOT%\tb_atk_reset.v > xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_atk.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_atk.log & exit /b 1)
findstr /C:"10-3091" xvlog_atk.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_atk.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_atk_reset xil_defaultlib.glbl -s tb_atk_reset -log xelab_atk.log > NUL 2>&1 || (type xelab_atk.log & exit /b 1)
call %XV%\xsim.bat tb_atk_reset -runall -log xsim_atk.log -testplusarg "HA=%HA%" -testplusarg "HB=%HB%" -testplusarg "STEP=%STEP%" -testplusarg "MODE=%MODE%" -testplusarg "NPULSE=%NPULSE%" -testplusarg "VLOG=%6" > NUL 2>&1
findstr /C:"RESET-RESULT" /C:"FAIL" /C:"PASS" /C:"NOTE" /C:"INFO" /C:"TIMEOUT" xsim_atk.log
