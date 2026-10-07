@echo off
REM quick_bw.bat -- P7B-RETXFIX r6 (L-A) 预检: 只跑 B / W / X 三臂 (全门 = run_tx_ovl_gate.bat)
REM   B = OVL 基线 (expect TB OK) / W = ARM_ACKGATE 专项 (expect TB OK) /
REM   X = mut_l1 + ARM_ACKGATE (expect nonzero, 判据有牙)
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%~dp0..\..\rtl
set HERE=%~dp0
cd /d %HERE%
call :run B "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL"
echo QUICK_B_RC=%errorlevel%
call :run W "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_ACKGATE"
echo QUICK_W_RC=%errorlevel%
call :run X "%HERE%\mut\mut_l1.v" "-d TCP_TX_OVL -d ARM_ACKGATE"
echo QUICK_X_RC=%errorlevel%
exit /b 0

:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\rtl\tcb.v" "..\..\..\rtl\fifo_sync.v" "..\..\..\rtl\checksum16.v" "..\..\..\rtl\retx_ram.v" "..\..\..\tb\tb_tcp_tx_ovl.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_tcp_tx_ovl -s txovl -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" txovl -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_TCP_TX_OVL: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"REDS " xs.log & findstr /C:"TB_TCP_TX_OVL" xs.log & findstr /C:"ACKGATE" xs.log & popd & exit /b 1)
findstr /C:"TB_TCP_TX_OVL" xs.log
findstr /C:"ACKGATE" xs.log
popd
exit /b 0
