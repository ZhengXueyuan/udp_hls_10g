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

REM run_tb_p5_pattern.bat -- app_pattern TX AXIS contract unit gate (P5a review W3)
REM ev_down mid-frame must close the frame (tlast) and never drop tvalid without tlast
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5sim

call %XV%\xvlog.bat -work xil_defaultlib_p ^
  %RTL%\app_pattern.v ^
  %TB%\tb_p5_pattern.v > xvlog_p.log 2>&1 || (type xvlog_p.log & exit /b 1)

call %XV%\xelab.bat xil_defaultlib_p.tb_p5_pattern -s tb_p5_pattern -log xelab_p.log > NUL 2>&1 || (type xelab_p.log & exit /b 1)
call %XV%\xsim.bat tb_p5_pattern -runall -log xsim_p.log > NUL 2>&1 || (type xsim_p.log & exit /b 1)

findstr /C:"P5 PATTERN" xsim_p.log
findstr /C:"W3 case" xsim_p.log
