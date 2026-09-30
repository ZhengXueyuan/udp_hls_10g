@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
set W=%R%\_tmp_w9verify
set D=%W%\rc_def_%1
if exist %D% rmdir /s /q %D%
mkdir %D%
cd /d %D%
set SRC=%W%\head_rtl
set SRCS=%SRC%\fifo_sync.v %SRC%\checksum16.v %SRC%\app_udp_pattern.v %SRC%\udp_tx_cfg.v %SRC%\udp_tx_frame.v %SRC%\crc32_64.v %SRC%\mac_tx_10g.v %W%\tb_chain_w9.v
call %XV%\xvlog.bat -work xil_defaultlib %SRCS% > _xvlog.out 2>&1
echo XVLOG_EXIT=%ERRORLEVEL%
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_chain_w9 -s tb_chain_w9 > _xelab.out 2>&1
echo XELAB_EXIT=%ERRORLEVEL%
call %XV%\xsim.bat tb_chain_w9 -runall -testplusarg "PAY=1472" -testplusarg "NFRM=40" -testplusarg "PHS=40"
