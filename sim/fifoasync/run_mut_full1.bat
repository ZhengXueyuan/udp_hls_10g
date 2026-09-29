@echo off
REM ---------------------------------------------------------------------------
REM run_mut_full1.bat -- MUTATION CHECK for the FULL-flag sync depth.
REM   DUT swapped for mut/mut_full_1stage.v: full_n compares against rgray_s1_w --
REM   ONE sync stage instead of two. Like the empty-side twin, the data path still
REM   works in a zero-delay behavioural simulator (a 1-stage sample of a monotonic
REM   pointer is still safe), so the golden-queue criteria CANNOT see it. Only the
REM   LAT contract on the FULL side ("full can never deassert earlier than the 4th
REM   wr edge after the pop") drops from eps+3T to eps+2T and catches it.
REM   EXPECTED RESULT: gate FAILS with "LAT_CONTRACT_VIOLATION".
REM bat rules: ASCII only + CRLF.
REM ---------------------------------------------------------------------------
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set MUT=%ROOT%\sim\fifoasync\mut\mut_full_1stage.v
set CASE=mut_full1
set CASEDIR=%~dp0case_%CASE%
if not exist "%CASEDIR%" mkdir "%CASEDIR%"
cd /d "%CASEDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %MUT% %ROOT%\tb\tb_fifo_async.v > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_%CASE%.log >NUL && (echo IMPLICIT-DECL-FAIL & exit /b 1)
findstr /C:"10-3091" xvlog_%CASE%.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_fifo_async xil_defaultlib.glbl -s tb_fifo_async -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat tb_fifo_async -runall -testplusarg C_LAT -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"LAT_CONTRACT_VIOLATION" xsim_%CASE%.log >NUL
if errorlevel 1 (echo MUTANT-NOT-CAUGHT & findstr /C:"FIFO_ASYNC_GATE" xsim_%CASE%.log & exit /b 1)
findstr /C:"LAT_CONTRACT_VIOLATION" xsim_%CASE%.log
echo MUTANT-CAUGHT-OK
REM keep a committable copy of the RAW log (sim/**/*.log is gitignored; .txt is not)
if exist "%~dp0fingerprint.txt" copy /y "%~dp0fingerprint.txt" "%~dp0gate_%CASE%.txt" > NUL
type xsim_%CASE%.log >> "%~dp0gate_%CASE%.txt"
exit /b 0
