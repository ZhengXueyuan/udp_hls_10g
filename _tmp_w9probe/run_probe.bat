@echo off
REM tb_w9probe runner: %1 = run tag (rate | def | ovlonly | p7bonly)
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HERE=%~dp0
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "TAG=%1"
if "%TAG%"=="" set "TAG=def"
set "DEFS="
if /i "%TAG%"=="rate" set "DEFS=-d P7B_10G -d UDP_TX_OVL"
if /i "%TAG%"=="ovlonly" set "DEFS=-d UDP_TX_OVL"
if /i "%TAG%"=="p7bonly" set "DEFS=-d P7B_10G"
echo [W9PROBE] TAG=%TAG% DEFS=%DEFS%
if not exist "%HERE%\run_%TAG%" mkdir "%HERE%\run_%TAG%"
cd /d "%HERE%\run_%TAG%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%ROOT%\rtl\fifo_sync.v" "%ROOT%\rtl\checksum16.v" "%ROOT%\rtl\app_udp_pattern.v" "%ROOT%\rtl\udp_tx_cfg.v" "%ROOT%\rtl\udp_tx_frame.v" "%HERE%\tb_w9probe.v" > xvlog_probe.log 2>&1 || (type xvlog_probe.log & exit /b 1)
call "%XV%\xvlog.bat" -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_probe.log 2>&1
call "%XV%\xelab.bat" -debug typical -L unisims_ver xil_defaultlib.tb_w9probe xil_defaultlib.glbl -s tb_w9probe -log xelab_probe.log > /dev/null 2>&1 || (type xelab_probe.log & exit /b 1)
call "%XV%\xsim.bat" tb_w9probe -runall -log xsim_probe.log > /dev/null 2>&1
findstr /C:"W9PROBE" xsim_probe.log
exit /b 0
