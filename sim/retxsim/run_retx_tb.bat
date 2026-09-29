@echo off
REM run_retx_tb.bat -- P4b-7-P1: retx_ram unit testbench
REM   usage (Git Bash): cmd //c '%REPO_ROOT%\sim\retxsim\run_retx_tb.bat'
REM   compiles rtl/retx_ram.v + tb/tb_retx_ram.v, runs xsim, prints xsim.log
cd /d %~dp0
call "%~dp0..\p4gates\p4env.bat" || exit /b 1
if not "%P4_WORKDIR%"=="" cd /d "%P4_WORKDIR%"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --path "%CD%" --quiet || exit /b 1

"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GATES%\retx_src.f" --path "%CD%" --quiet || exit /b 1
call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\retx_ram.v ^
  %TB%\tb_retx_ram.v > xvlog_c.log 2>&1 || (type xvlog_c.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_retx_ram -s tb_retx_ram -log xelab.log > NUL 2>&1 || (type xelab.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab.log & exit /b 1)

call %XV%\xsim.bat tb_retx_ram -runall -log xsim.log > NUL 2>&1

type xsim.log
