@echo off
REM run_atk_phase.bat - adversarial gate B: sub-cycle phase sweep + word glitch
REM   usage: run_atk_phase.bat HA HB STEP NLOOP VLOG
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\sim\snapcdc\atk
set HA=%1
if "%1"=="" set HA=2000
set HB=%2
if "%2"=="" set HB=4000
set STEP=%3
if "%3"=="" set STEP=100
set NLOOP=%4
if "%4"=="" set NLOOP=1
set VLOG=%5
if "%5"=="" set VLOG=0
set WT=2000000000
echo [B] HA=%HA% HB=%HB% STEP=%STEP% NLOOP=%NLOOP%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\snap_cdc.v %ROOT%\tb_atk_phase.v > xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_atk.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_atk.log & exit /b 1)
findstr /C:"10-3091" xvlog_atk.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_atk.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_atk_phase xil_defaultlib.glbl -s tb_atk_phase -log xelab_atk.log > NUL 2>&1 || (type xelab_atk.log & exit /b 1)
call %XV%\xsim.bat tb_atk_phase -runall -log xsim_atk.log -testplusarg "HA=%HA%" -testplusarg "HB=%HB%" -testplusarg "STEP=%STEP%" -testplusarg "NLOOP=%NLOOP%" -testplusarg "VLOG=%VLOG%" -testplusarg "WT=%WT%" > NUL 2>&1
findstr /C:"PHASE-RESULT" /C:"FAIL" /C:"PASS" /C:"WARN" /C:"INFO" /C:"TIMEOUT" xsim_atk.log
