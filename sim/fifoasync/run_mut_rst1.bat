@echo off
REM ---------------------------------------------------------------------------
REM run_mut_rst1.bat -- MUTATION CHECK for the reset synchronizer depth.
REM   DUT swapped for mut/mut_rst_1stage.v: both domain reset synchronizers are cut
REM   to a single flop (async assert, ONE-cycle synchronous release).
REM   What this probe is really asking: is the gate sensitive to the reset-release
REM   structure at all? The golden model in the TB mirrors the DUT's 2-FF release
REM   chain; a 1-FF release makes the DUT leave reset one clock earlier than the
REM   model, so the model loses track of the very first accepted write.
REM   MEASURED RESULT (2026-09-29): **NOT CAUGHT** -- the gate prints PASS_ALL for this
REM   mutant. Reason: the driver offers its first write 1-2 clocks after the release
REM   anyway, so a one-clock-earlier release changes nothing observable. Same class of
REM   limitation as metastability: a zero-delay simulator cannot see reset-release
REM   timing either. NOT part of run_all.bat -- this is a probe (no pass/fail verdict),
REM   kept on record so the limitation is explicit instead of silently unknown.
REM bat rules: ASCII only + CRLF.
REM ---------------------------------------------------------------------------
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set MUT=%ROOT%\sim\fifoasync\mut\mut_rst_1stage.v
set CASE=mut_rst1
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
call %XV%\xsim.bat tb_fifo_async -runall -testplusarg C_RESET -log xsim_%CASE%.log > NUL 2>&1
findstr /C:"FIFO_ASYNC_GATE: PASS_ALL" xsim_%CASE%.log >NUL
if errorlevel 1 (echo RST-SYNC-DEPTH-OBSERVABLE) else (echo RST-SYNC-DEPTH-NOT-OBSERVABLE ^(documented limitation^))
REM keep a committable copy of the RAW log (sim/**/*.log is gitignored; .txt is not)
if exist "%~dp0fingerprint.txt" copy /y "%~dp0fingerprint.txt" "%~dp0gate_%CASE%.txt" > NUL
type xsim_%CASE%.log >> "%~dp0gate_%CASE%.txt"
exit /b 0
