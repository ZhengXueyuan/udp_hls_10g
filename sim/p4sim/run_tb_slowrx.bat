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

rem tb_slow_rx xsim 回归: 生成刺激 -> 编译 -> 三模式仿真 -> Python 比对
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %REPO_ROOT%\sim\p4sim
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_slowrx.py . > gen_sr.log 2>&1
if errorlevel 1 exit /b 1
rmdir /s /q xsim.dir 2>nul
del /q tb_slow_rx.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib ..\..\rtl\fifo_sync.v ..\..\rtl\frame_fifo.v ..\..\rtl\slow_rx_adp.v ..\..\tb\tb_slow_rx.v
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib "%VIV_BIN%\..\..\data\verilog\src\glbl.v"

call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L unisims_ver -L xil_defaultlib xil_defaultlib.tb_slow_rx xil_defaultlib.glbl -s tb_slow_rx

if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl -testplusarg STALL
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl -testplusarg HARD
if errorlevel 1 exit /b 1
call "%VIV_BIN%\xsim.bat" tb_slow_rx -tclbatch run.tcl -testplusarg WD
if errorlevel 1 exit /b 1
call C:\Users\zhxue\anaconda3\python.exe ..\..\tools\gen_stim_p4_slowrx.py . --check
exit /b %errorlevel%
