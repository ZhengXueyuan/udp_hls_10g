@echo off
REM run_tb_p5_fc.bat -- P5b/P5c directed unit gate (app_ctrl), P5c-T5 private dir
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5c_t5\fcrun

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\app_ctrl.v %TB%\tb_app_fc.v > xvlog_fc.log 2>&1 || (type xvlog_fc.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_app_fc -s tb_app_fc -log xelab_fc.log > xelab_out.log 2>&1 || (type xelab_fc.log & exit /b 1)
call %XV%\xsim.bat tb_app_fc -runall -log xsim_fc.log > xsim_out.log 2>&1 || (type xsim_fc.log & exit /b 1)

findstr /C:"P5 FC UNIT OK" xsim_fc.log > findstr_out.log
if errorlevel 1 (findstr /C:"FAIL" xsim_fc.log & exit /b 1)
echo P5 FC UNIT GATE PASS
