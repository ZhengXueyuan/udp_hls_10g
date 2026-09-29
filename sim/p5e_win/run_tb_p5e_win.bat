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
REM p5e_win -- P5e "0 payload opener" narrow-window gate
REM   DUT: app_pattern -> axis_pipe -> tcp_tx_frame (APP_MODE unit level).
REM   Judges the on-wire TCP payload bytes only: after a DEL + re-ADD
REM   (new session, new ISN) every payload byte must equal the pattern at
REM   its seq offset from the new ISN (zero cross-session leakage), and
REM   each session must run to TX_BYTES.
REM   Scenario 1: the narrow window with the real DEL->ADD spacing (70 cyc):
REM               ev_up lands while the app is still in W3 closing.
REM   Scenario 2: ev_up collides with the W3 closing delivery (framer already
REM               ready one cycle before) -- the uncounted word must not leak.
REM   Negative control: sim\p5e_win\neg\<neg>\ (mkneg.py punches the opener
REM   out of a COPY of rtl\) must FAIL the same gate.
REM Usage: cmd //c "D:\repo\ECO\udp_hls_10g\sim\p5e_win\run_tb_p5e_win.bat"
REM Exit : 0 = GATE PASS, 1 = GATE FAIL, 2 = tool error / no verdict
REM NOTE: ASCII only (UTF-8 comments in a .bat get re-paired as GBK and eat
REM       the CR -- the comment line is then run as a command).
REM ============================================================
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set T5=%REPO_ROOT%\sim\p5e_win
cd /d %T5%
rmdir /s /q xsim.dir 2>nul
del /q tb_p5e_win.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib -d APP_MODE %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_tx_frame.v %RTL%\axis_pipe.v %RTL%\app_pattern.v %T5%\tb_p5e_win.v > xvlog_p5e.log 2>&1
if errorlevel 1 (type xvlog_p5e.log & exit /b 2)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_p5e_win -s tb_p5e_win -log xelab_p5e.log
if errorlevel 1 (type xelab_p5e.log & exit /b 2)
call "%VIV_BIN%\xsim.bat" tb_p5e_win -runall -log xsim_p5e.log
if errorlevel 1 (type xsim_p5e.log & exit /b 2)
findstr /c:"GATE tb_p5e_win: PASS" xsim_p5e.log >nul
if not errorlevel 1 (echo P5E-WIN GATE PASS & exit /b 0)
findstr /c:"GATE tb_p5e_win: FAIL" xsim_p5e.log >nul
if not errorlevel 1 (echo P5E-WIN GATE FAIL & findstr /c:"FAIL" xsim_p5e.log & exit /b 1)
echo no verdict line in xsim_p5e.log & type xsim_p5e.log & exit /b 2
