@echo off
REM ===========================================================================
REM run_neg.bat -- P7B-BIZ: prove run_tb_biz_win has teeth (mutation test)
REM   Three mutants of axi_regs.v, each = one defect this project has suffered:
REM     mut_base6   : snap_base narrowed to [5:0]   (high words wrap silently)
REM     mut_dec6    : ar_word/r_word back to 6 bits (0x100 aliases to word 0)
REM     mut_lastoff : SNAP_LAST_IDX off by one      (window boundary shifted)
REM   Expectation: mutants FAIL, the real file PASSES. Exit 0 iff so.
REM   ASCII-only on purpose (project rule for .bat).
REM ===========================================================================
setlocal enabledelayedexpansion
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set D=%~dp0
set TB=%D%tb_biz_win.v
set NBAD=0
call :one "real"       "%D%..\..\..\_proj_pcie\rtl\axi_regs.v" PASS
call :one "mut_base6"  "%D%neg\axi_regs_mut_base6.v"        FAIL
call :one "mut_dec6"   "%D%neg\axi_regs_mut_dec6.v"         FAIL
call :one "mut_lastoff" "%D%neg\axi_regs_mut_lastoff.v"     FAIL
echo.
if %NBAD% NEQ 0 ( echo NEG_GATE_FAIL %NBAD% & exit /b 1 )
echo NEG_GATE_PASS 4/4
exit /b 0

:one
set TAG=%~1
set SRC=%~2
set WANT=%~3
set WD=%D%neg\w_%TAG%
if not exist "%WD%" mkdir "%WD%"
pushd "%WD%"
REM NOTE: log name must NOT be xvlog.log (that is xvlog's own default log -> handle clash)
call "%XV%\xvlog.bat" -work xil_defaultlib "%SRC%" "%TB%" > xv_biz.log 2>&1
if errorlevel 1 ( echo [BAD ] %TAG% xvlog-fatal & type xv_biz.log & popd & set /a NBAD+=1 & exit /b 0 )
call "%XV%\xvlog.bat" -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_biz.log 2>&1
call "%XV%\xelab.bat" -debug typical -L unisims_ver xil_defaultlib.tb_biz_win xil_defaultlib.glbl -s tb -log xelab_biz.log > NUL 2>&1
if errorlevel 1 ( echo [BAD ] %TAG% xelab-fatal & popd & set /a NBAD+=1 & exit /b 0 )
call "%XV%\xsim.bat" tb -runall -log xsim_biz.log > NUL 2>&1
REM NOTE: keep the parens -- a trailing space in the value breaks the compare below
findstr /C:"PASS_ALL" xsim_biz.log >NUL && (set GOT=PASS) || (set GOT=FAIL)
popd
if "!GOT!"=="%WANT%" ( echo [OK  ] %TAG% got=!GOT! want=%WANT% ) else ( echo [BAD ] %TAG% got=!GOT! want=%WANT% & set /a NBAD+=1 )
exit /b 0
