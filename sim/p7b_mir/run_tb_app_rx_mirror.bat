@echo off
REM run_tb_app_rx_mirror.bat -- M1 payload-mirror unit gate (self-checking TB, no Python)
REM   usage: run_tb_app_rx_mirror.bat [real|mut_gate|mut_order]
REM     real      : compile rtl\app_rx_mirror.v                    -> expect PASS_ALL
REM     mut_gate  : compile mut\app_rx_mirror_mut_gate.v  (wr_en=have, no !full)
REM                 -> MUST be caught: expect NOT PASS_ALL
REM     mut_order : compile mut\app_rx_mirror_mut_order.v (2-byte mv b0/b1 swapped)
REM                 -> MUST be caught: expect NOT PASS_ALL
REM   exit 0 only when the observed verdict matches the arm's expectation
REM   (a mutant that PASSES is a gate with no teeth => hard failure, project trap #18).
REM   Each arm runs in its OWN dir (project trap 7: shared xsim.dir => false failures).
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set VAR=%1
if "%VAR%"=="" set VAR=real
set DUT=%ROOT%\rtl\app_rx_mirror.v
set EXPECT=PASS
if /i "%VAR%"=="mut_gate"  set DUT=%ROOT%\sim\p7b_mir\mut\app_rx_mirror_mut_gate.v
if /i "%VAR%"=="mut_gate"  set EXPECT=MUT
if /i "%VAR%"=="mut_order" set DUT=%ROOT%\sim\p7b_mir\mut\app_rx_mirror_mut_order.v
if /i "%VAR%"=="mut_order" set EXPECT=MUT
cd /d %~dp0
if not exist xdir_%VAR% mkdir xdir_%VAR%
cd xdir_%VAR%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DUT% %ROOT%\rtl\fifo_async.v %ROOT%\tb\tb_app_rx_mirror.v > xvlog_out.log 2>&1 || (type xvlog_out.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_out.log 2>&1 || (type xvlog_out.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_out.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_out.log & exit /b 1)
findstr /C:"10-3091" xvlog_out.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_out.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_out.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_out.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_app_rx_mirror xil_defaultlib.glbl -s tb_app_rx_mirror -log xelab.log > NUL 2>&1 || (type xelab.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab.log & exit /b 1)
call %XV%\xsim.bat tb_app_rx_mirror -runall -log xsim.log > NUL 2>&1
findstr /C:"APP_RX_MIRROR_GATE" xsim.log
findstr /C:"TIMEOUT" xsim.log >NUL && (echo MIRROR-GATE-TIMEOUT & findstr /C:"INFO" xsim.log & exit /b 1)
findstr /C:"PASS_ALL" xsim.log >NUL
set RC=%ERRORLEVEL%
if "%EXPECT%"=="MUT" goto mut_arm
if %RC%==0 (echo MIRROR-GATE-VERDICT: PASS-as-expected & exit /b 0)
echo MIRROR-GATE-VERDICT: FAIL-UNEXPECTED
findstr /C:"[FAIL]" xsim.log
exit /b 1
:mut_arm
if %RC%==0 (echo MIRROR-GATE-VERDICT: MUTANT-NOT-CAUGHT & findstr /C:"[FAIL]" xsim.log & exit /b 1)
echo MIRROR-GATE-VERDICT: MUTANT-CAUGHT-as-expected
findstr /C:"[FAIL]" xsim.log
exit /b 0
