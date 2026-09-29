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

REM run_tb_p5b_ind.bat -- P5b 独立对抗单元门 (测试 agent 自建, 不复用实现者 TB)
REM 判据: 末行 "P5B IND OK" (失败则 "P5B IND FAIL n" + 逐项 FAIL 明细)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl

if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\app_ctrl.v ^
  tb_p5b_ind.v > xvlog_ind.log 2>&1 || (type xvlog_ind.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_p5b_ind -s tb_p5b_ind -log xelab_ind.log > NUL 2>&1 || (type xelab_ind.log & exit /b 1)
call %XV%\xsim.bat tb_p5b_ind -runall -log xsim_ind.log > NUL 2>&1

findstr /C:"FAIL" xsim_ind.log > NUL
if not errorlevel 1 (echo ---- FAIL DETAIL ---- & findstr /C:"FAIL" xsim_ind.log)

findstr /C:"P5B IND OK" xsim_ind.log > NUL
if errorlevel 1 (echo P5B INDEPENDENT GATE FAIL & exit /b 1)
echo P5B INDEPENDENT GATE PASS
