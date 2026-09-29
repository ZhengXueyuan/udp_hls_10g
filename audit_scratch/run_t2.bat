@echo off
REM run_t2.bat -- RX CDC-boundary chain gate (audit_scratch/t2_rxcdc).
REM usage: run_t2.bat [pos|neg_late|neg_nobp]   (default pos)
REM   pos      : expected PASS
REM   neg_late : registered tready (pop != CDC write)  -> MUST FAIL (R1)
REM   neg_nobp : tready tied 1 (full ignored)          -> MUST FAIL (R1)
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CASE=%1
if "%CASE%"=="" set CASE=pos
set DEFS=
if /i "%CASE%"=="neg_late" set DEFS=-d NEG_LATE_GATE
if /i "%CASE%"=="neg_nobp" set DEFS=-d NEG_NO_BP
set CDIR=%~dp0t2_rxcdc\case_%CASE%
if not exist "%CDIR%" mkdir "%CDIR%"
cd /d "%CDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DEFS% %ROOT%\rtl\crc32_8b.v %ROOT%\rtl\fifo_sync.v %ROOT%\rtl\fifo_async.v %ROOT%\rtl\mac_rx_64.v %ROOT%\audit_scratch\t2_rxcdc\tb_rx_cdc_chain.v > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_%CASE%.log >NUL && echo NOTE-IMPLICIT-DECL
findstr /C:"10-3091" xvlog_%CASE%.log >NUL && echo NOTE-BITWIDTH-MISMATCH
call %XV%\xelab.bat -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_rx_cdc_chain -s tb_rx_cdc_chain -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat tb_rx_cdc_chain -runall -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"RXCHAIN" /C:"TB-CRC-SELFTEST-FAIL" /C:"NOTE-" xsim_%CASE%.log
findstr /C:"RXCHAIN: PASS_ALL" xsim_%CASE%.log >NUL
if errorlevel 1 (echo T2[%CASE%] FAIL & exit /b 1)
echo T2[%CASE%] PASS
exit /b 0
