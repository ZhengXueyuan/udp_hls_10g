@echo off
REM run_tb_mir_dma.bat -- M1 phase-B unit gate: mir_dma_ring + aximm_c2h_win (+ 3 mutation arms)
REM   usage: run_tb_mir_dma.bat [real|mut_rid|mut_rlast|mut_row]
REM     real   : compile rtl\aximm_c2h_win.v               -> expect PASS_ALL
REM     mut_*  : compile a single-point mutant from mut_aximm.py -> expect NOT PASS_ALL
REM   exit 0 only when the observed verdict matches the arm expectation
REM   (a mutant that PASSES = gate with no teeth => hard failure, project trap #18).
REM   Each arm runs in its OWN dir (trap 7: shared xsim.dir => false failures).
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set PY=C:\Users\zhxue\anaconda3\python.exe
set VAR=%1
if "%VAR%"=="" set VAR=real
set AXIMM=%ROOT%\rtl\aximm_c2h_win.v
set EXPECT=PASS
if /i not "%VAR%"=="real" (
  set EXPECT=MUT
  %PY% "%~dp0mut_aximm.py" --arm %VAR% --repo "%ROOT%" > mut_%VAR%_gen.txt 2>&1
  type mut_%VAR%_gen.txt
  findstr /C:"MUT_AXIMM_OK" mut_%VAR%_gen.txt >NUL || (echo MUT-AXIMM-GENFAIL & exit /b 1)
  set AXIMM=%ROOT%\sim\p7b_mirdma\mut\aximm_c2h_win_%VAR%.v
)
cd /d %~dp0
if not exist xdir_%VAR% mkdir xdir_%VAR%
cd xdir_%VAR%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib "%AXIMM%" %ROOT%\rtl\mir_dma_ring.v %ROOT%\tb\tb_mir_dma.v > xvlog_out.log 2>&1 || (type xvlog_out.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_out.log 2>&1 || (type xvlog_out.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_out.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_out.log & exit /b 1)
findstr /C:"10-3091" xvlog_out.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_out.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_out.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_out.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_mir_dma xil_defaultlib.glbl -s tb_mir_dma -log xelab.log > NUL 2>&1 || (type xelab.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab.log & exit /b 1)
call %XV%\xsim.bat tb_mir_dma -runall -log xsim.log > NUL 2>&1
findstr /C:"MIR_DMA_GATE" xsim.log
findstr /C:"TIMEOUT" xsim.log >NUL && (echo MIR-DMA-GATE-TIMEOUT & findstr /C:"INFO" xsim.log & exit /b 1)
findstr /C:"PASS_ALL" xsim.log >NUL
set RC=%ERRORLEVEL%
if "%EXPECT%"=="MUT" goto mut_arm
if %RC%==0 (echo MIR-DMA-GATE-VERDICT: PASS-as-expected & exit /b 0)
echo MIR-DMA-GATE-VERDICT: FAIL-UNEXPECTED
findstr /C:"[FAIL]" xsim.log
exit /b 1
:mut_arm
if %RC%==0 (echo MIR-DMA-GATE-VERDICT: MUTANT-NOT-CAUGHT & findstr /C:"[FAIL]" xsim.log & exit /b 1)
echo MIR-DMA-GATE-VERDICT: MUTANT-CAUGHT-as-expected
findstr /C:"[FAIL]" xsim.log
exit /b 0
