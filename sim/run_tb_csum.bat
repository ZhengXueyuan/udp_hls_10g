@echo off
set "REPO_ROOT=%~dp0..\."
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

rem 用法: run_tb_csum.bat   (工作目录必须为本 sim 目录)
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %REPO_ROOT%\sim
rmdir /s /q xsim.dir 2>nul
del /q tb_snap.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\rtl\checksum16.v ..\tb\tb_checksum16.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_checksum16 -s tb_snap
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_snap -tclbatch run.tcl
