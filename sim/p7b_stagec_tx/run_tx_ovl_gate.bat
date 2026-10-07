@echo off
setlocal
REM =====================================================================
REM run_tx_ovl_gate.bat -- P7b Stage C / tcp_tx_frame ping-pong gate (TCP_TX_OVL)
REM   A = default build (no macro)      expect RC 0  (S0: current serial RTL green)
REM   B = -d TCP_TX_OVL                 expect RC 0  (ping-pong green)
REM   C..L = mutants (1 change each, from sim/p7b_stagec_tx/mut):
REM     C = M-S0a  advance write does not advance (OVL branch)
REM     D = M-S0b  same class in the DEFAULT branch (S0 sensitivity)
REM     E = M-C1   control reservation and data advance same cycle
REM     F = M-C7   drop !ctrl_slot_busy from start_ack
REM     G = M-C9   arbitration key = ctrl_slot_busy (no ctrl_tx_pend)
REM     H = M-C3   ping-pong degenerated to single bank
REM     I = M-C2   control reservation registered 8 cycles (form A)
REM     J = M-C6   drop the rewind gate (ctrl_adv_inflight)  [IN CONTRACT now]
REM     K = M-C8   drop rx_idle from start_ack
REM     L = M-C4   session self-lock (drain branch never clears retx_active)
REM   S/T = B5 same-batch INTEGRATION gate (real app_pattern P7B_10G -> real framer):
REM     S = integ tb vs current RTL    expect OK
REM     T = integ tb vs mut_s0a        expect nonzero  <-- teeth of the integ gate
REM   P/Q/R = F1 negative control (stimulus = review's flood probe, verbatim):
REM     P = probe vs current OVL RTL   expect NOFLOOD
REM     Q = probe vs mut_f1 (fix off)  expect FLOOD   <-- teeth of the F1 judge
REM     R = probe vs default serial    expect NOFLOOD
REM Contract: A/B/P/R RC==0; C..L/Q RC!=0.
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "PY=C:\Users\zhxue\anaconda3\python.exe"
set "RTL=%ROOT%\rtl"
set "TB=%ROOT%\tb\tb_tcp_tx_ovl.v"
cd /d "%HERE%"
if not exist "%RTL%\tcp_tx_frame.v" (echo [FAIL] RTL missing & exit /b 1)
if not exist "%TB%" (echo [FAIL] TB missing & exit /b 1)
"%PY%" mk_mut_tx.py > mut_gen.log 2>&1 || (type mut_gen.log & echo MUTGEN-FAIL & exit /b 1)

call :run A "%RTL%\tcp_tx_frame.v" ""
set RCA=%errorlevel%
call :run B "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL"
set RCB=%errorlevel%
call :run C "%HERE%\mut\mut_s0a.v" "-d TCP_TX_OVL"
set RCC=%errorlevel%
call :run D "%HERE%\mut\mut_s0b.v" ""
set RCD=%errorlevel%
call :run E "%HERE%\mut\mut_c1.v" "-d TCP_TX_OVL"
set RCE=%errorlevel%
call :run F "%HERE%\mut\mut_c7.v" "-d TCP_TX_OVL"
set RCF=%errorlevel%
call :run G "%HERE%\mut\mut_c9.v" "-d TCP_TX_OVL"
set RCG=%errorlevel%
call :run H "%HERE%\mut\mut_c3.v" "-d TCP_TX_OVL"
set RCH=%errorlevel%
call :run I "%HERE%\mut\mut_c2.v" "-d TCP_TX_OVL"
set RCI=%errorlevel%
call :run J "%HERE%\mut\mut_c6.v" "-d TCP_TX_OVL"
set RCJ=%errorlevel%
call :run K "%HERE%\mut\mut_c8.v" "-d TCP_TX_OVL"
set RCK=%errorlevel%
call :run L "%HERE%\mut\mut_c4.v" "-d TCP_TX_OVL"
set RCL=%errorlevel%
call :runp P "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL" "FLOODPROBE: NOFLOOD"
set RCP=%errorlevel%
call :runp Q "%HERE%\mut\mut_f1.v" "-d TCP_TX_OVL" "FLOODPROBE: FLOOD"
set RCQ=%errorlevel%
call :runp R "%RTL%\tcp_tx_frame.v" "-d ARM_SERIAL" "FLOODPROBE: NOFLOOD"
set RCR=%errorlevel%
call :runi S "%RTL%\tcp_tx_frame.v"
set RCS=%errorlevel%
call :runi T "%HERE%\mut\mut_s0a.v"
set RCT=%errorlevel%

echo ==================== SUMMARY ====================
echo   A default serial  RC=%RCA%  (expect 0)
echo   B TCP_TX_OVL      RC=%RCB%  (expect 0)
echo   C M-S0a advance   RC=%RCC%  (expect nonzero)
echo   D M-S0b default   RC=%RCD%  (expect nonzero)
echo   E M-C1  samecycle RC=%RCE%  (expect nonzero)
echo   F M-C7  no slot   RC=%RCF%  (expect nonzero)
echo   G M-C9  arb busy  RC=%RCG%  (expect nonzero)
echo   H M-C3  one bank  RC=%RCH%  (expect nonzero)
echo   I M-C2  reg 8cyc  RC=%RCI%  (expect nonzero)
echo   J M-C6  no rewgate RC=%RCJ% (expect nonzero; stimulus = in-slot FIN window + retx_req)
echo   K M-C8  no rx_idle RC=%RCK% (expect nonzero)
echo   L M-C4  self-lock RC=%RCL%  (expect nonzero; stuck judge)
echo   P probe OVL fixed RC=%RCP% (expect 0 = NOFLOOD)
echo   Q probe M-F1      RC=%RCQ% (expect 0 = FLOOD verdict found; teeth)
echo   R probe serial    RC=%RCR% (expect 0 = NOFLOOD)
echo   S integ app to frm RC=%RCS% (expect 0 = OK)
echo   T integ + M-S0a   RC=%RCT% (expect nonzero)

set FAILS=0
if not "%RCA%"=="0" set /a FAILS+=1
if not "%RCB%"=="0" set /a FAILS+=1
if "%RCC%"=="0" set /a FAILS+=1
if "%RCD%"=="0" set /a FAILS+=1
if "%RCE%"=="0" set /a FAILS+=1
if "%RCF%"=="0" set /a FAILS+=1
if "%RCG%"=="0" set /a FAILS+=1
if "%RCH%"=="0" set /a FAILS+=1
if "%RCI%"=="0" set /a FAILS+=1
if "%RCJ%"=="0" set /a FAILS+=1
if "%RCK%"=="0" set /a FAILS+=1
if "%RCL%"=="0" set /a FAILS+=1
if not "%RCP%"=="0" set /a FAILS+=1
if not "%RCQ%"=="0" set /a FAILS+=1
if not "%RCR%"=="0" set /a FAILS+=1
if not "%RCS%"=="0" set /a FAILS+=1
if "%RCT%"=="0" set /a FAILS+=1

echo   ---- B key readings ----
findstr /C:"FRAMES" /C:"COV " /C:"MINGAP" /C:"CYCRX" /C:"CYCTX" /C:"FRAMEPERIOD" /C:"OVL F1" /C:"OVL C6" /C:"OVL wsrc" /C:"REDS" /C:"T8 " /C:"TB_TCP_TX_OVL" "runB\xs.log"
echo   ---- F1 negative control (review flood probe: P fixed / Q mut_f1 / R serial) ----
for %%M in (P Q R) do (
  echo   [%%M]:
  findstr /C:"FLOODPROBE" "run%%M\xs.log"
)
echo   ---- integration gate (real app_pattern P7B_10G -> real tcp_tx_frame) ----
for %%M in (S T) do (
  echo   [%%M]:
  findstr /C:"FRAMES" /C:"WIRE" /C:"APP " /C:"T8" /C:"REDS" /C:"TB_INTEG_APP_TX" "run%%M\xs.log"
)
echo   ---- mutant verdicts (REDS line + verdict + first FAIL lines) ----
for %%M in (C D E F G H I J K L) do (
  echo   [%%M]:
  findstr /C:"REDS " /C:"TB_TCP_TX_OVL:" /C:"T8 " "run%%M\xs.log"
)
if "%FAILS%"=="0" (echo TX_OVL_GATE: PASS & exit /b 0)
echo TX_OVL_GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:runi
REM integration gate arm (needs -d P7B_10G -d TCP_TX_OVL + rtl/app_pattern.v)
set "NAME=%~1"
set "RSRC=%~2"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib -d P7B_10G -d TCP_TX_OVL "%RSRC%" "..\..\..\rtl\tcb.v" "..\..\..\rtl\fifo_sync.v" "..\..\..\rtl\checksum16.v" "..\..\..\rtl\retx_ram.v" "..\..\..\rtl\app_pattern.v" "..\..\..\tb\tb_integ_app_tx.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_integ_app_tx -s tb_integ -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb_integ -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_INTEG_APP_TX: OK" xs.log > NUL
if errorlevel 1 (echo ---- INTEG detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"REDS" xs.log & findstr /C:"TB_INTEG_APP_TX" xs.log & popd & exit /b 1)
findstr /C:"TB_INTEG_APP_TX" xs.log
popd
exit /b 0

:runp
REM probe arm: %4 = expected verdict string in xs.log
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
set "EXP=%~4"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\rtl\tcb.v" "..\..\..\rtl\fifo_sync.v" "..\..\..\rtl\checksum16.v" "..\..\..\rtl\retx_ram.v" "..\..\..\sim\p7b_stagec_tx\probe\tb_flood_probe.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_flood_probe -s flood -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" flood -runall -log xs.log > xs_out.log 2>&1
findstr /C:"%EXP%" xs.log > NUL
if errorlevel 1 (echo PROBE-VERDICT-MISMATCH [%NAME%] expected [%EXP%]: & findstr /C:"FLOODPROBE" xs.log & popd & exit /b 1)
findstr /C:"FLOODPROBE" xs.log
popd
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
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE [%NAME%]: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & popd & exit /b 1)
findstr /I /C:"ERROR" xv_out.log > NUL
if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_tcp_tx_ovl -s txovl -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)
call "%XV%\xsim.bat" txovl -runall -log xs.log > xs_out.log 2>&1
findstr /C:"TB_TCP_TX_OVL: OK" xs.log > NUL
if errorlevel 1 (echo ---- TB detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"REDS " xs.log & findstr /C:"TB_TCP_TX_OVL" xs.log & popd & exit /b 1)
findstr /C:"TB_TCP_TX_OVL" xs.log
popd
exit /b 0
