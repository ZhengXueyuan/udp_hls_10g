@echo off
REM run_tb_vlan_strip.bat -- vlan_strip unit gate (xsim, self-checking TB)
REM   from Git Bash: cmd //c '%REPO_ROOT%\sim\vlansim\run_tb_vlan_strip.bat'
REM   TB prints "VLAN_STRIP TB PASS" / "VLAN_STRIP TB FAIL" (exit code follows).
REM   NOTE: xvlog.bat writes its own xvlog.log -> redirect to a different name.
cd /d %~dp0
call "%~dp0..\p4gates\p4env.bat" || exit /b 1
if not "%P4_WORKDIR%"=="" cd /d "%P4_WORKDIR%"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --path "%CD%" --quiet || exit /b 1
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GATES%\vlan_src.f" --path "%CD%" --quiet || exit /b 1
call %XV%\xvlog.bat -work xil_defaultlib ^
  %REPO_ROOT%\rtl\vlan_strip.v ^
  %REPO_ROOT%\tb\tb_vlan_strip.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_vlan_strip -s tb_vlan_strip -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_vlan_strip -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)
findstr /C:"ERR" /C:"VLAN_STRIP TB" xsim_run.log
findstr /C:"VLAN_STRIP TB PASS" xsim_run.log >nul || exit /b 1
exit /b 0
