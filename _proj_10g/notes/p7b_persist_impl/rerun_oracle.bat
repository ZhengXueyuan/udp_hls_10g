@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
set AG=D:\repo\XCKU5PMini\udp_hls_10g\sim\p7b_stagec_tx_regress\author_gate
set EV=D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_persist_impl\ev
call :one S "%R%\rtl\tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_PERSIST -d PS_RINGORACLE" "%AG%\ors" "orS"
call :one T "%R%\rtl\tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_PERSIST -d PS_RINGORACLE -d PERSIST_NEGCTL" "%AG%\ort" "orT"
echo ORACLE_RUN_DONE
exit /b 0
:one
set NAME=%~1
set SRC=%~2
set DEFS=%~3
set DIR=%~4
set TAG=%~5
if not exist "%DIR%" mkdir "%DIR%"
pushd "%DIR%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%SRC%" "%R%\rtl\tcb.v" "%R%\rtl\fifo_sync.v" "%R%\rtl\checksum16.v" "%R%\rtl\retx_ram.v" "%R%\tb\tb_tcp_tx_ovl.v" > xv_out.log 2>&1 || (echo XVLOG-FAIL %NAME% & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_tcp_tx_ovl -s txovl -log xe.log > xe_out.log 2>&1 || (echo XELAB-FAIL %NAME% & findstr /I "ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" txovl -runall -log xs.log > xs_out.log 2>&1
echo [%NAME%] done
popd
exit /b 0
