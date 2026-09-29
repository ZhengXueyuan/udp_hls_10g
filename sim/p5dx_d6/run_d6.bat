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

REM P5d-D6: exp2 slot-leak TB (verbatim copy of sim/p5dx/exp2/tb_hls_slotleak.v)
REM run against the CANONICAL HLS netlist hls\slowstack_prj\solution1\syn\verilog.
REM Own dir keeps xsim.dir locks out of sim/p5dx/exp2 (other agents).
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog
set TB=%REPO_ROOT%\sim\p5dx_d6

if not exist "%HLS%\udp_echo.v" (echo HLS netlist missing & exit /b 1)
dir /b /s %HLS%\*.v > hls_files.f
copy /y %HLS%\*.dat %TB%\ >NUL

%PY% %TB%\gen_frames.py %TB% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib %TB%\tb_hls_slotleak.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_hls_slotleak xil_defaultlib.glbl -s tb_hls_slotleak -log xelab_d6.log > NUL 2>&1 || (type xelab_d6.log & exit /b 1)
call %XV%\xsim.bat tb_hls_slotleak -runall -log xsim_d6.log > NUL 2>&1 || (type xsim_d6.log & exit /b 1)

%PY% %TB%\check_exp2.py %TB%
exit /b %ERRORLEVEL%
