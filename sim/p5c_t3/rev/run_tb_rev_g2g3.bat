@echo off
set "REPO_ROOT=%~dp0..\..\..\."
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
REM p5c_t3/rev -- INDEPENDENT REVIEW TB for P5c-T3 (G2 timeout / G3 fence)
REM   Topology: real tcb + app_ctrl + tcp_tx_frame, wrapper-style TCB arbiter.
REM   R1 timeout with natural fc grant: is an RST ever sent?
REM   R2 fc stalled with an in-flight window write for the same slot:
REM      is the state=0 write request (st_pend) lost?
REM   R3 two simultaneous timeout CONN_DOWN events.
REM   R4 external ev_down must not be mixed up with the timeout event.
REM   R5 same-slot reconnect after a timeout must not inherit state.
REM Exit : 0 = all checks pass, 1 = check failures, 2 = tool error
REM NOTE: ASCII only on purpose (UTF-8 comments in a .bat get re-paired as
REM       GBK and eat the CR -- the comment line is then run as a command).
REM ============================================================
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set REV=%REPO_ROOT%\sim\p5c_t3\rev
cd /d %REV%
rmdir /s /q xsim.dir 2>nul
del /q tb_rev_g2g3.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcb.v %RTL%\app_ctrl.v %RTL%\tcp_tx_frame.v %REV%\tb_rev_g2g3.v > xvlog_rev.log 2>&1
if errorlevel 1 (type xvlog_rev.log & exit /b 2)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_rev_g2g3 -s tb_rev_g2g3 -log xelab_rev.log
if errorlevel 1 (type xelab_rev.log & exit /b 2)
call "%VIV_BIN%\xsim.bat" tb_rev_g2g3 -runall -log xsim_rev.log
if errorlevel 1 (type xsim_rev.log & exit /b 2)
findstr /c:"GATE tb_rev_g2g3: PASS" xsim_rev.log >nul
if not errorlevel 1 (echo P5C-T3 REV TB: ALL CHECKS PASS & exit /b 0)
findstr /c:"GATE tb_rev_g2g3: FAIL" xsim_rev.log >nul
if not errorlevel 1 (echo P5C-T3 REV TB: CHECK FAILURES & findstr /c:"FAIL" xsim_rev.log & exit /b 1)
echo no verdict line in xsim_rev.log & type xsim_rev.log & exit /b 2
