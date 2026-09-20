@echo off
REM run_tb_p5b_ind.bat -- P5b 独立对抗单元门 (测试 agent 自建, 不复用实现者 TB)
REM 判据: 末行 "P5B IND OK" (失败则 "P5B IND FAIL n" + 逐项 FAIL 明细)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl

if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\app_ctrl.v ^
  tb_p5b_ind.v > xvlog_ind.log 2>&1 || (type xvlog_ind.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_p5b_ind -s tb_p5b_ind -log xelab_ind.log > NUL 2>&1 || (type xelab_ind.log & exit /b 1)
call %XV%\xsim.bat tb_p5b_ind -runall -log xsim_ind.log > NUL 2>&1

findstr /C:"FAIL" xsim_ind.log > NUL
if not errorlevel 1 (echo ---- FAIL DETAIL ---- & findstr /C:"FAIL" xsim_ind.log)

findstr /C:"P5B IND OK" xsim_ind.log > NUL
if errorlevel 1 (echo P5B INDEPENDENT GATE FAIL & exit /b 1)
echo P5B INDEPENDENT GATE PASS
