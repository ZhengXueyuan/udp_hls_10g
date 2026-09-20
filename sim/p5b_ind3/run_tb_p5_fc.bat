@echo off
REM run_tb_p5_fc.bat -- P5b 定向单元门 (app_ctrl 流控算术/边界/回绕/H3/C14/C15)
REM 判据: tb_app_fc 内部逐项 PASS/FAIL + 末行 "P5 FC UNIT OK" / "P5 FC UNIT FAIL n"
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5b_ind3\fcrun

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\app_ctrl.v ^
  %TB%\tb_app_fc.v > xvlog_fc.log 2>&1 || (type xvlog_fc.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_app_fc -s tb_app_fc -log xelab_fc.log > NUL 2>&1 || (type xelab_fc.log & exit /b 1)
call %XV%\xsim.bat tb_app_fc -runall -log xsim_fc.log > NUL 2>&1 || (type xsim_fc.log & exit /b 1)

findstr /C:"P5 FC UNIT OK" xsim_fc.log > NUL
if errorlevel 1 (findstr /C:"FAIL" xsim_fc.log & exit /b 1)
echo P5 FC UNIT GATE PASS
