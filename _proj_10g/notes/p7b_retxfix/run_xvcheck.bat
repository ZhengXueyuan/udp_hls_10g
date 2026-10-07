@echo off
REM P7B-RETXFIX 语法体检: 对改动文件跑裸 xvlog (两个宏态各一遍)
REM 用法: cmd //c '_proj_10g\notes\p7b_retxfix\run_xvcheck.bat'
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %~dp0
if not exist xv_ovl mkdir xv_ovl
if not exist xv_def mkdir xv_def
echo ===== OVL 态 (TCP_TX_OVL=1) =====
cd xv_ovl
call "%XV%\xvlog.bat" -work xil_defaultlib -d TCP_TX_OVL -d P7B_10G -d DP_156MHZ ..\..\..\..\rtl\tcp_tx_frame.v
echo XVLOG_TXFRAME_OVL_RC=%ERRORLEVEL%
call "%XV%\xvlog.bat" -work xil_defaultlib ..\..\..\..\rtl\tcp_rx.v
echo XVLOG_TCPRX_RC=%ERRORLEVEL%
cd ..
echo ===== 默认态 (宏关) =====
cd xv_def
call "%XV%\xvlog.bat" -work xil_defaultlib ..\..\..\..\rtl\tcp_tx_frame.v
echo XVLOG_TXFRAME_DEF_RC=%ERRORLEVEL%
call "%XV%\xvlog.bat" -work xil_defaultlib ..\..\..\..\rtl\tcp_rx.v
echo XVLOG_TCPRX_DEF_RC=%ERRORLEVEL%
cd ..
endlocal
