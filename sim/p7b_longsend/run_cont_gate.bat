@echo off
setlocal
REM =====================================================================
REM run_cont_gate.bat -- P7B-LONGSEND / TX_CONTINUOUS gate (self-locating)
REM   A = default (no macro)                    expect RC 0
REM   B = -d APP_CONT_ARM                       expect RC 0
REM   C = -d P7B_10G -d APP_CONT_ARM            expect RC 0
REM   G = FROZEN anchor file (= A3 修复**之前**), no macro
REM       expect RC != 0 AND the reds are EXACTLY the A13a/A13b pair
REM       (2026-10-10 build E: A3 = **unconditional behaviour fix**; the frozen anchor
REM        is therefore a *negative control for A3*, not an equivalence anchor)
REM   M1..M5 = mutants under APP_CONT_ARM       expect RC != 0
REM Criteria:
REM   1) A/B/C RC 0; G RC != 0 (with exactly the A13a/A13b reds -- see criterion 2b)
REM   2) A vs G: (a) the **19 unaffected files** still byte-identical (fc /b);
REM      (b) the delta must be EXACTLY {d7.hex d8.hex f7.txt f8.txt} (they must DIFFER)
REM          + stats.txt identical after dropping its I7/I8 lines.
REM      原判据 = "24 files byte-identical" = 等价锚 (设计件 §4.3) -- 已不成立 (见上)。
REM   3) zero arm: z_zero_c.txt vs z_zero_d.txt byte-identical (every arm) = A10
REM   4) M1..M4 RC != 0 (M2 无判别力时如实登记)
REM   5) compile-source witness: A/B/C must compile <ROOT>\rtl\app_pattern.v (live);
REM      G must compile the frozen snapshot (NOT the live rtl/)
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
set "TB=%ROOT%\tb\tb_app_cont.v"
set "FRZ=%ROOT%\sim\p7b_stagec_tx_regress\frozen\app_pattern_rev0e804099.v"
cd /d "%HERE%"

if not exist "%PY%" (echo [FAIL] python not found: %PY% & exit /b 1)
if not exist "%RTL%\app_pattern.v" (echo [FAIL] RTL missing & exit /b 1)
if not exist "%TB%" (echo [FAIL] TB missing & exit /b 1)
if not exist "%FRZ%" (echo [FAIL] frozen anchor missing & exit /b 1)
"%PY%" mk_mut_cont.py > mutgen.log 2>&1 || (type mutgen.log & echo MUTGEN-FAIL & exit /b 1)

call :run A "%RTL%\app_pattern.v" ""
set "RCA=%errorlevel%"
call :run B "%RTL%\app_pattern.v" "-d APP_CONT_ARM"
set "RCB=%errorlevel%"
call :run C "%RTL%\app_pattern.v" "-d P7B_10G -d APP_CONT_ARM"
set "RCC=%errorlevel%"
call :run G "%FRZ%" ""
set "RCG=%errorlevel%"
call :run M1 "%HERE%\mut\m1_cont_off.v" "-d APP_CONT_ARM"
set "RCM1=%errorlevel%"
call :run M2 "%HERE%\mut\m2_no_reload_txok.v" "-d APP_CONT_ARM"
set "RCM2=%errorlevel%"
call :run M3 "%HERE%\mut\m3_miss_frmwait.v" "-d APP_CONT_ARM"
set "RCM3=%errorlevel%"
call :run M4 "%HERE%\mut\m4_term_open.v" "-d APP_CONT_ARM"
set "RCM4=%errorlevel%"
call :run M5 "%HERE%\mut\m5_no_uppend.v" "-d APP_CONT_ARM"
set "RCM5=%errorlevel%"

echo ==================== SUMMARY ====================
echo   A default          RC=%RCA%   (expect 0)
echo   B APP_CONT_ARM     RC=%RCB%   (expect 0)
echo   C P7B_10G+CONT     RC=%RCC%   (expect 0)
echo   G frozen anchor    RC=%RCG%   (expect nonzero: pre-A3 anchor)
echo   M1 CONT_OK=0        RC=%RCM1%  (expect nonzero)
echo   M2 no-txok-reload  RC=%RCM2%  (expect nonzero; 无判别力则如实登记)
echo   M3 miss-frmwait     RC=%RCM3%  (expect nonzero)
echo   M4 term-open        RC=%RCM4%  (expect nonzero)
echo   M5 no-uppend (A3)   RC=%RCM5%  (expect nonzero; build E)

set "FAILS=0"
if not "%RCA%"=="0"  set /a FAILS+=1
if not "%RCB%"=="0"  set /a FAILS+=1
if not "%RCC%"=="0"  set /a FAILS+=1
if "%RCM1%"=="0" set /a FAILS+=1
if "%RCM2%"=="0" set /a FAILS+=1
if "%RCM3%"=="0" set /a FAILS+=1
if "%RCM4%"=="0" set /a FAILS+=1
if "%RCM5%"=="0" set /a FAILS+=1

REM ---- 2a) A vs G: **19 个未受影响的文件**逐字节相同 ----
REM   (排除 d7/d8/f7/f8 = u_rec1/u_rec2 两臂 + stats.txt 的 I7/I8 两行; 见下 2b)
set "EQ=1"
for %%F in (d0.hex d1.hex d2.hex d3.hex d4.hex d5.hex d6.hex d9.hex f0.txt f1.txt f2.txt f3.txt f4.txt f5.txt f6.txt f9.txt rate.txt z_zero_c.txt z_zero_d.txt) do (
  fc /b "runA\%%F" "runG\%%F" > NUL
  if errorlevel 1 (echo   [DIFF] %%F & set "EQ=0")
)
if "%EQ%"=="1" (echo   [PASS] equivalence anchor: A vs G byte-identical on the 19 unaffected files) else (echo   [FAIL] A vs G differ on a file A3 does NOT explain & set /a FAILS+=1)

REM ---- 2b) A3 登记差异必须**恰好** ----
set "A3OK=1"
for %%F in (d7.hex d8.hex f7.txt f8.txt) do (
  fc /b "runA\%%F" "runG\%%F" > NUL
  if not errorlevel 1 (echo   [DIFF-MISSING] %%F: A == G -- the registered A3 delta vanished? & set "A3OK=0")
)
findstr /V /C:"I7 " /C:"I8 " "runA\stats.txt" > a_stats_norec.txt
findstr /V /C:"I7 " /C:"I8 " "runG\stats.txt" > g_stats_norec.txt
fc /b "a_stats_norec.txt" "g_stats_norec.txt" > NUL
if errorlevel 1 (echo   [DIFF] stats.txt (I7/I8 之外的行) & set "A3OK=0")
if "%A3OK%"=="1" (echo   [PASS] A3 delta exactly as registered: d7 d8 f7 f8 + stats I7/I8) else (echo   [FAIL] A3 delta is not exactly as registered & set /a FAILS+=1)

REM ---- 2c) 冻结锚的红必须恰好是 A13a/A13b 两条 ----
if "%RCG%"=="0"  set /a FAILS+=1
findstr /C:"[FAIL]" "runG\xs.log" > g_reds.txt
set /a GNF=0
for /f %%C in (g_reds.txt) do set /a GNF+=1
if "%GNF%"=="2" (echo   [PASS] arm G reds == 2) else (echo   [FAIL] arm G reds=%GNF% -- expect exactly 2 & set /a FAILS+=1)
findstr /C:"A13a" /C:"A13b" "runG\xs.log" > NUL
if errorlevel 1 (echo   [FAIL] arm G: the reds are NOT the A13a/A13b pair & set /a FAILS+=1) else (echo   [PASS] arm G: reds are the A13a/A13b pair)

REM ---- 3) zero arm: z_zero_c vs z_zero_d (每臂都查) ----
set "ZOK=1"
for %%A in (A B C G) do (
  fc /b "run%%A\z_zero_c.txt" "run%%A\z_zero_d.txt" > NUL
  if errorlevel 1 (echo   [DIFF] arm %%A zero-arm dumps differ & set "ZOK=0")
)
if "%ZOK%"=="1" (echo   [PASS] A10 zero arm: z_zero_c == z_zero_d on A/B/C/G) else (set /a FAILS+=1)

REM ---- 5) 编译源见证 (防真空门: 门到底编了哪份 RTL) ----
set "WOK=1"
for %%A in (A B C) do (
  findstr /C:"%RTL%\app_pattern.v" "run%%A\srcpath.log" > NUL
  if errorlevel 1 (echo   [FAIL] arm %%A did not compile the LIVE rtl/app_pattern.v & set "WOK=0")
)
findstr /C:"frozen\app_pattern_rev0e804099.v" "runG\srcpath.log" > NUL
if errorlevel 1 (echo   [FAIL] arm G did not compile the frozen anchor & set "WOK=0")
if "%WOK%"=="1" (echo   [PASS] compile-source witness: A/B/C live rtl, G frozen anchor) else (set /a FAILS+=1)

echo   ---- key readings (runB = APP_CONT_ARM) ----
findstr /C:"  I" /C:"  REC:" /C:"  RATE:" /C:"  TOK:" "runB\xs.log"
echo   ---- mutant reds ----
echo   [M1] CONT_OK=0:
findstr /C:"[FAIL]" "runM1\xs.log"
echo   [M2] no-txok-reload:
findstr /C:"[FAIL]" "runM2\xs.log"
echo   [M3] miss-frmwait:
findstr /C:"[FAIL]" "runM3\xs.log"
echo   [M4] term-open:
findstr /C:"[FAIL]" "runM4\xs.log"
echo   [M5] no-uppend (A3):
findstr /C:"[FAIL]" "runM5\xs.log"

if "%FAILS%"=="0" (echo CONT-GATE: PASS & exit /b 0)
echo CONT-GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
echo RSRC=%RSRC% > srcpath.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\tb\tb_app_cont.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_app_cont -s tbcont -log xe.log > xe_out.log 2>&1 || (type xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tbcont -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_APP_CONT: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB FAIL detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"TB_APP_CONT" xs.log & popd & exit /b 1)
findstr /C:"TB_APP_CONT" xs.log
popd
exit /b 0
