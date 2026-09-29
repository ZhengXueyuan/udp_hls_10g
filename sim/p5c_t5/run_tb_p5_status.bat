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

REM run_tb_p5_status.bat -- app_status_uart unit gate (P5a Step 6)
REM decodes the 136-char status line from txd and compares it with the expected
REM string (gen_stim_p5_app.py checkstatus)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set BD=%REPO_ROOT%\board
set TOOL=%REPO_ROOT%\tools
set SIM=%REPO_ROOT%\sim\p5c_t5\g_status

if exist status_line.txt del /q status_line.txt

call %XV%\xvlog.bat -work xil_defaultlib_a ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
  %TB%\tb_p5_status.v > xvlog_st.log 2>&1 || (type xvlog_st.log & exit /b 1)

call %XV%\xelab.bat xil_defaultlib_a.tb_p5_status -s tb_p5_status -log xelab_st.log > NUL 2>&1 || (type xelab_st.log & exit /b 1)
call %XV%\xsim.bat tb_p5_status -runall -log xsim_st.log > NUL 2>&1 || (type xsim_st.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_app.py %SIM% checkstatus
