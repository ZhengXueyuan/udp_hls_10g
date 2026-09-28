@echo off
REM run_atk_ratio.bat - adversarial gate A: extreme clock ratios / real usage
REM   usage: run_atk_ratio.bat HA HB MODE NVAL [KA] [VLOG]
REM   hard failures: implicit nets and bit-width mismatches (project trap 24)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\sim\snapcdc\atk
set HA=%1
if "%1"=="" set HA=2000
set HB=%2
if "%2"=="" set HB=4000
set MODE=%3
if "%3"=="" set MODE=1
set NVAL=%4
if "%4"=="" set NVAL=200
set KA=%5
if "%5"=="" set KA=7
set VLOG=%6
if "%6"=="" set VLOG=0
set WT=2000000000
echo [A] HA=%HA%ps HB=%HB%ps MODE=%MODE% NVAL=%NVAL% KA=%KA%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\snap_cdc.v %ROOT%\tb_atk_ratio.v > xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_atk.log 2>&1 || (type xvlog_atk.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_atk.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_atk.log & exit /b 1)
findstr /C:"10-3091" xvlog_atk.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_atk.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_atk_ratio xil_defaultlib.glbl -s tb_atk_ratio -log xelab_atk.log > NUL 2>&1 || (type xelab_atk.log & exit /b 1)
call %XV%\xsim.bat tb_atk_ratio -runall -log xsim_atk.log -testplusarg "HA=%HA%" -testplusarg "HB=%HB%" -testplusarg "MODE=%MODE%" -testplusarg "NVAL=%NVAL%" -testplusarg "KA=%KA%" -testplusarg "VLOG=%VLOG%" -testplusarg "WT=%WT%" > NUL 2>&1
findstr /C:"RATIO-RESULT" /C:"FAIL" /C:"NEG-OK" /C:"INFO" /C:"LOG" /C:"TIMEOUT" xsim_atk.log
