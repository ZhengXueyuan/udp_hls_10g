@echo off
REM ---------------------------------------------------------------------------
REM run_tb_fifo_async.bat -- fifo_async unit gate (self-checking TB, no Python).
REM usage: run_tb_fifo_async.bat [bal|wrfast|rdfast|bound|reset|clkstop|lat|early]
REM   default = bal. Each case runs in its OWN dir (%~dp0case_<case>).
REM Project traps handled here:
REM   7  : parallel gates must not share xsim.dir (a leftover lock => FALSE failure)
REM   24 : "implicitly" (implicit 1-bit wire) and VRFC 10-3091 (bit-width mismatch)
REM        are hard failures, not warnings.
REM bat rules: ASCII only + CRLF (non-ASCII comments break the GBK console).
REM exit 0 only when the TB prints "FIFO_ASYNC_GATE: PASS_ALL".
REM ---------------------------------------------------------------------------
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CASE=%1
if "%CASE%"=="" set CASE=bal
set PA=C_BAL
if /i "%CASE%"=="wrfast"  set PA=C_WRFAST
if /i "%CASE%"=="rdfast"  set PA=C_RDFAST
if /i "%CASE%"=="bound"   set PA=C_BOUND
if /i "%CASE%"=="reset"   set PA=C_RESET
if /i "%CASE%"=="clkstop" set PA=C_CLKSTOP
if /i "%CASE%"=="lat"     set PA=C_LAT
if /i "%CASE%"=="early"   set PA=C_EARLY
set CASEDIR=%~dp0case_%CASE%
if not exist "%CASEDIR%" mkdir "%CASEDIR%"
cd /d "%CASEDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\fifo_async.v %ROOT%\tb\tb_fifo_async.v > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_%CASE%.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_%CASE%.log & exit /b 1)
findstr /C:"10-3091" xvlog_%CASE%.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_%CASE%.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_fifo_async xil_defaultlib.glbl -s tb_fifo_async -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat tb_fifo_async -runall -testplusarg %PA% -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"FIFO_ASYNC_GATE: PASS_ALL" xsim_%CASE%.log >NUL
if errorlevel 1 (echo ---- FAIL detail [%CASE%]: & findstr /C:"FAIL-DETAIL" xsim_%CASE%.log & exit /b 1)
findstr /C:"FIFO_ASYNC_GATE" xsim_%CASE%.log
REM keep a committable copy of the RAW log (sim/**/*.log is gitignored; .txt is not)
if exist "%~dp0fingerprint.txt" copy /y "%~dp0fingerprint.txt" "%~dp0gate_%CASE%.txt" > NUL
type xsim_%CASE%.log >> "%~dp0gate_%CASE%.txt"
exit /b 0
