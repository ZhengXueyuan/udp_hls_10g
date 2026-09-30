@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
set W=%R%\_tmp_w9verify
set D=%W%\run_mac
if exist %D% rmdir /s /q %D%
mkdir %D%
cd /d %D%
call %XV%\xvlog.bat -work xil_defaultlib %R%\_proj_10g\p7b_mac\rtl\crc32_64.v %R%\rtl\fifo_sync.v %R%\_proj_10g\p7b_mac\rtl\mac_tx_10g.v %W%\tb_macperiod.v > _xvlog.out 2>&1
echo XVLOG_EXIT=%ERRORLEVEL%
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_macperiod -s tb_macperiod > _xelab.out 2>&1
echo XELAB_EXIT=%ERRORLEVEL%
call %XV%\xsim.bat tb_macperiod -runall -testplusarg "CLIST=%1" -testplusarg "NF=%2"
