@echo off
setlocal
REM =====================================================================
REM run_rx8_gate.bat -- Stage B / R1 (TCP app RX 8-way) gate (self-locating)
REM   A = default build (no P7B_10G)            expect RC 0
REM   B = -d P7B_10G  (RX 8-way)                expect RC 0
REM   C = negctl M1 (xs_next8 -> xs_next)       expect RC != 0
REM   D = negctl M2 (only lane0 compared)       expect RC != 0
REM   E = negctl M3 (tail fallback removed)     expect RC != 0
REM Criteria:
REM   1) A/B: 7 dump/stats files byte-identical (fc /b)
REM   2) A/B: TB self-checks all OK (RC 0)
REM   3) C/D/E: RC != 0 AND their TX dump identical to A (mutants are RX-scoped)
REM   4) python oracle (check_rx8.py runB) RC == 0
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
set "TB=%ROOT%\tb\tb_app_rx8_equiv.v"
cd /d "%HERE%"

if not exist "%PY%" (echo [FAIL] python not found: %PY% & exit /b 1)
if not exist "%RTL%\app_pattern.v" (echo [FAIL] RTL missing & exit /b 1)
if not exist "%TB%" (echo [FAIL] TB missing & exit /b 1)
"%PY%" make_negctl_rx8.py > negctl_gen.log 2>&1 || (type negctl_gen.log & echo NEGCTL-GEN-FAIL & exit /b 1)

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

echo ==================== SUMMARY ====================
echo   A default        RC=%RCA%   (expect 0)
echo   B P7B_10G        RC=%RCB%   (expect 0)
echo   C M8-to-M         RC=%RCC%   (expect nonzero)
echo   D lane0-only      RC=%RCD%   (expect nonzero)
echo   E no-tail-fallback RC=%RCE%  (expect nonzero)
echo   F no-ev-up-yield  RC=%RCF%   (expect nonzero; only the EV judge may go red)

set "FAILS=0"
if not "%RCA%"=="0" set /a FAILS+=1
if not "%RCB%"=="0" set /a FAILS+=1
if "%RCC%"=="0" set /a FAILS+=1
if "%RCD%"=="0" set /a FAILS+=1
if "%RCE%"=="0" set /a FAILS+=1
if "%RCF%"=="0" set /a FAILS+=1

set "EQ=1"
for %%F in (dump_tx.hex dump_tx.frm acc_w0.txt acc_w1.txt acc_w2.txt acc_w3.txt acc_w4.txt stats.txt) do (
  fc /b "runA\%%F" "runB\%%F" > NUL
  if errorlevel 1 (echo   [DIFF] %%F & set "EQ=0")
)
if "%EQ%"=="1" (echo   [PASS] byte-equivalence: A vs B identical on 8 dump/stats files) else (echo   [FAIL] A vs B differ & set /a FAILS+=1)

set "MOK=1"
for %%M in (C D E F) do (
  fc /b "runA\dump_tx.hex" "run%%M\dump_tx.hex" > NUL
  if errorlevel 1 (echo   [DIFF] run%%M TX dump touched: mutant is not RX-scoped & set "MOK=0")
  fc /b "runA\dump_tx.frm" "run%%M\dump_tx.frm" > NUL
  if errorlevel 1 (echo   [DIFF] run%%M TX frm touched & set "MOK=0")
)
if "%MOK%"=="1" (echo   [PASS] mutants are RX-scoped: TX dump identical to A on all 4) else (set /a FAILS+=1)

REM ---- F 的判别力: 必须**恰好一条红, 且就是 EV 判据** (ev_up 让位硬化有牙) ----
REM 注: 不用 `... ^| find /c /v ""` 计数 (在本机 cmd 里会挂住), 改成直读临时文件逐行计数。
findstr /C:"[FAIL]" "runF\xs.log" > f_reds.txt
set /a FNF=0
for /f %%C in (f_reds.txt) do set /a FNF+=1
if "%FNF%"=="1" (echo   [PASS] negctl-F: exactly 1 red) else (echo   [FAIL] negctl-F reds=%FNF% (expect exactly 1) & set /a FAILS+=1)
findstr /C:"[FAIL] EV zero mismatch" "runF\xs.log" > NUL
if errorlevel 1 (echo   [FAIL] negctl-F: the red is NOT the EV judge & set /a FAILS+=1) else (echo   [PASS] negctl-F: the red is the EV judge)

"%PY%" check_rx8.py runB > oracle_out.txt 2>&1
if errorlevel 1 (echo   [FAIL] python oracle vs runB & type oracle_out.txt & set /a FAILS+=1) else (echo   [PASS] python oracle agrees with runB)

echo   ---- key readings (runB = P7B_10G) ----
findstr /C:"TX :" /C:"RX0:" /C:"RX1:" /C:"I0 :" /C:"I1 :" /C:"EV :" /C:"RATE:" "runB\xs.log"
echo   ---- negative-control reds ----
echo   [C] M8-to-M:
findstr /C:"[FAIL]" "runC\xs.log"
echo   [D] lane0-only:
findstr /C:"[FAIL]" "runD\xs.log"
echo   [E] no-tail-fallback:
findstr /C:"[FAIL]" "runE\xs.log"
echo   [F] no-ev-up-yield (only the EV judge should be red):
findstr /C:"[FAIL]" "runF\xs.log"

if "%FAILS%"=="0" (echo RX8-GATE: PASS & exit /b 0)
echo RX8-GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\tb\tb_app_rx8_equiv.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_app_rx8_equiv -s tb8rx -log xe.log > xe_out.log 2>&1 || (type xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb8rx -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_APP_RX8_EQUIV: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB FAIL detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"TB_APP_RX8_EQUIV" xs.log & popd & exit /b 1)
findstr /C:"TB_APP_RX8_EQUIV" xs.log
popd
exit /b 0
