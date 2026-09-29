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

rem udp_tx_frame 全链 xsim 回归: csum_en=1 与 CSUM0 两模式
rem 用法: cmd //c D:\repo\ECO\udp_hls_10g\sim\txsim\run_tb_udp_tx.bat
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %REPO_ROOT%\sim\txsim
rmdir /s /q xsim.dir 2>nul
del /q tb_udp_tx.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\rtl\checksum16.v ..\..\rtl\mac_tx_64.v ..\..\rtl\udp_tx_frame.v ..\..\tb\tb_udp_tx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_udp_tx -s tb_udp_tx
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_tx -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_udp_tx -tclbatch run.tcl -testplusarg CSUM0
if errorlevel 1 exit /b 1
