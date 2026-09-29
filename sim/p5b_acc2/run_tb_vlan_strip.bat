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

REM run_tb_vlan_strip.bat -- vlan_strip unit gate (xsim, self-checking TB)
REM   from Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\vlansim\run_tb_vlan_strip.bat'
REM   TB prints "VLAN_STRIP TB PASS" / "VLAN_STRIP TB FAIL" (exit code follows).
REM   NOTE: xvlog.bat writes its own xvlog.log -> redirect to a different name.
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call %XV%\xvlog.bat -work xil_defaultlib ^
  %REPO_ROOT%\rtl\vlan_strip.v ^
  %REPO_ROOT%\tb\tb_vlan_strip.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_vlan_strip -s tb_vlan_strip -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_vlan_strip -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)
findstr /C:"ERR" /C:"VLAN_STRIP TB" xsim_run.log
findstr /C:"VLAN_STRIP TB PASS" xsim_run.log >nul || exit /b 1
exit /b 0
