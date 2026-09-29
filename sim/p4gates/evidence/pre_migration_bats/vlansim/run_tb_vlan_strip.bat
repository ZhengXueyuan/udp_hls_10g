@echo off
REM run_tb_vlan_strip.bat -- vlan_strip unit gate (xsim, self-checking TB)
REM   from Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\vlansim\run_tb_vlan_strip.bat'
REM   TB prints "VLAN_STRIP TB PASS" / "VLAN_STRIP TB FAIL" (exit code follows).
REM   NOTE: xvlog.bat writes its own xvlog.log -> redirect to a different name.
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call %XV%\xvlog.bat -work xil_defaultlib ^
  D:\repo\ECO\udp_hls_10g\rtl\vlan_strip.v ^
  D:\repo\ECO\udp_hls_10g\tb\tb_vlan_strip.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_vlan_strip -s tb_vlan_strip -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_vlan_strip -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)
findstr /C:"ERR" /C:"VLAN_STRIP TB" xsim_run.log
findstr /C:"VLAN_STRIP TB PASS" xsim_run.log >nul || exit /b 1
exit /b 0
