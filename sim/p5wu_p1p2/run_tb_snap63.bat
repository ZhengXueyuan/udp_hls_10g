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

REM run_tb_snap63.bat -- P7B-WU snapshot window (63 words) readback gate
REM   tb/tb_snap63.v = copy of _proj_10g/notes/p7b_biz_win/tb_biz_win.v (NW=61) with
REM   NW 61->63 and BUILD_ID 8->9 only; criteria are NW-parameterised (unchanged).
REM   covers: word<->address 1:1 for W0..W62, last word 0x118, unimplemented 0x11C == SLVERR,
REM           0x200 wrap red line, 0x108/0x118 aliasing (SCRATCH / SNAP_CTRL) negative tests.
REM criteria: per-item PASS/FAIL + last line "PASS_ALL  tb_snap63: ..." (else FAIL)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set PCIE=%REPO_ROOT%\_proj_pcie\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5wu_p1p2\runsnap

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %PCIE%\axi_regs.v ^
  %TB%\tb_snap63.v > xvlog_snap63.log 2>&1 || (type xvlog_snap63.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_snap63 -s tb_snap63 -log xelab_snap63.log > NUL 2>&1 || (type xelab_snap63.log & exit /b 1)
REM ---- pitfall 24 (implicit net / port-width silent truncation): only xelab/synth can catch it
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_snap63.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_snap63.log & exit /b 1)

call %XV%\xsim.bat tb_snap63 -runall -log xsim_snap63.log > NUL 2>&1 || (type xsim_snap63.log & exit /b 1)

type xsim_snap63.log
findstr /C:"PASS_ALL  tb_snap63" xsim_snap63.log > NUL
if errorlevel 1 (echo SNAP63 GATE FAIL & exit /b 1)
echo SNAP63 GATE PASS
