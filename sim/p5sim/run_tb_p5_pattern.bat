@echo off
REM run_tb_p5_pattern.bat -- app_pattern TX AXIS contract unit gate (P5a review W3)
REM ev_down mid-frame must close the frame (tlast) and never drop tvalid without tlast
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5sim

call %XV%\xvlog.bat -work xil_defaultlib_p ^
  %RTL%\app_pattern.v ^
  %TB%\tb_p5_pattern.v > xvlog_p.log 2>&1 || (type xvlog_p.log & exit /b 1)

call %XV%\xelab.bat xil_defaultlib_p.tb_p5_pattern -s tb_p5_pattern -log xelab_p.log > NUL 2>&1 || (type xelab_p.log & exit /b 1)
call %XV%\xsim.bat tb_p5_pattern -runall -log xsim_p.log > NUL 2>&1 || (type xsim_p.log & exit /b 1)

findstr /C:"P5 PATTERN" xsim_p.log
findstr /C:"W3 case" xsim_p.log
