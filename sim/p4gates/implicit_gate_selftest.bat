@echo off
REM ===========================================================================
REM implicit_gate_selftest.bat -- pathological / clean / benign controls for
REM sim\p4gates\implicit_gate.bat.  Offline replay of frozen Vivado-2025.2 logs,
REM so it needs no toolchain and runs in about a second.
REM
REM usage: implicit_gate_selftest.bat        exit 0 = all controls as expected
REM Evidence + raw tool output: _proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md
REM ===========================================================================
setlocal
set D=%~dp0evidence\implicit_gate_2026-09-29
set G=%~dp0implicit_gate.bat
set BAD=0
echo ==========================================================================
echo  implicit_gate.bat self test -- controls a0 / a / a1 / a2 / b / c
echo ==========================================================================

echo.
echo ---- a0  PATHOLOGICAL design seen by XVLOG ONLY ---- EXPECT PASS(0)
echo      (this is the proof the OLD keyword gate was dumb: xvlog prints nothing)
call "%G%" "%D%\log_a_A1_xvlog_clean_SILENT.log.txt" CASE-a0-A1-xvlog
set EXP=0
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [a0] expected=%EXP% got=%GOT%

echo.
echo ---- a1  PATHOLOGICAL design seen by XELAB ---- EXPECT FAIL(1)
call "%G%" "%D%\log_a_A1_xelab_10-3091.log.txt" CASE-a1-A1-xelab
set EXP=1
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [a1] expected=%EXP% got=%GOT%

echo.
echo ---- a2  PATHOLOGICAL design (implicit net in an EXPRESSION) xvlog ---- EXPECT FAIL(1)
call "%G%" "%D%\log_a2_A2_xvlog_10-2989.log.txt" CASE-a2-A2-expr
set EXP=1
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [a2] expected=%EXP% got=%GOT%

echo.
echo ---- a3  PATHOLOGICAL design seen by SYNTH ---- EXPECT FAIL(1)
call "%G%" "%D%\log_a_A1_synth_8-11241.log.txt" CASE-a3-A1-synth
set EXP=1
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [a3] expected=%EXP% got=%GOT%

echo.
echo ---- b1  CLEAN design, xvlog ---- EXPECT PASS(0)
call "%G%" "%D%\log_b_B1_xvlog.log.txt" CASE-b1-clean-xvlog
set EXP=0
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [b1] expected=%EXP% got=%GOT%

echo.
echo ---- b2  CLEAN design, xelab ---- EXPECT PASS(0)
call "%G%" "%D%\log_b_B1_xelab.log.txt" CASE-b2-clean-xelab
set EXP=0
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [b2] expected=%EXP% got=%GOT%

echo.
echo ---- b3  CLEAN design, synth ---- EXPECT PASS(0)
call "%G%" "%D%\log_b_B1_synth.log.txt" CASE-b3-clean-synth
set EXP=0
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [b3] expected=%EXP% got=%GOT%

echo.
echo ---- c1  BENIGN WARNINGS only (synth 8-6014 / 8-7129 / 8-3917) ---- EXPECT PASS(0)
call "%G%" "%D%\log_c_C1_synth_benign_warnings.log.txt" CASE-c1-benign-synth
set EXP=0
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [c1] expected=%EXP% got=%GOT%

echo.
echo ---- c2  REAL production xvlog log (VRFC 10-3609 benign) ---- EXPECT PASS(0)
call "%G%" "%D%\log_c_REAL_production_xvlog_10-3609.log.txt" CASE-c2-real-prod
set EXP=0
if errorlevel 1 (set GOT=1) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [c2] expected=%EXP% got=%GOT%

echo.
echo ---- c3  missing log file ---- EXPECT FAIL(2)
call "%G%" "%D%\no_such_log.txt" CASE-c3-missing
set EXP=2
if errorlevel 2 (set GOT=2) else (set GOT=0)
if not "%GOT%"=="%EXP%" set BAD=1
echo [c3] expected=%EXP% got=%GOT%

echo.
if "%BAD%"=="1" (
  echo SELFTEST_RESULT = FAIL ^(at least one control did not behave as expected^)
  exit /b 1
)
echo SELFTEST_RESULT = PASS_ALL ^(9 controls: 4 pathological FAIL, 4 clean PASS, 1 missing-log FAIL^)
exit /b 0
