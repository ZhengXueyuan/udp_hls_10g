@echo off
setlocal
REM =====================================================================
REM run_app8_gate.bat -- P7B app 8-byte/cycle gate (self-locating, ASCII only)
REM   A = default build  (old byte-serial RTL, no P7B_10G)
REM   B = -d P7B_10G     (new 8-byte/cycle RTL)
REM   C = negctl M1      (M^8 degraded to M   -> MUST go red)
REM   D = negctl M2      (RX compares lane0 only -> MUST go red)
REM Criteria:
REM   1) A vs B: all 14 dump files (7 configs x {bytes,frames}) byte-identical
REM   2) A/B testbench self-checks all OK (loopback / injected RX / PLEN_MAX ...)
REM   3) C: dump differs (red)  AND  TB fails (red)
REM   4) D: dump identical (TX untouched) BUT TB fails (RX lane coverage lost)
REM exit 0 only when every expectation above holds.
REM NOTE: never redirect into a name the tool itself uses (xvlog.log / xelab.log
REM       / xsim.log) -- cmd holds the handle and the tool then fails to open it.
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate repo root from %~f0
  echo   derived ROOT = %ROOT%
  exit /b 1
)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "PY=C:\Users\zhxue\anaconda3\python.exe"
set "RTL=%ROOT%\rtl"
cd /d "%HERE%"

if not exist "%PY%" (echo [FAIL] python not found: %PY% & exit /b 1)
if not exist "%RTL%\app_udp_pattern.v" (echo [FAIL] RTL missing & exit /b 1)
"%PY%" make_negctl.py > negctl_gen.log 2>&1 || (type negctl_gen.log & echo NEGCTL-GEN-FAIL & exit /b 1)

call :run A "%RTL%\app_udp_pattern.v" ""
set "RCA=%errorlevel%"
call :run B "%RTL%\app_udp_pattern.v" "-d P7B_10G"
set "RCB=%errorlevel%"
call :run C "%HERE%\negctl\app_udp_pattern_m1.v" "-d P7B_10G"
set "RCC=%errorlevel%"
call :run D "%HERE%\negctl\app_udp_pattern_m2.v" "-d P7B_10G"
set "RCD=%errorlevel%"

echo ==================== SUMMARY ====================
echo   A default      RC=%RCA%   (expect 0)
echo   B P7B_10G      RC=%RCB%   (expect 0)
echo   C M8-to-M       RC=%RCC%   (expect nonzero: must go red)
echo   D lane0-only   RC=%RCD%   (expect nonzero: must go red)

set "FAILS=0"
if not "%RCA%"=="0" set /a FAILS+=1
if not "%RCB%"=="0" set /a FAILS+=1
if "%RCC%"=="0" set /a FAILS+=1
if "%RCD%"=="0" set /a FAILS+=1

set "EQ=1"
for %%T in (T0 T1 T2 T3 T4 T5 T6) do (
  fc /b "runA\dump_%%T.hex" "runB\dump_%%T.hex" > NUL
  if errorlevel 1 (echo   [DIFF] %%T.hex & set "EQ=0")
  fc /b "runA\dump_%%T.frm" "runB\dump_%%T.frm" > NUL
  if errorlevel 1 (echo   [DIFF] %%T.frm & set "EQ=0")
)
if "%EQ%"=="1" (echo   [PASS] byte-equivalence: A vs B identical on 14 dump files) else (echo   [FAIL] A vs B differ & set /a FAILS+=1)

set "CRED=0"
fc /b "runA\dump_T0.hex" "runC\dump_T0.hex" > NUL
if errorlevel 1 set "CRED=1"
fc /b "runA\dump_T1.hex" "runC\dump_T1.hex" > NUL
if errorlevel 1 set "CRED=1"
if "%CRED%"=="1" (echo   [PASS] negctl-C red: dump differs from A) else (echo   [FAIL] negctl-C NOT red & set /a FAILS+=1)

set "DGRN=1"
fc /b "runA\dump_T0.hex" "runD\dump_T0.hex" > NUL
if errorlevel 1 set "DGRN=0"
fc /b "runA\dump_T6.frm" "runD\dump_T6.frm" > NUL
if errorlevel 1 set "DGRN=0"
if "%DGRN%"=="1" (echo   [PASS] negctl-D: TX dump unchanged - mutation is RX-only) else (echo   [FAIL] negctl-D touched TX & set /a FAILS+=1)

echo   ---- key readings ----
findstr /C:"T0: txf" /C:"L0: txb" /C:"L1: txb" /C:"R0: rxb" /C:"R1: rxb" "runB\xs.log"
echo   ---- negctl-C reds ----
findstr /C:"[FAIL]" "runC\xs.log"
echo   ---- negctl-D reds ----
findstr /C:"[FAIL]" "runD\xs.log"

if "%FAILS%"=="0" (echo APP8-GATE: PASS & exit /b 0)
echo APP8-GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "%RTL%\fifo_sync.v" "%HERE%\tb_app8_equiv.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_app8_equiv -s tb8 -log xe.log > xe_out.log 2>&1 || (type xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb8 -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_APP8_EQUIV: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB FAIL detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"TB_APP8_EQUIV" xs.log & popd & exit /b 1)
findstr /C:"TB_APP8_EQUIV" xs.log
popd
exit /b 0
