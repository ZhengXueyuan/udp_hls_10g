@echo off
REM ---------------------------------------------------------------------------
REM run_mut_empty1.bat -- MUTATION CHECK for the sync-depth latency contract.
REM   DUT swapped for mut/mut_empty_1stage.v: empty_n (and hence the empty flag)
REM   compares against wgray_s1_r -- ONE sync stage instead of two. Functionally the
REM   data path still works in a behavioural simulator (no metastability model!), so
REM   the golden-queue criteria CANNOT see it. The only criterion that can is the
REM   LAT contract ("empty can never deassert earlier than the 4th rd edge after the
REM   write"), which drops from eps+3T to eps+2T.
REM   EXPECTED RESULT: the gate must FAIL and the log must contain the ASCII marker
REM   "LAT_CONTRACT_VIOLATION". MUTANT-NOT-CAUGHT => the LAT criterion is vacuous.
REM bat rules: ASCII only + CRLF.
REM ---------------------------------------------------------------------------
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set MUT=%ROOT%\sim\fifoasync\mut\mut_empty_1stage.v
set CASE=mut_empty1
set CASEDIR=%~dp0case_%CASE%
if not exist "%CASEDIR%" mkdir "%CASEDIR%"
cd /d "%CASEDIR%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %MUT% %ROOT%\tb\tb_fifo_async.v > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_%CASE%.log >NUL && (echo IMPLICIT-DECL-FAIL & exit /b 1)
findstr /C:"10-3091" xvlog_%CASE%.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_fifo_async xil_defaultlib.glbl -s tb_fifo_async -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_%CASE%.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat tb_fifo_async -runall -testplusarg C_LAT -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"LAT_CONTRACT_VIOLATION" xsim_%CASE%.log >NUL
if errorlevel 1 (echo MUTANT-NOT-CAUGHT & findstr /C:"FIFO_ASYNC_GATE" xsim_%CASE%.log & exit /b 1)
findstr /C:"LAT_CONTRACT_VIOLATION" xsim_%CASE%.log
echo MUTANT-CAUGHT-OK
REM keep a committable copy of the RAW log (sim/**/*.log is gitignored; .txt is not)
if exist "%~dp0fingerprint.txt" copy /y "%~dp0fingerprint.txt" "%~dp0gate_%CASE%.txt" > NUL
type xsim_%CASE%.log >> "%~dp0gate_%CASE%.txt"
exit /b 0
