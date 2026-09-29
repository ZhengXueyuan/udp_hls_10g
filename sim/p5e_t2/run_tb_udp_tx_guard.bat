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

REM run_tb_udp_tx_guard.bat -- P5e-T2 UDP app TX unit gate (self-checking TB, no Python)
REM chain: app AXIS -> udp_tx_cfg (peer latch + enable gate) -> udp_tx_frame
REM        (PLEN_MAX length guard) -> tx_arb (reused as-is)
REM criteria: default-no-send, 1500 pass / 1501 abort / 4096 (>FIFO 2048B) abort with
REM            no lockup, cfg latch stable-in-frame & variable-between-frames,
REM            byte/checksum exactness, zero-length datagram, and a built-in
REM            NEGATIVE CONTROL (same 4096B frame on an unguarded instance
REM            = defparam PLEN_MAX=4095 must deadlock: payload FIFO full, no tlast).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\udp_tx_frame.v %RTL%\udp_tx_cfg.v ^
  %RTL%\tx_arb.v ^
  %TB%\tb_udp_tx_guard.v > xvlog_g.log 2>&1 || (type xvlog_g.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_udp_tx_guard -s tb_udp_tx_guard -log xelab_g.log > NUL 2>&1 || (type xelab_g.log & exit /b 1)
call %XV%\xsim.bat tb_udp_tx_guard -runall -log xsim_g.log > NUL 2>&1 || (type xsim_g.log & exit /b 1)

findstr /C:"P5E-T2 GUARD GATE: OK" xsim_g.log > NUL
if errorlevel 1 (echo ---- FAIL detail: & findstr /C:"FAIL" xsim_g.log & exit /b 1)
findstr /C:"P5E-T2 GUARD GATE" xsim_g.log
exit /b 0
