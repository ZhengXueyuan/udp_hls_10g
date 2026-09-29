@echo off
REM probe p7a: can p7a_top be elaborated (GT + VIO IP sources)?
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set RTL=%ROOT%\_proj_10g\rtl
set IP=%ROOT%\_proj_10g\vivado_prj\p7a_prj.gen\sources_1\ip
set WORK=%~dp0probe_p7a_work
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%"
cd /d "%WORK%"
copy /y "%RTL%\..\tcl\lint\files.f" files.f >NUL
echo %IP%\gt_10gbr\synth\gtwizard_ultrascale_v1_7_gtye4_channel.v >> files.f
echo %IP%\gt_10gbr\synth\gtwizard_ultrascale_v1_7_gtye4_common.v >> files.f
echo %IP%\gt_10gbr\synth\gt_10gbr.v >> files.f
echo %IP%\gt_10gbr\synth\gt_10gbr_gtwizard_gtye4.v >> files.f
echo %IP%\gt_10gbr\synth\gt_10gbr_gtwizard_top.v >> files.f
echo %IP%\gt_10gbr\synth\gt_10gbr_gtye4_channel_wrapper.v >> files.f
echo %IP%\gt_10gbr\synth\gt_10gbr_gtye4_common_wrapper.v >> files.f
dir /b /s "%IP%\gt_10gbr\hdl\*.v" >> files.f
echo %IP%\vio_p7a\vio_p7a_stub.v >> files.f
echo --- files.f ---
type files.f
echo === XVLOG %TIME% ===
call %XV%\xvlog.bat -work xil_defaultlib -i %RTL% -i "%IP%\gt_10gbr\hdl" -f files.f > xv_p7a.log 2>&1
echo XVLOG_RC=%ERRORLEVEL%
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_p7a.log 2>&1
echo === XELAB %TIME% ===
call %XV%\xelab.bat -debug typical -L unisims_ver -L secureip xil_defaultlib.p7a_top xil_defaultlib.glbl -s lint_p7a -log xe_p7a.log > NUL 2>&1
echo XELAB_RC=%ERRORLEVEL%
echo === xelab log ===
type xe_p7a.log
