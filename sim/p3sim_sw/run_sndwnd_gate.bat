@echo off
setlocal
REM =====================================================================
REM run_sndwnd_gate.bat -- P7B-SNDWND-GUARD gate (self-locating)
REM   ARM A (FIXED):  -                DUT SNDWND_GUARD=1  expect: legs A/B green
REM   ARM B (LEGACY): -d SNDWND_LEGACY DUT SNDWND_GUARD=0  expect: leg A XFAIL
REM                    (XFAIL = defect reproduced; leg B must STILL be green)
REM   ARM M (MUTANT): fixed arm TB compiled against mut\mut_acckadv.v
REM                    (guard predicate deliberately wrong: ack_adv_l) expect:
REM                    [FAIL] SNDWND LEGB1 with passd=1 (frame accepted, window
REM                    update blocked) AND leg A still PASS => leg B has teeth.
REM   ARM D (DROPA) : fixed arm TB, stim generated with SW_LEGDROP_A=1 (leg A
REM                    frames pushed out of window => dropped, no fend) expect:
REM                    [FAIL] SNDWND LEGA with passd=0 (accept witness fires)
REM                    => the load-bearing "frame accepted + fend" assertion has
REM                    teeth (a value-only criterion would degrade silently).
REM Criteria:
REM   1) each arm: xvlog/xelab clean (incl. implicit-wire keys), 3 modes run
REM   2) FIXED : "SNDWND ALL PASS" in all 3 mode logs; no "[FAIL] SNDWND" anywhere;
REM              python model check (arm=fixed) OK on nostall,stall
REM   3) LEGACY: "SNDWND LEGACY OK" in all 3 mode logs; python check (arm=legacy)
REM              OK on nostall,stall
REM   4) MUTANT: "[FAIL] SNDWND LEGB1" (+ passd=1 on the same line) in all 3 logs;
REM              "SNDWND ALL PASS" absent; "SNDWND LEGA PASS" present
REM   5) hard-mode divergence: recorded known pre-existing red (identical at HEAD
REM      139d7b71, verified by a clean HEAD-copy run) -- the exact LINE-63 signature
REM      must still be present, otherwise this gate FAILS loudly (either somebody
REM      fixed it => update this gate, or a new divergence appeared => investigate)
REM   6) arm-mismatch negative control (model): running "check fixed" against the
REM      LEGACY arm's resp files MUST mismatch (proves the arm mirror is load-bearing)
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
set "GEN=%ROOT%\tools\gen_stim_tcp_rx.py"
set "RTL=%ROOT%\rtl\tcp_rx.v"
set "TB=%ROOT%\tb\tb_tcp_rx.v"
cd /d "%HERE%"

if not exist "%GEN%" (echo [FAIL] generator missing: %GEN% & exit /b 1)
if not exist "%RTL%" (echo [FAIL] RTL missing: %RTL% & exit /b 1)
if not exist "%TB%"  (echo [FAIL] TB missing: %TB% & exit /b 1)
if not exist "%PY%"  (echo [FAIL] python not found: %PY% & exit /b 1)

REM ---- mutant generation (anchored + counted; stale anchor => hard fail) ----
"%PY%" "mut\mk_mut_acckadv.py" "%ROOT%" > mut\mutgen.log 2>&1
if errorlevel 1 (type mut\mutgen.log & echo MUTGEN-FAIL & exit /b 1)
type mut\mutgen.log

call :run FIXED  runA_fixed  ""               "%RTL%"        fixed
set "RCA=%errorlevel%"
call :run LEGACY runB_legacy "-d SNDWND_LEGACY" "%RTL%"      legacy
set "RCB=%errorlevel%"
call :run MUT    runM_mut   ""                "%HERE%\mut\mut_acckadv.v" fixed
set "RCM=%errorlevel%"
set "SW_LEGDROP_A=1"
call :run DROP   runD_drop  ""                "%RTL%"        fixed
set "RCD=%errorlevel%"
set "SW_LEGDROP_A="

echo ==================== SUMMARY ====================
echo   A FIXED  runA_fixed  RC=%RCA%   (expect 0)
echo   B LEGACY runB_legacy RC=%RCB%  (expect 0)
echo   M MUTANT runM_mut   RC=%RCM%   (expect 0: mechanism OK, verdicts as designed)
echo   D DROPA  runD_drop  RC=%RCD%   (expect 0: mechanism OK, leg A red as designed)

set "FAILS=0"
REM ---- 1) mechanical: check RCs and mode logs present ----
if not "%RCA%"=="0" set /a FAILS+=1
if not "%RCB%"=="0" set /a FAILS+=1
if not "%RCM%"=="0" set /a FAILS+=1
if not "%RCD%"=="0" set /a FAILS+=1
for %%A in (runA_fixed runB_legacy runM_mut runD_drop) do (
  for %%M in (xs1 xs2 xs3 chk_ns chk_h) do (
    if not exist "%%A\%%M.log" (echo   [FAIL] %%A\%%M.log missing & set /a FAILS+=1)
  )
)

REM ---- 2) FIXED arm verdicts (all 3 modes) ----
set "OK=1"
for %%M in (xs1 xs2 xs3) do (
  findstr /C:"SNDWND ALL PASS" "runA_fixed\%%M.log" > NUL
  if errorlevel 1 (echo   [FAIL] FIXED %%M: no "SNDWND ALL PASS" & set "OK=0")
  findstr /C:"[FAIL] SNDWND" "runA_fixed\%%M.log" > NUL
  if not errorlevel 1 (echo   [FAIL] FIXED %%M: has [FAIL] SNDWND line & set "OK=0")
)
if "%OK%"=="1" (echo   [PASS] FIXED arm: SNDWND ALL PASS in xs1/xs2/xs3, zero [FAIL] SNDWND) else (set /a FAILS+=1)
findstr /C:"MISMATCH" "runA_fixed\chk_ns.log" > NUL
if not errorlevel 1 (echo   [FAIL] FIXED model check reports MISMATCH & set /a FAILS+=1)
findstr /C:" OK" "runA_fixed\chk_ns.log" > NUL
if errorlevel 1 (echo   [FAIL] FIXED model check: no OK verdict line & set /a FAILS+=1)
type runA_fixed\chk_ns.log

REM ---- 3) LEGACY arm verdicts (all 3 modes) ----
set "OK=1"
for %%M in (xs1 xs2 xs3) do (
  findstr /C:"SNDWND LEGACY OK" "runB_legacy\%%M.log" > NUL
  if errorlevel 1 (echo   [FAIL] LEGACY %%M: no "SNDWND LEGACY OK" & set "OK=0")
  findstr /C:"SNDWND LEGA XFAIL-REPRODUCED" "runB_legacy\%%M.log" > NUL
  if errorlevel 1 (echo   [FAIL] LEGACY %%M: no XFAIL-REPRODUCED marker & set "OK=0")
)
if "%OK%"=="1" (echo   [PASS] LEGACY arm: legA XFAIL-REPRODUCED + LEGACY OK in xs1/xs2/xs3) else (set /a FAILS+=1)
findstr /C:"MISMATCH" "runB_legacy\chk_ns.log" > NUL
if not errorlevel 1 (echo   [FAIL] LEGACY model check reports MISMATCH & set /a FAILS+=1)
findstr /C:" OK" "runB_legacy\chk_ns.log" > NUL
if errorlevel 1 (echo   [FAIL] LEGACY model check: no OK verdict line & set /a FAILS+=1)
type runB_legacy\chk_ns.log

REM ---- 4) MUTANT arm (negative control: leg B must be red, and only leg B) ----
set "OK=1"
for %%M in (xs1 xs2 xs3) do (
  findstr /C:"[FAIL] SNDWND LEGB1" "runM_mut\%%M.log" | findstr /C:"passd=1" > NUL
  if errorlevel 1 (echo   [FAIL] MUTANT %%M: no "[FAIL] SNDWND LEGB1 ... passd=1" line & set "OK=0")
  findstr /C:"SNDWND ALL PASS" "runM_mut\%%M.log" > NUL
  if not errorlevel 1 (echo   [FAIL] MUTANT %%M: mutant must NOT be all-green & set "OK=0")
  findstr /C:"SNDWND LEGA PASS" "runM_mut\%%M.log" > NUL
  if errorlevel 1 (echo   [FAIL] MUTANT %%M: legA should stay PASS under mutant & set "OK=0")
)
if "%OK%"=="1" (echo   [PASS] MUTANT arm: LEGB1 red with accept witness, legA green -- leg B has teeth) else (set /a FAILS+=1)
findstr /C:"[FAIL] SNDWND" "runM_mut\xs1.log"

REM ---- 4b) DROP arm (accept-witness teeth): leg A frames forced out-of-window =>
REM          dropped, no fend => the "frame accepted" assertion MUST go red ----
set "OK=1"
for %%M in (xs1 xs2 xs3) do (
  findstr /C:"[FAIL] SNDWND LEGA" "runD_drop\%%M.log" | findstr /C:"passd=0" > NUL
  if errorlevel 1 (echo   [FAIL] DROP %%M: no "[FAIL] SNDWND LEGA ... passd=0" line & set "OK=0")
  findstr /C:"SNDWND LEGB1 PASS" "runD_drop\%%M.log" > NUL
  if errorlevel 1 (echo   [FAIL] DROP %%M: legB1 should stay PASS & set "OK=0")
  findstr /C:"SNDWND ALL PASS" "runD_drop\%%M.log" > NUL
  if not errorlevel 1 (echo   [FAIL] DROP %%M: drop arm must NOT be all-green & set "OK=0")
)
if "%OK%"=="1" (echo   [PASS] DROP arm: LEGA red with passd=0 -- accept witness has teeth) else (set /a FAILS+=1)
findstr /C:"[FAIL] SNDWND LEGA" "runD_drop\xs1.log"

REM ---- 5) hard-mode known pre-existing divergence: signature must be UNCHANGED ----
findstr /C:"hard LINE 63: exp 'META 0A000001 D431 0014 1 00000000' resp 'FEND 1'" "runA_fixed\chk_h.log" > NUL
if errorlevel 1 (
  echo   [FAIL] hard-mode divergence signature changed/absent -- the known pre-existing
  echo          red was: hard LINE 63: exp 'META ...' resp 'FEND 1', identical at
  echo          HEAD 139d7b71. If it is FIXED now, update this gate; else investigate.
  set /a FAILS+=1
) else (
  echo   [PASS] hard-mode: known pre-existing divergence signature unchanged, LINE 63
)

REM ---- 6) arm-mismatch negative control (model arm mirror is load-bearing) ----
"%PY%" "%GEN%" runB_legacy check fixed nostall > runB_legacy\chk_mismatch.log 2>&1
if errorlevel 1 (
  findstr /C:"MISMATCH" "runB_legacy\chk_mismatch.log" > NUL
  if errorlevel 1 (echo   [FAIL] arm-mismatch control: check failed w/o MISMATCH line & set /a FAILS+=1) else (echo   [PASS] arm-mismatch negative control: check fixed vs LEGACY resp reported MISMATCH)
) else (
  echo   [FAIL] arm-mismatch negative control: check fixed PASSED on legacy output & set /a FAILS+=1
)

echo ---- key readings ----
for %%A in (runA_fixed runB_legacy runM_mut runD_drop) do (
  echo   [%%A xs1]
  findstr /C:"SNDWND ARM=" /C:"SNDWND LEGA" /C:"SNDWND LEGB1" /C:"SNDWND LEGB2" /C:"SNDWND ALL PASS" /C:"SNDWND LEGACY OK" /C:"P4b7 DIRECTED" "%%A\xs1.log"
)

if "%FAILS%"=="0" (echo SNDWND-GATE: PASS & exit /b 0)
echo SNDWND-GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:run
set "NAME=%~1"
set "WD=%~2"
set "DEFS=%~3"
set "RSRC=%~4"
set "CARM=%~5"
if not exist "%WD%" mkdir "%WD%"
pushd "%WD%"
if exist xsim.dir rmdir /s /q xsim.dir
echo run all > run.tcl
echo quit >> run.tcl
echo RSRC=%RSRC% DEFS=%DEFS% > srcpath.log
"%PY%" "%GEN%" . > gen.log 2>&1
if errorlevel 1 (type gen.log & popd & echo GEN-FAIL [%NAME%] & exit /b 1)
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%ROOT%\rtl\crc32_8b.v" "%ROOT%\rtl\fifo_sync.v" "%ROOT%\rtl\mac_rx_64.v" "%ROOT%\rtl\tcp_cam.v" "%ROOT%\rtl\tcb.v" "%RSRC%" "%TB%" > xv.log 2>&1
if errorlevel 1 (type xv.log & popd & echo XVLOG-FAIL [%NAME%] & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv.log > NUL
if not errorlevel 1 (type xv.log & popd & echo XVLOG-ERROR [%NAME%] & exit /b 1)
call "%XV%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_tcp_rx -s tb_tcp_rx -log xe.log > xe_out.log 2>&1
if errorlevel 1 (type xe_out.log & popd & echo XELAB-FAIL [%NAME%] & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb_tcp_rx -tclbatch run.tcl > xs1.log 2>&1
call "%XV%\xsim.bat" tb_tcp_rx -tclbatch run.tcl -testplusarg STALL > xs2.log 2>&1
call "%XV%\xsim.bat" tb_tcp_rx -tclbatch run.tcl -testplusarg HARD > xs3.log 2>&1
for %%M in (xs1 xs2 xs3) do (
  findstr /C:"SNDWND ARM=" "%%M.log" > NUL
  if errorlevel 1 (echo XSIM-NORUN [%NAME% %%M%]: no SNDWND banner & popd & exit /b 1)
)
"%PY%" "%GEN%" . check %CARM% nostall,stall > chk_ns.log 2>&1
set "CNS=%errorlevel%"
"%PY%" "%GEN%" . check %CARM% hard > chk_h.log 2>&1
set "CH=%errorlevel%"
popd
if not "%CNS%"=="0" (echo MODEL-CHECK-FAIL [%NAME%] nostall/stall & exit /b 1)
if "%CH%"=="0" (echo NOTE [%NAME%]: hard-mode check now PASSES -- divergence gone/updated & exit /b 0)
exit /b 0
