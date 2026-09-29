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

REM ============================================================
REM p5c_t3 -- P5c-T3 G3 directed gate: TX fence after abort
REM   Unit level (tcp_tx_frame only). Judges the AXIS frame stream only:
REM   F1 baseline data frame (byte exact) / F2 rst_req -> RST frame 0x14
REM   F3 after RST the same slot cannot start a frame (tready stays 0)
REM   F4 another slot still works (per-slot blacklist, not a global block)
REM   F5 cfg_up clears rst_sent_r -> frame resumes, payload byte exact
REM      (same-gate proof: a wider accept gate would have swallowed words)
REM Usage: cmd //c "D:\repo\ECO\udp_hls_10g\sim\p5c_t3\run_tb_p5c_fence.bat"
REM Exit : 0 = GATE PASS, 1 = GATE FAIL, 2 = tool error / no verdict
REM NOTE: ASCII only on purpose (UTF-8 comments in a .bat get re-paired as
REM       GBK and eat the CR -- the comment line is then run as a command).
REM ============================================================
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set T3=%REPO_ROOT%\sim\p5c_t3
cd /d %T3%
rmdir /s /q xsim.dir 2>nul
del /q tb_p5c_fence.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_tx_frame.v %T3%\tb_p5c_fence.v > xvlog_fence.log 2>&1
if errorlevel 1 (type xvlog_fence.log & exit /b 2)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_p5c_fence -s tb_p5c_fence -log xelab_fence.log
if errorlevel 1 (type xelab_fence.log & exit /b 2)
call "%VIV_BIN%\xsim.bat" tb_p5c_fence -runall -log xsim_fence.log
if errorlevel 1 (type xsim_fence.log & exit /b 2)
findstr /c:"GATE tb_p5c_fence: PASS" xsim_fence.log >nul
if not errorlevel 1 (echo P5C-T3 FENCE GATE PASS & exit /b 0)
findstr /c:"GATE tb_p5c_fence: FAIL" xsim_fence.log >nul
if not errorlevel 1 (echo P5C-T3 FENCE GATE FAIL & findstr /c:"FAIL" xsim_fence.log & exit /b 1)
echo no verdict line in xsim_fence.log & type xsim_fence.log & exit /b 2
