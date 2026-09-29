@echo off
REM run_tb_frame_fifo.bat [frame_fifo_source.v] -- frame_fifo unit test (two-stage:
REM stage1 = sim\retxsim2\frame_fifo_old.v (reg-array RTL), stage2 = rtl\frame_fifo.v (BRAM).
REM Usage: run_tb_frame_fifo.bat <path-to-frame_fifo.v>
cd /d %~dp0
call "%~dp0..\p4gates\p4env.bat" || exit /b 1
if not "%P4_WORKDIR%"=="" cd /d "%P4_WORKDIR%"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --path "%CD%" --quiet || exit /b 1
if "%~1"=="" (echo ERROR: pass frame_fifo source as %%1 & exit /b 1)
set SRC=%~f1
set "TBF=%REPO_ROOT%\tb\tb_frame_fifo.v"
echo == TB stage: %SRC% ==
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GATES%\fifo_src.f" --path "%CD%" --path "%SRC%" --quiet || exit /b 1
call %XV%\xvlog.bat -work xil_defaultlib "%SRC%" "%TBF%" > xvlog_ff.log 2>&1 || (type xvlog_ff.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_ff.log 2>&1 || (type xvlog_ff.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_frame_fifo xil_defaultlib.glbl -s tb_frame_fifo -log xelab_ff.log > NUL 2>&1 || (type xelab_ff.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ff.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_ff.log & exit /b 1)
call %XV%\xsim.bat tb_frame_fifo -runall -log xsim_ff.log > NUL 2>&1
type xsim_ff.log
