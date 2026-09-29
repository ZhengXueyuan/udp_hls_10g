@echo off
REM run_t1.bat -- bit/field span gate for the two P6b CDC FIFOs (audit_scratch/t1_bits).
REM usage: run_t1.bat [pos|mutw75|mutswap]   (default pos)
REM   pos     : expected PASS
REM   mutw75  : FIFO port width = W-1 (silent MSB truncation) -> MUST FAIL
REM   mutswap : read-side field unpack swapped (clean compile)   -> MUST FAIL
REM own xsim.dir per case (project rule 7). exit 0 only when CDC_BITS: PASS_ALL.
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CASE=%1
if "%CASE%"=="" set CASE=pos
set DEFS=
if /i "%CASE%"=="mutw75"  set DEFS=-d MUT_W75
if /i "%CASE%"=="mutswap" set DEFS=-d MUT_SWAP
set CDIR=%~dp0t1_bits\case_%CASE%
if not exist "%CDIR%" mkdir "%CDIR%"
cd /d "%CDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DEFS% %ROOT%\rtl\fifo_async.v %ROOT%\audit_scratch\t1_bits\tb_cdc_bits.v > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_%CASE%.log >NUL && echo NOTE-IMPLICIT-DECL
findstr /C:"10-3091" xvlog_%CASE%.log >NUL && echo NOTE-BITWIDTH-MISMATCH
call %XV%\xelab.bat -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_cdc_bits -s tb_cdc_bits -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat tb_cdc_bits -runall -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"RESULT" /C:"CDC_SPAN_TOTAL" /C:"CDC_BITS" /C:"BAD-" /C:"CONS-FAIL" /C:"INCOMPLETE" /C:"TIMEOUT" /C:"NOTE-" xsim_%CASE%.log
findstr /C:"CDC_BITS: PASS_ALL" xsim_%CASE%.log >NUL
if errorlevel 1 (echo T1[%CASE%] FAIL & exit /b 1)
echo T1[%CASE%] PASS
exit /b 0
