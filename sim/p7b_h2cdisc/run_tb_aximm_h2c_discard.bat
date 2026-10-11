@echo off
REM run_tb_aximm_h2c_discard.bat -- M1 phase-B unit gate: aximm_h2c_discard (+3 mutation arms)
REM   usage: run_tb_aximm_h2c_discard.bat [real|mut_bid|mut_bearly|mut_wready]
REM     real   : compile rtl\aximm_h2c_discard.v               -> expect PASS_ALL
REM     mut_*  : compile a single-point mutant from mut_h2cdisc.py -> expect NOT PASS_ALL
REM   exit 0 only when the observed verdict matches the arm expectation
REM   (a mutant that PASSES = gate with no teeth => hard failure, project trap #18).
REM   Each arm runs in its OWN dir (trap 7: shared xsim.dir => false failures).
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set PY=C:\Users\zhxue\anaconda3\python.exe
set VAR=%1
if "%VAR%"=="" set VAR=real
set DUT=%ROOT%\rtl\aximm_h2c_discard.v
set EXPECT=PASS
if /i not "%VAR%"=="real" (
  set EXPECT=MUT
  %PY% "%~dp0mut_h2cdisc.py" --arm %VAR% --repo "%ROOT%" > "%~dp0mut_%VAR%_gen.txt" 2>&1
  type mut_%VAR%_gen.txt
  findstr /C:"MUT_H2CDISC_OK" "%~dp0mut_%VAR%_gen.txt" >NUL || (echo MUT-H2CDISC-GENFAIL & exit /b 1)
  set DUT=%ROOT%\sim\p7b_h2cdisc\mut\aximm_h2c_discard_%VAR%.v
)
cd /d %~dp0
if not exist xdir_%VAR% mkdir xdir_%VAR%
cd xdir_%VAR%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib "%DUT%" %ROOT%\tb\tb_aximm_h2c_discard.v > xvlog_out.log 2>&1 || (type xvlog_out.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_out.log 2>&1 || (type xvlog_out.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_out.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_out.log & exit /b 1)
findstr /C:"10-3091" xvlog_out.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_out.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_out.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_out.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_aximm_h2c_discard xil_defaultlib.glbl -s tb_aximm_h2c_discard -log xelab.log > NUL 2>&1 || (type xelab.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab.log & exit /b 1)
call %XV%\xsim.bat tb_aximm_h2c_discard -runall -log xsim.log > NUL 2>&1
findstr /C:"H2C_DISC_GATE" xsim.log
findstr /C:"TIMEOUT" xsim.log >NUL && (echo H2C-DISC-GATE-TIMEOUT & findstr /C:"INFO" xsim.log & exit /b 1)
findstr /C:"PASS_ALL" xsim.log >NUL
set RC=%ERRORLEVEL%
if "%EXPECT%"=="MUT" goto mut_arm
if %RC%==0 (echo H2C-DISC-GATE-VERDICT: PASS-as-expected & exit /b 0)
echo H2C-DISC-GATE-VERDICT: FAIL-UNEXPECTED
findstr /C:"[FAIL]" xsim.log
exit /b 1
:mut_arm
if %RC%==0 (echo H2C-DISC-GATE-VERDICT: MUTANT-NOT-CAUGHT & findstr /C:"[FAIL]" xsim.log & exit /b 1)
echo H2C-DISC-GATE-VERDICT: MUTANT-CAUGHT-as-expected
findstr /C:"[FAIL]" xsim.log
exit /b 0
