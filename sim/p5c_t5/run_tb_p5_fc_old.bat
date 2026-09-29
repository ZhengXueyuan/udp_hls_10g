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

REM run_tb_p5_fc_old.bat -- NEGATIVE CONTROL: old criterion (no activity term)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5c_t5\oldrun

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib %RTL%\fifo_sync.v app_ctrl_old.v %TB%\tb_app_fc.v > xvlog_old.log 2>&1 || (type xvlog_old.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_app_fc -s tb_app_fc -log xelab_old.log > xelab_old_out.log 2>&1 || (type xelab_old.log & exit /b 1)
call %XV%\xsim.bat tb_app_fc -runall -log xsim_old.log > xsim_old_out.log 2>&1 || (type xsim_old.log & exit /b 1)
echo --- OLD RTL RESULT (expect FAIL) ---
findstr /C:"FC UNIT" xsim_old.log
findstr /C:"FC UNIT FAIL" xsim_old.log > nul && (echo OLD_RTL_FAILS_AS_EXPECTED & exit /b 0)
echo OLD_RTL_UNEXPECTEDLY_OK
