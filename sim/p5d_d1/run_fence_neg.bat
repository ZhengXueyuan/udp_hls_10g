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

REM run_fence_neg.bat -- counterfactual: run the READ-ONLY P5c-T3 fence TB
REM (sim\p5c_t3\tb_p5c_fence.v, never modified) against the P5d-D1
REM NEGATIVE RTL copy (rst_req term removed from tx_blk) to prove that the F5
REM failure of the canonical fence gate is caused by exactly that one term.
REM ASCII only. Exit: 0 = fence PASS, 1 = fence FAIL, 2 = tool error.
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\sim\p5d_d1neg\neg_rst\rtl
set T3=%REPO_ROOT%\sim\p5c_t3
set D1=%REPO_ROOT%\sim\p5d_d1\fenceneg
cd /d %D1%
rmdir /s /q xsim.dir 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_tx_frame.v %T3%\tb_p5c_fence.v > xvlog_fn.log 2>&1
if errorlevel 1 (type xvlog_fn.log & exit /b 2)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_p5c_fence -s tb_p5c_fence -log xelab_fn.log > NUL 2>&1
if errorlevel 1 (type xelab_fn.log & exit /b 2)
call "%VIV_BIN%\xsim.bat" tb_p5c_fence -runall -log xsim_fn.log > NUL 2>&1
if errorlevel 1 (type xsim_fn.log & exit /b 2)
findstr /c:"GATE tb_p5c_fence: PASS" xsim_fn.log >nul
if not errorlevel 1 (echo FENCE-NEG PASS & exit /b 0)
echo FENCE-NEG FAIL & findstr /c:"FAIL" xsim_fn.log & exit /b 1
