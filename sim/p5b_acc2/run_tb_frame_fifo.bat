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

REM run_tb_frame_fifo.bat [frame_fifo_source.v] -- frame_fifo unit test (two-stage:
REM stage1 = sim\retxsim2\frame_fifo_old.v (reg-array RTL), stage2 = rtl\frame_fifo.v (BRAM).
REM Usage: run_tb_frame_fifo.bat <path-to-frame_fifo.v>
cd /d %~dp0
if "%~1"=="" (echo ERROR: pass frame_fifo source as %%1 & exit /b 1)
set SRC=%~f1
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set TB=%REPO_ROOT%\tb\tb_frame_fifo.v
echo == TB stage: %SRC% ==
call %XV%\xvlog.bat -work xil_defaultlib "%SRC%" "%TB%" > xvlog_ff.log 2>&1 || (type xvlog_ff.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ff.log 2>&1 || (type xvlog_ff.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_frame_fifo xil_defaultlib.glbl -s tb_frame_fifo -log xelab_ff.log > NUL 2>&1 || (type xelab_ff.log & exit /b 1)
call %XV%\xsim.bat tb_frame_fifo -runall -log xsim_ff.log > NUL 2>&1
type xsim_ff.log
