@echo off
REM P7B-BIZ regression agent: A/B harness (OLD rtl/app_udp_pattern.v vs CURRENT tb)
REM This does NOT touch any repo file: the old RTL is a scratch copy in this dir.
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
cd /d %~dp0
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %R%\rtl\fifo_sync.v %R%\rtl\checksum16.v %R%\rtl\crc32_8b.v %R%\rtl\udp_tx_cfg.v %R%\rtl\udp_tx_frame.v %R%\rtl\mac_tx_64.v app_udp_pattern.v %R%\tb\tb_app_udp_rate.v > xv_out.txt 2>&1
if errorlevel 1 (type xv_out.txt & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_app_udp_rate -s ab_old -log xelab.log > /dev/null 2>&1
if errorlevel 1 (type xelab.log & exit /b 1)
call %XV%\xsim.bat ab_old -runall -log xsim.log > /dev/null 2>&1
findstr /C:"C1 contract" xsim.log
findstr /C:"C2 framer" xsim.log
findstr /C:"C3 wire" xsim.log
findstr /C:"coverage:" xsim.log
findstr /C:"app tx_frames" xsim.log
findstr /C:"RATE GATE" xsim.log
exit /b 0
