@echo off
setlocal
REM =====================================================================
REM run_tailcarry_gate.bat -- P7B-GAP9-TX / TX_TAILCARRY gate (self-locating)
REM   ARM A: default (no macro)                 expect RC 0
REM   ARM B: -d P7B_10G                         expect RC 0   (ref: A2, carry off)
REM   ARM C: -d P7B_10G -d APP_TC_ARM           expect RC 0   (DELIVERY: A2 + carry on)
REM   ARM D: -d APP_TC_ARM                      expect RC 0   (param gate: no P7B_10G)
REM Criteria:
REM   1) A/B/C/D RC 0  (in-TB criteria G1..G16 all green)
REM   2) B vs C: finite-session instances (d0..d2.hex, f0..f2.txt) byte-identical
REM              = tail-carry byte-equivalence gate (on vs off arms)
REM   3) A vs D: all dump/stats/rate byte-identical = "param gate inert w/o macro"
REM   4) counter non-zero readings + negative control: covered by in-TB G7/G8/G9
REM      (raw readings printed in xs.log)
REM   5) compile-source witness: A/B/C/D must all compile the LIVE rtl\app_pattern.v
REM NOTE: never redirect into a name the tool itself uses (xvlog.log / xelab.log
REM       / xsim.log) -- cmd holds the handle and the tool then fails to open it.
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate repo root from %~f0
  echo   derived ROOT = %ROOT%
  exit /b 1
)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl\app_pattern.v"
set "TB=%ROOT%\tb\tb_app_tailcarry.v"
set "PY=C:\Users\zhxue\anaconda3\python.exe"
cd /d "%HERE%"

if not exist "%RTL%" (echo [FAIL] RTL missing & exit /b 1)
if not exist "%TB%"  (echo [FAIL] TB missing & exit /b 1)
if not exist "%PY%" (echo [FAIL] python not found: %PY% & exit /b 1)
"%PY%" "tc_mut\mk_mut_tc.py" "%ROOT%" > tc_mut\mutgen.log 2>&1 || (type tc_mut\mutgen.log & echo MUTGEN-FAIL & exit /b 1)

call :run A "" "%RTL%"
set "RCA=%errorlevel%"
call :run B "-d P7B_10G" "%RTL%"
set "RCB=%errorlevel%"
call :run C "-d P7B_10G -d APP_TC_ARM" "%RTL%"
set "RCC=%errorlevel%"
call :run D "-d APP_TC_ARM" "%RTL%"
set "RCD=%errorlevel%"
call :run M1 "-d P7B_10G -d APP_TC_ARM" "%HERE%\tc_mut\mut_tc_off.v"
set "RCM1=%errorlevel%"
call :run M2 "-d P7B_10G -d APP_TC_ARM" "%HERE%\tc_mut\mut_bad_upd.v"
set "RCM2=%errorlevel%"
call :run M3 "-d P7B_10G -d APP_TC_ARM" "%HERE%\tc_mut\mut_noclear.v"
set "RCM3=%errorlevel%"

echo ==================== SUMMARY ====================
echo   A default            RC=%RCA%   (expect 0)
echo   B P7B_10G            RC=%RCB%   (expect 0)
echo   C P7B_10G+TCARM      RC=%RCC%   (expect 0)
echo   D TCARM (no P7B10G)  RC=%RCD%   (expect 0)
echo   M1 TAILC_OK=0        RC=%RCM1%  (expect nonzero)
echo   M2 bad-frame update  RC=%RCM2%  (expect nonzero)
echo   M3 no ev_up clear    RC=%RCM3%  (expect nonzero)

set "FAILS=0"
REM ---- mutant arms must have REALLY run (xs.log present AND containing [FAIL]) ----
set "MOK=1"
for %%A in (M1 M2 M3) do (
  if not exist "tcr%%A\xs.log" (echo   [FAIL] mutant %%A did not run: no xs.log & set "MOK=0")
  findstr /C:"[FAIL]" "tcr%%A\xs.log" > NUL
  if errorlevel 1 (echo   [FAIL] mutant %%A produced no [FAIL] line & set "MOK=0")
)
if "%MOK%"=="1" (echo   [PASS] mutant arms ran and produced in-TB [FAIL] reds) else (set /a FAILS+=1)
if not "%RCA%"=="0"  set /a FAILS+=1
if not "%RCB%"=="0"  set /a FAILS+=1
if not "%RCC%"=="0"  set /a FAILS+=1
if not "%RCD%"=="0"  set /a FAILS+=1
if "%RCM1%"=="0" set /a FAILS+=1
if "%RCM2%"=="0" set /a FAILS+=1
if "%RCM3%"=="0" set /a FAILS+=1

REM ---- 2) B vs C: finite-session instances byte-identical ----
set "EQ=1"
for %%F in (d0.hex d1.hex d2.hex f0.txt f1.txt f2.txt) do (
  fc /b "tcrB\%%F" "tcrC\%%F" > NUL
  if errorlevel 1 (echo   [DIFF] B-vs-C %%F & set "EQ=0")
)
if "%EQ%"=="1" (echo   [PASS] carry byte-equivalence: B vs C byte-identical on 6 finite-session files) else (echo   [FAIL] B vs C differ & set /a FAILS+=1)

REM ---- 3) A vs D: full byte-identical (param gate inert without P7B_10G) ----
set "EQ2=1"
for %%F in (d0.hex d1.hex d2.hex d3.hex d4.hex d5.hex d6.hex d7.hex d8.hex d9.hex f0.txt f1.txt f2.txt f3.txt f4.txt f5.txt f6.txt f7.txt f8.txt f9.txt stats.txt rate.txt) do (
  fc /b "tcrA\%%F" "tcrD\%%F" > NUL
  if errorlevel 1 (echo   [DIFF] A-vs-D %%F & set "EQ2=0")
)
if "%EQ2%"=="1" (echo   [PASS] param gate inert without P7B_10G: A vs D byte-identical on 22 files) else (echo   [FAIL] A vs D differ & set /a FAILS+=1)

REM ---- 5) compile-source witness (anti-vacuum-gate) ----
set "WOK=1"
for %%A in (A B C D) do (
  findstr /C:"app_pattern.v" "tcr%%A\srcpath.log" > NUL
  if errorlevel 1 (echo   [FAIL] arm %%A missing srcpath witness & set "WOK=0")
)
if "%WOK%"=="1" (echo   [PASS] compile-source witness: A/B/C/D all compile the LIVE rtl\app_pattern.v) else (set /a FAILS+=1)

echo   ---- key readings: RATE (u_cont idx4) ----
echo   [B] (A2, carry off):
findstr /C:"  RATE:" "tcrB\xs.log"
echo   [C] (A2, carry ON):
findstr /C:"  RATE:" "tcrC\xs.log"
echo   ---- counters (C arm): ----
findstr /C:"  FW :" /C:"  BP :" /C:"  NST:" "tcrC\xs.log"
echo   ---- TB verdicts ----
findstr /C:"TB_APP_TAILCARRY" "tcrA\xs.log"
findstr /C:"TB_APP_TAILCARRY" "tcrB\xs.log"
findstr /C:"TB_APP_TAILCARRY" "tcrC\xs.log"
findstr /C:"TB_APP_TAILCARRY" "tcrD\xs.log"
echo   ---- mutant reds (expect [FAIL] lines) ----
echo   [M1] TAILC_OK=0:
findstr /C:"[FAIL]" "tcrM1\xs.log"
echo   [M2] bad-frame carry update:
findstr /C:"[FAIL]" "tcrM2\xs.log"
echo   [M3] no carry clear on ev_up:
findstr /C:"[FAIL]" "tcrM3\xs.log"

if "%FAILS%"=="0" (echo TAILCARRY-GATE: PASS & exit /b 0)
echo TAILCARRY-GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:run
set "NAME=%~1"
set "DEFS=%~2"
set "RSRC=%~3"
if not exist "tcr%NAME%" mkdir "tcr%NAME%"
pushd "tcr%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
echo RSRC=%RSRC% > srcpath.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\tb\tb_app_tailcarry.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_app_tailcarry -s tb_tc -log xe.log > xe_out.log 2>&1 || (type xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb_tc -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_APP_TAILCARRY: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB FAIL detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"TB_APP_TAILCARRY" xs.log & popd & exit /b 1)
popd
exit /b 0
