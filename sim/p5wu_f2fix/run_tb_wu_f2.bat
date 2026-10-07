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

REM run_tb_wu_f2.bat -- P7b-WU 2nd round F2 gate (winq==0 explicit no-fire)
REM   2 arms, same stimulus / same gnt / same waveform:
REM     u_dut = rtl/app_ctrl.v worktree (F2 fixed)
REM     u_pre = sim/p5wu_f2fix/app_ctrl_prefix.v = pre-F2 worktree file, module renamed only
REM              (sha256 prefix 83d318f9 renamed / 871eab12 unrenamed) => "F2 unfixed" arm
REM   criteria: per-item PASS/FAIL in the TB + hard count "F2 GATE PASSCOUNT 38"
REM             + last line "F2 GATE OK" / "F2 GATE FAIL n"
REM dedicated work dir sim\p5wu_f2fix\run (leftover xsim procs holding xsim.dir cause false failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5wu_f2fix\run

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\app_ctrl.v ^
  %REPO_ROOT%\sim\p5wu_f2fix\app_ctrl_prefix.v ^
  %REPO_ROOT%\sim\p5wu_f2fix\app_ctrl_mut.v ^
  %TB%\tb_wu_f2.v > xvlog_f2.log 2>&1 || (type xvlog_f2.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_wu_f2 -s tb_wu_f2 -log xelab_f2.log > NUL 2>&1 || (type xelab_f2.log & exit /b 1)
REM ---- pitfall 24 (implicit net / port-width silent truncation): only xelab/synth can catch it
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_f2.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_f2.log & exit /b 1)

call %XV%\xsim.bat tb_wu_f2 -runall -log xsim_f2.log > NUL 2>&1 || (type xsim_f2.log & exit /b 1)

type xsim_f2.log
findstr /C:"F2 GATE PASSCOUNT 38" xsim_f2.log > NUL
if errorlevel 1 (echo F2 PASSCOUNT MISMATCH & exit /b 1)
findstr /C:"F2 GATE OK" xsim_f2.log > NUL
if errorlevel 1 (echo F2 GATE FAIL & exit /b 1)
echo F2 GATE PASS
