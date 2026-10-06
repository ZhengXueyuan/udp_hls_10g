@echo on
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

REM run_tb_app_wu.bat -- P7b-WU gate: same-stimulus A/B for app_ctrl C6 (window reopen notify wu)
REM   both arms driven at the same time by identical stimulus / identical gnt:
REM     u_new = app_ctrl (default params, after fix) / u_old = app_ctrl #(.WU_LEGACY(1)) (before fix)
REM   main criteria: in the field modality (window held at 56..128, never exactly 0) NEW must fire / OLD 0 times;
REM           in the designed condition (occ>=winq => wscan==0) both arms fire once (both arms alive).
REM criteria: per-item PASS/FAIL inside the TB + last line "P7B WU GATE OK" / "P7B WU GATE FAIL n"
REM dedicated work dir sim\p5wu\run (project rule: leftover xsim procs holding xsim.dir cause false gate failures)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5wu\run

if not exist "%SIM%" mkdir "%SIM%"
echo PROBE-END
