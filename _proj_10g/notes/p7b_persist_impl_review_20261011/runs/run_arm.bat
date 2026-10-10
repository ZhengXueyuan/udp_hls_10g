@echo off
setlocal
REM run_arm.bat -- one xsim arm for the persist-impl review (D-2/D-3/D-7)
REM   usage: run_arm.bat <name> <rtl_src> "<defs>"
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
set "R=%ROOT%\rtl"
set "T=%ROOT%\tb\tb_tcp_tx_ovl.v"
if not exist "%HERE%\%NAME%" mkdir "%HERE%\%NAME%"
pushd "%HERE%\%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "%R%\tcb.v" "%R%\fifo_sync.v" "%R%\checksum16.v" "%R%\retx_ram.v" "%T%" > xv_out.log 2>&1 || (echo XVLOG-FAIL & type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR: & findstr /I "ERROR" xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_tcp_tx_ovl -s txovl -log xe.log > xe_out.log 2>&1 || (echo XELAB-FAIL: & findstr /I "ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" txovl -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_TCP_TX_OVL" xs.log
findstr /C:"PS7" xs.log
popd
exit /b 0
