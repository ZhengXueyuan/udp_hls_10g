@echo off
setlocal
REM =====================================================================
REM run_evphase.bat -- 对抗审查反例门: ev_up 的**相位** (握手拍 vs 握手后第 4 拍)
REM   A = 默认构建 (无 P7B_10G), B = -d P7B_10G
REM 期望 (判据, 反了就是 FAIL):
REM   acc_ctrl.txt : A == B   (控制组: ev_up 压在握手拍 ⇒ 两条路径同行为)
REM   stats.txt    : A != B   (相位组: 默认构建复位被撞掉 / P7B_10G 复位生效)
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] cannot locate repo root & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl\app_pattern.v"
set "TB=%HERE%\tb_rx8_evphase_review.v"
cd /d "%HERE%"

if not exist "%RTL%" (echo [FAIL] RTL missing & exit /b 1)
if not exist "%TB%" (echo [FAIL] TB missing & exit /b 1)

call :run A "%RTL%" ""
if errorlevel 1 (echo EVPHASE-RUN-FAIL A & exit /b 1)
call :run B "%RTL%" "-d P7B_10G"
if errorlevel 1 (echo EVPHASE-RUN-FAIL B & exit /b 1)

echo ==================== EVPHASE SUMMARY ====================
set "FAILS=0"
fc /b "runA\acc_ctrl.txt" "runB\acc_ctrl.txt" > NUL
if errorlevel 1 (echo   [FAIL] control drift: acc_ctrl.txt differs (A vs B) & set /a FAILS+=1) else (echo   [PASS] control: acc_ctrl.txt identical A vs B)
fc /b "runA\acc_mid.txt" "runB\acc_mid.txt" > NUL
if errorlevel 1 (echo   [info] acc_mid.txt differs A vs B) else (echo   [info] acc_mid.txt identical A vs B)
fc /b "runA\stats.txt" "runB\stats.txt" > NUL
if errorlevel 1 (echo   [PASS] phase hole reproduced: stats.txt differs A vs B) else (echo   [FAIL] no divergence found (hole NOT reproduced) & set /a FAILS+=1)

echo   ---- runA (default build) ----
findstr /C:"EVID" /C:"CTRL " /C:"MID " "runA\xs.log"
echo   ---- runB (P7B_10G) ----
findstr /C:"EVID" /C:"CTRL " /C:"MID " "runB\xs.log"
echo   ---- stats.txt (A then B) ----
type "runA\stats.txt"
echo   ----
type "runB\stats.txt"

if "%FAILS%"=="0" (echo EVPHASE-GATE: PASS & exit /b 0)
echo EVPHASE-GATE: FAIL count=%FAILS%
exit /b 1

:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "%TB%" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_rx8_evphase_review -s evph -log xe.log > xe_out.log 2>&1 || (type xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT [%NAME%]: & findstr /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"undeclared symbol" xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" evph -runall -log xs.log > xs_out.log 2>&1
findstr /C:"EVPHRASE DONE" xs.log > NUL
if errorlevel 1 (echo ---- TB INCOMPLETE [%NAME%]: & type xs_out.log & popd & exit /b 1)
popd
exit /b 0
