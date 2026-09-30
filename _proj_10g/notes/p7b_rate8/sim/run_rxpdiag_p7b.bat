@echo off
setlocal
REM =====================================================================
REM run_rxpdiag_p7b.bat -- 既有 RXP_DIAG 仪器的**宏组合**门 (本目录工作区)
REM   与 sim/rxpdiag/run_tb_rxp_diag.bat 同款文件表/TB, 只加 -d P7B_10G:
REM     A) 只 -d RXP_DIAG            = 今天诊断构建 (逐字节仪器)
REM     B) -d RXP_DIAG -d P7B_10G    = 8 字节/拍构建下的诊断组合
REM          (本模块里该组合**主动关闭宽 RX** ⇒ 仪器语义与 A 必须逐字相同)
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "TB=%ROOT%\tb"
set "BD=%ROOT%\board"
cd /d "%HERE%"

call :run A "-d RXP_DIAG -d APP_MODE"
set "RCA=%errorlevel%"
call :run B "-d RXP_DIAG -d APP_MODE -d P7B_10G"
set "RCB=%errorlevel%"
echo RXP-DIAG-A RC=%RCA%  RXP-DIAG-B RC=%RCB%
if "%RCA%%RCB%"=="00" (echo RXP-DIAG-COMBINED: PASS & exit /b 0)
echo RXP-DIAG-COMBINED: FAIL
exit /b 1

:run
set "NAME=%~1"
set "DEFS=%~2"
if not exist "rd_%NAME%" mkdir "rd_%NAME%"
pushd "rd_%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% ^
  "%RTL%\fifo_sync.v" "%RTL%\app_udp_pattern.v" "%RTL%\app_status_uart.v" ^
  "%BD%\uart_dbg.v" "%TB%\tb_rxp_diag.v" > xv_d.log 2>&1 || (type xv_d.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_d.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_d.log & popd & exit /b 1)
call "%XV%\xelab.bat" -L unisims_ver xil_defaultlib.tb_rxp_diag -s tb_rxp_diag -log xe_d.log > NUL 2>&1 || (type xe_d.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb_rxp_diag -runall -log xs_d.log > NUL 2>&1
findstr /C:"RXPDIAG" /C:"RXP-DIAG GATE" xs_d.log
findstr /C:"RXP-DIAG GATE: OK" xs_d.log > NUL
if errorlevel 1 (echo ---- FAIL detail [%NAME%]: & findstr /C:"FAIL" xs_d.log & popd & exit /b 1)
popd
exit /b 0
