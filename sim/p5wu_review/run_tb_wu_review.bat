@echo off
setlocal
set "REPO=%~dp0..\.."
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO%\rtl
set SIM=%~dp0runrev2
if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %RTL%\fifo_sync.v %RTL%\app_ctrl.v %REPO%\sim\p5wu_review\app_ctrl_head.v %REPO%\sim\p5wu_review\tb_wu_review.v > xvlog_rev.log 2>&1 || (type xvlog_rev.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_wu_review -s tb_wu_review -log xelab_rev.log > NUL 2>&1 || (type xelab_rev.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_rev.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_rev.log & exit /b 1)
call %XV%\xsim.bat tb_wu_review -runall -nolog > xsim_out.txt 2>&1
type xsim_out.txt
findstr /C:"WU-REVIEW GATE OK" xsim_out.txt > NUL
if errorlevel 1 (echo REVIEW GATE FAIL & exit /b 1)
echo REVIEW GATE PASS
