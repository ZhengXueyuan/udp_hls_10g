@echo off
set "REPO_ROOT=%~dp0..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)
rem --- pathguard tripwire: refuse to run if a LIVE line points outside ---
set "P4PY=C:\Users\zhxue\anaconda3\python.exe"
if exist "%P4PY%" goto :pg_py_ok
set "P4PY="
for %%P in (python.exe) do if not defined P4PY set "P4PY=%%~$PATH:P"
:pg_py_ok
if not defined P4PY goto :pg_sc_done
if not exist "%REPO_ROOT%\sim\p4gates\p4gate.py" goto :pg_sc_done
"%P4PY%" "%REPO_ROOT%\sim\p4gates\p4gate.py" selfcheck --root "%REPO_ROOT%" --bat "%~f0" --quiet || exit /b 1
:pg_sc_done

REM run_tb_wu_p1p2.bat -- P7b-WU 2nd round gate: P1 (arm-threshold floor) + P2 (activity gate)
REM   3 arms, same stimulus / same gnt / same waveform:
REM     u_dut  = rtl/app_ctrl.v worktree (fixed)
REM     u_base = sim/p5wu_p1p2/app_ctrl_base.v = git HEAD 95c9485 file, module renamed only
REM              (sha256 prefix c38b3b96) => the real "P1/P2 unfixed" negative-control arm
REM     u_leg  = app_ctrl #(.WU_LEGACY(1)) => pre-2026-10-07 first-round-fix logic
REM   criteria: per-item PASS/FAIL in the TB + last line "P1P2 GATE OK" / "P1P2 GATE FAIL n"
REM dedicated work dir sim\p5wu_p1p2\run (leftover xsim procs holding xsim.dir cause false failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5wu_p1p2\run

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\app_ctrl.v ^
  %REPO_ROOT%\sim\p5wu_p1p2\app_ctrl_base.v ^
  %TB%\tb_wu_p1p2.v > xvlog_p1p2.log 2>&1 || (type xvlog_p1p2.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_wu_p1p2 -s tb_wu_p1p2 -log xelab_p1p2.log > NUL 2>&1 || (type xelab_p1p2.log & exit /b 1)
REM ---- pitfall 24 (implicit net / port-width silent truncation): only xelab/synth can catch it
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p1p2.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p1p2.log & exit /b 1)

call %XV%\xsim.bat tb_wu_p1p2 -runall -log xsim_p1p2.log > NUL 2>&1 || (type xsim_p1p2.log & exit /b 1)

type xsim_p1p2.log
findstr /C:"P1P2 GATE OK" xsim_p1p2.log > NUL
if errorlevel 1 (echo P1P2 GATE FAIL & exit /b 1)
echo P1P2 GATE PASS
