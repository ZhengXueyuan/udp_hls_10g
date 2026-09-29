@echo off
REM run_t4.bat -- CDC reset / clock-stop boundary gate (audit_scratch/t4_reset).
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CDIR=%~dp0t4_reset\case
if not exist "%CDIR%" mkdir "%CDIR%"
cd /d "%CDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\fifo_async.v %ROOT%\audit_scratch\t4_reset\tb_cdc_reset.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log >NUL && (echo IMPLICIT-DECL-FAIL-VXLOG & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log & exit /b 1)
findstr /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" xvlog_run.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"VRFC 10-3091" xvlog_run.log & exit /b 1)
call %XV%\xelab.bat -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_cdc_reset -s tb_cdc_reset -log xelab.log > NUL 2>&1 || (type xelab.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab.log & exit /b 1)
call %XV%\xsim.bat tb_cdc_reset -runall -log xsim.log > NUL 2>&1
findstr /C:"RST" /C:"RESET" /C:"NOTE-" xsim.log
findstr /C:"RESET DONE" xsim.log >NUL || exit /b 1
exit /b 0
