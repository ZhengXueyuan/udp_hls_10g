@echo off
REM run_t3.bat -- TX CDC-boundary chain gate + F-2 (mid-frame abort residue) A/B.
REM usage: run_t3.bat [pos|orig|nostall_new|nostall_orig]   (default pos)
REM   pos          : NEW rtl/mac_tx_64.v  + GAP=12000 -> expect PASS, ghost=0
REM   orig         : OLD mac_tx_64 (audit_scratch/rtl_orig copy) + GAP=12000
REM                  -> negative control: MUST FAIL (ghost=1)
REM   nostall_new  : NEW rtl, GAP=0 (no abort) -> expect PASS; FPRINT wf == nostall_orig
REM   nostall_orig : OLD rtl, GAP=0          -> expect PASS; FPRINT wf must match
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CASE=%1
if "%CASE%"=="" set CASE=pos
set RTL=%ROOT%\rtl\mac_tx_64.v
set DEFS=-d F2_RTL
set PA=
set GAP=12000
if /i "%CASE%"=="orig"         set RTL=%ROOT%\audit_scratch\rtl_orig\mac_tx_64.v
if /i "%CASE%"=="orig"         set DEFS=
if /i "%CASE%"=="nostall_new"  set PA=-testplusarg NOSTALL
if /i "%CASE%"=="nostall_new"  set GAP=0
if /i "%CASE%"=="nostall_orig" set RTL=%ROOT%\audit_scratch\rtl_orig\mac_tx_64.v
if /i "%CASE%"=="nostall_orig" set DEFS=
if /i "%CASE%"=="nostall_orig" set PA=-testplusarg NOSTALL
if /i "%CASE%"=="nostall_orig" set GAP=0
set CDIR=%~dp0t3_txcdc\case_%CASE%
if not exist "%CDIR%" mkdir "%CDIR%"
cd /d "%CDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DEFS% %ROOT%\rtl\crc32_8b.v %ROOT%\rtl\fifo_sync.v %ROOT%\rtl\fifo_async.v %RTL% %ROOT%\audit_scratch\t3_txcdc\tb_tx_cdc_chain.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log >NUL && (echo IMPLICIT-DECL-FAIL-VXLOG & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log & exit /b 1)
findstr /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" xvlog_run.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"VRFC 10-3091" xvlog_run.log & exit /b 1)
call %XV%\xelab.bat -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tx_cdc_chain -s tb_tx_cdc_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_tx_cdc_chain -runall %PA% -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"TXCHAIN" /C:"WIRE" /C:"NOTE-" xsim_%CASE%.log
findstr /C:"TXCHAIN: PASS_ALL" xsim_%CASE%.log >NUL
if errorlevel 1 (echo T3[%CASE%] FAIL & exit /b 1)
echo T3[%CASE%] PASS
exit /b 0
