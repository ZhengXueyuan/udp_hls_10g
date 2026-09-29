@echo off
REM review_scratch: run tb_fifo_async against an arbitrary DUT file
REM usage: run.bat <dutfile> <testplusarg> <rundir>
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set DUT=%1
set PA=%2
set RD=%3
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g\review_scratch\rw
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib "%DUT%" "%ROOT%\tb_fifo_async.v" > xv_rv.log 2>&1 || (type xv_rv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_rv.log 2>&1 || (type xv_rv.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_rv.log >NUL && (echo IMPLICIT-DECL-FAIL & exit /b 1)
findstr /C:"10-3091" xv_rv.log >NUL && (echo BITWIDTH-FAIL & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_fifo_async xil_defaultlib.glbl -s tb_fifo_async -log xe_rv.log > NUL 2>&1 || (type xe_rv.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_rv.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_rv.log & exit /b 1)
call %XV%\xsim.bat tb_fifo_async -runall -testplusarg %PA% -log xs_rv.log > NUL 2>&1
findstr /C:"FIFO_ASYNC_GATE" xs_rv.log
findstr /C:"FIFO_ASYNC_GATE: PASS_ALL" xs_rv.log >NUL
if errorlevel 1 (echo GATE-RESULT: FAIL & findstr /C:"FAIL-DETAIL" xs_rv.log & exit /b 1)
echo GATE-RESULT: PASS_ALL
exit /b 0
