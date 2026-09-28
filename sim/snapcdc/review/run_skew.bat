@echo off
REM run_skew.bat <dut.v> - skewed-source discriminating test (own sim dir)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %1 tb_skew.v > xvlog_s.log 2>&1 || (type xvlog_s.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_skew -s tb_skew -log xelab_s.log > NUL 2>&1 || (type xelab_s.log & exit /b 1)
call %XV%\xsim.bat tb_skew -runall -log xsim_s.log > NUL 2>&1
findstr /C:"SKEW_RESULT" /C:"[结果]" /C:"MIX" /C:"TIMEOUT" xsim_s.log
