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

REM run_tb_udp_split.bat -- P5e-T1 udp_split unit gate (tb_udp_split.v)
REM Self-checking: last line "P5 UDP SPLIT UNIT OK" / "... FAIL n".
REM Own xsim.dir here (project rule 7: never share xsim.dir across gates).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\frame_fifo.v ^
  %RTL%\udp_rx.v ^
  %RTL%\udp_split.v ^
  %TB%\tb_udp_split.v > xvlog_split.log 2>&1 || (type xvlog_split.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_split.log 2>&1 || (type xvlog_split.log & exit /b 1)

REM frame_fifo instantiates RAMB36E1 -> -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_udp_split xil_defaultlib.glbl -s tb_udp_split -log xelab_split.log > NUL 2>&1 || (type xelab_split.log & exit /b 1)
call %XV%\xsim.bat tb_udp_split -runall -log xsim_split.log > NUL 2>&1 || (type xsim_split.log & exit /b 1)

findstr /C:"P5 UDP SPLIT UNIT OK" xsim_split.log > NUL
if errorlevel 1 (findstr /C:"P5US " xsim_split.log & findstr /C:"FAIL" xsim_split.log & exit /b 1)
findstr /C:"P5US " xsim_split.log
echo P5 UDP SPLIT UNIT GATE PASS
