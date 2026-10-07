@echo off
REM P7B-RETXFIX 快速两臂: qB (现役 OVL 修复) + qU (mut_k2 只撤跳写) —— 量 RETXFIX span_max 定界
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g_fix
cd /d %~dp0
if not exist qB mkdir qB
pushd qB
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib -d TCP_TX_OVL "%ROOT%\rtl\tcp_tx_frame.v" "%ROOT%\rtl\tcb.v" "%ROOT%\rtl\fifo_sync.v" "%ROOT%\rtl\checksum16.v" "%ROOT%\rtl\retx_ram.v" "%ROOT%\tb\tb_tcp_tx_ovl.v" > xv.log 2>&1 || (type xv.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_tcp_tx_ovl -s txovl -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERR-[B] & popd & exit /b 1)
call "%XV%\xsim.bat" txovl -runall -log xs.log > xs_out.log 2>&1
echo ---- [qB] fixed OVL ----
findstr /C:"OVL RETXFIX" /C:"TB_TCP_TX_OVL:" /C:"REDS " xs.log
popd
if not exist qU mkdir qU
pushd qU
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib -d TCP_TX_OVL "%ROOT%\sim\p7b_stagec_tx\mut\mut_k2.v" "%ROOT%\rtl\tcb.v" "%ROOT%\rtl\fifo_sync.v" "%ROOT%\rtl\checksum16.v" "%ROOT%\rtl\retx_ram.v" "%ROOT%\tb\tb_tcp_tx_ovl.v" > xv.log 2>&1 || (type xv.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_tcp_tx_ovl -s txovl -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERR-[U] & popd & exit /b 1)
call "%XV%\xsim.bat" txovl -runall -log xs.log > xs_out.log 2>&1
echo ---- [qU] mut_k2 (jump off) ----
findstr /C:"OVL RETXFIX" /C:"TB_TCP_TX_OVL:" /C:"REDS " /C:"RETXFIX span" xs.log
popd
endlocal
