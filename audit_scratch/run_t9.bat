@echo off
REM run_t9.bat -- F-3 "MMCM 失锁->重锁" 判定实验 (t9_f3restart)
REM usage: run_t9.bat [old|new]   old = 现行接线 (rd_rst_n=reset_n)
REM                               new = 提议接线 (rd_rst_n=reset_n&dp_rst_n)
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CASE=%1
if "%CASE%"=="" set CASE=old
set DEFS=
if /i "%CASE%"=="new" set DEFS=-d WIRE_NEW
if /i "%CASE%"=="both" set DEFS=-d WIRE_BOTH
set CDIR=%~dp0t9_f3restart\case_%CASE%
if not exist "%CDIR%" mkdir "%CDIR%"
cd /d "%CDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DEFS% %ROOT%\rtl\crc32_8b.v %ROOT%\rtl\fifo_sync.v %ROOT%\rtl\fifo_async.v %ROOT%\rtl\mac_rx_64.v %ROOT%\rtl\vlan_strip.v %ROOT%\audit_scratch\t9_f3restart\tb_f3_restart.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log >NUL && (echo IMPLICIT-DECL-FAIL-VXLOG & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log & exit /b 1)
findstr /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" xvlog_run.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"VRFC 10-3091" xvlog_run.log & exit /b 1)
call %XV%\xelab.bat -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_f3_restart -s tb_f3_restart -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_f3_restart -runall -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"F3 " /C:"TB-" /C:"NOTE-" xsim_%CASE%.log
exit /b 0
