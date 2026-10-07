@echo off
setlocal enabledelayedexpansion
REM =====================================================================
REM run_a2_gate.bat -- Stage C / A2 (app_pattern TX 1 cycle/word) gate
REM   A = default build (no P7B_10G)               expect RC 0, 1828 cyc/frame
REM   B = -d P7B_10G  (A2)                         expect RC 0,  190 cyc/frame
REM   C = negctl m1 (sent_a without lookahead)     expect RC != 0
REM   D = negctl m2 (frame close on lookahead)     expect RC != 0
REM   E = negctl m3 (M^8 -> M^1 in whole-word load)expect RC != 0
REM   F = negctl m4 (no asm_go relaxation = A1)    expect RC != 0 BUT exactly
REM       2 reds = both cycles/frame judges, and every dump identical to A
REM       => the cycles/frame judge has teeth (bytes same, timing red).
REM   G = negctl m5 (fill/load sized by non-lookahead need)  expect RC != 0
REM Criteria:
REM   1) A/B: 29 dump/stats files byte-identical (fc /b)
REM   2) A/B: TB self-checks all OK (RC 0); cycles/frame judge lives in the TB
REM   3) C/D/E/G: RC != 0 AND its file set differs from A (real behaviour change)
REM   4) F: file set == A + exactly 2 reds, both cycles/frame lines
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
set "PY=C:\Users\zhxue\anaconda3\python.exe"
set "RTL=%ROOT%\rtl"
set "TB=%ROOT%\tb\tb_app_a2_equiv.v"
set "FLIST=d0.hex d1.hex d2.hex d3.hex d4.hex d5.hex d6.hex d7.hex d8.hex d9.hex d10.hex d11.hex d12.hex d13.hex f0.txt f1.txt f2.txt f3.txt f4.txt f5.txt f6.txt f7.txt f8.txt f9.txt f10.txt f11.txt f12.txt f13.txt stats.txt"
cd /d "%HERE%"

if not exist "%PY%" (echo [FAIL] python not found: %PY% & exit /b 1)
if not exist "%RTL%\app_pattern.v" (echo [FAIL] RTL missing & exit /b 1)
if not exist "%TB%" (echo [FAIL] TB missing & exit /b 1)
"%PY%" gen_negctl_a2.py > negctl_gen.log 2>&1 || (type negctl_gen.log & echo NEGCTL-GEN-FAIL & exit /b 1)
type negctl_gen.log

call :run A "%RTL%\app_pattern.v" ""
set "RCA=%errorlevel%"
call :run B "%RTL%\app_pattern.v" "-d P7B_10G"
set "RCB=%errorlevel%"
call :run C "%HERE%\negctl\app_pattern_m1.v" "-d P7B_10G"
set "RCC=%errorlevel%"
call :run D "%HERE%\negctl\app_pattern_m2.v" "-d P7B_10G"
set "RCD=%errorlevel%"
call :run E "%HERE%\negctl\app_pattern_m3.v" "-d P7B_10G"
set "RCE=%errorlevel%"
call :run F "%HERE%\negctl\app_pattern_m4.v" "-d P7B_10G"
set "RCF=%errorlevel%"
call :run G "%HERE%\negctl\app_pattern_m5.v" "-d P7B_10G"
set "RCG=%errorlevel%"

echo ==================== SUMMARY ====================
echo   A default            RC=%RCA%   expect 0
echo   B P7B_10G A2         RC=%RCB%   expect 0
echo   C m1 no-lookahead    RC=%RCC%   expect nonzero
echo   D m2 close-on-look   RC=%RCD%   expect nonzero
echo   E m3 M8-to-M         RC=%RCE%   expect nonzero
echo   F m4 A1-style        RC=%RCF%   expect nonzero, ONLY reds = 2 cycles/frame
echo   G m5 need-not-look   RC=%RCG%   expect nonzero

set "FAILS=0"
if not "%RCA%"=="0" set /a FAILS+=1
if not "%RCB%"=="0" set /a FAILS+=1
if "%RCC%"=="0" set /a FAILS+=1
if "%RCD%"=="0" set /a FAILS+=1
if "%RCE%"=="0" set /a FAILS+=1
if "%RCF%"=="0" set /a FAILS+=1
if "%RCG%"=="0" set /a FAILS+=1

REM ---- 1) A vs B: 29 files byte-identical ----
set "EQ=1"
for %%F in (%FLIST%) do (
  fc /b "runA\%%F" "runB\%%F" > NUL
  if errorlevel 1 (echo   [DIFF] %%F & set "EQ=0")
)
if "!EQ!"=="1" (echo   [PASS] byte-equivalence: A vs B identical on 29 dump/stats files) else (echo   [FAIL] A vs B differ & set /a FAILS+=1)

REM ---- 3) C/D/E/G: file set must differ from A (real behaviour change) ----
for %%M in (C D E G) do (
  set "DD=0"
  for %%F in (%FLIST%) do (
    fc /b "runA\%%F" "run%%M\%%F" > NUL
    if errorlevel 1 set "DD=1"
  )
  if "!DD!"=="1" (echo   [PASS] run%%M differs from A on at least 1 file) else (echo   [FAIL] run%%M is a null mutant -- identical to A & set /a FAILS+=1)
)

REM ---- 4) F: file set == A, exactly 2 reds, both are the cycles/frame judges ----
set "FF=0"
for %%F in (%FLIST%) do (
  fc /b "runA\%%F" "runF\%%F" > NUL
  if errorlevel 1 set "FF=1"
)
if "!FF!"=="0" (echo   [PASS] runF byte-identical to A on all 29 files -- A1 keeps the byte stream) else (echo   [FAIL] runF dumps differ from A & set /a FAILS+=1)
findstr /C:"[FAIL]" "runF\xs.log" > f_reds.txt
set /a FNF=0
for /f %%C in (f_reds.txt) do set /a FNF+=1
if "%FNF%"=="2" (echo   [PASS] runF exactly 2 reds) else (echo   [FAIL] runF reds=%FNF% -- expect exactly 2 & set /a FAILS+=1)
set /a FCR=0
findstr /C:"[FAIL] cycles/frame" "runF\xs.log" > f_cr.txt
for /f %%C in (f_cr.txt) do set /a FCR+=1
if "%FCR%"=="2" (echo   [PASS] runF both reds are the cycles/frame judges) else (echo   [FAIL] runF cycles/frame reds=%FCR% -- expect 2 & set /a FAILS+=1)

echo   ---- key readings (runB = P7B_10G / A2) ----
findstr /C:"TX0:" /C:"BAD:" /C:"BP :" /C:"EVD:" /C:"EVR:" /C:"TOK:" /C:"RATE:" "runB\xs.log"
findstr /C:"seg=" "runB\xs.log"
echo   ---- cycles/frame readings (A = default, then B = A2) ----
type runA\rate.txt
type runB\rate.txt

echo   ---- negative-control reds (per-byte noise filtered) ----
echo   [C] m1 no-lookahead:
call :reds C
echo   [D] m2 close-on-lookahead:
call :reds D
echo   [E] m3 M8-to-M:
call :reds E
echo   [F] m4 no-relaxation A1:
call :reds F
echo   [G] m5 fill/load on non-lookahead need:
call :reds G

if "%FAILS%"=="0" (echo A2-GATE: PASS & exit /b 0)
echo A2-GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:reds
set /a NR=0
findstr /C:"[FAIL]" "run%~1\xs.log" > r_all.txt
for /f %%C in (r_all.txt) do set /a NR+=1
echo     total reds = %NR%
findstr /C:"[FAIL]" "run%~1\xs.log" | findstr /V /C:"pattern mismatch" | findstr /V /C:"hold violation" | findstr /V /C:"bad-frame byte" > r_chk.txt
for /f "tokens=* delims=" %%L in (r_chk.txt) do echo     %%L
exit /b 0

REM =====================================================================
:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\tb\tb_app_a2_equiv.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_app_a2_equiv -s tba2 -log xe.log > xe_out.log 2>&1 || (type xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tba2 -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_APP_A2_EQUIV: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB FAIL detail [%NAME%] chk-style reds: & findstr /C:"[FAIL]" xs.log | findstr /V /C:"pattern mismatch" | findstr /V /C:"hold violation" | findstr /V /C:"bad-frame byte" & findstr /C:"TB_APP_A2_EQUIV" xs.log & popd & exit /b 1)
findstr /C:"TB_APP_A2_EQUIV" xs.log
popd
exit /b 0
