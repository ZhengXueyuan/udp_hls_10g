@echo off
setlocal
REM =====================================================================
REM run_tx_ovl_gate.bat -- P7b Stage C / tcp_tx_frame ping-pong gate (TCP_TX_OVL)
REM   A = default build (no macro)      expect RC 0  (S0: current serial RTL green)
REM   B = -d TCP_TX_OVL                 expect RC 0  (ping-pong green)
REM   C..I = mutants (1 change each, from sim/p7b_stagec_tx/mut):
REM     C = M-S0a  advance write does not advance (OVL branch)
REM     D = M-S0b  same class in the DEFAULT branch (S0 sensitivity)
REM     E = M-C1   control reservation and data advance same cycle
REM     F = M-C7   drop !ctrl_slot_busy from start_ack
REM     G = M-C9   arbitration key = ctrl_slot_busy (no ctrl_tx_pend)
REM     H = M-C3   ping-pong degenerated to single bank
REM     I = M-C2   control reservation registered 8 cycles (form A)
REM   L = M-W66-1  stat_winstall never counts (build E)
REM   M = M-W66-2  stat_winstall predicate drops !wnd_open (build E)
REM   --- build F (W67/W69 judges + the W67_CAP_SMALL arm) ---
REM   N = M-W67-1  split predicate drops the side term (expect nonzero; has teeth in arm B)
REM   O = CLEAN  -d TCP_TX_OVL -d W67_CAP_SMALL  expect RC 0  (the ONLY arm where the
REM       board-cap side is non-empty: cap 8192 is reachable, so W67 is NOT an empty judge)
REM   P = M-W67-2  cap-side counter never counts (expect nonzero; teeth ONLY in arm O)
REM   Q = M-W69-2  op-point latch enabled by start_data instead of the wait cycle
REM   R = M-W69-1  op-point latch never updates
REM   --- P7B-PERSIST (2026-10-10) ---
REM   S = CLEAN  -d TCP_TX_OVL -d ARM_PERSIST          expect RC 0 (all new judges green)
REM   T = CLEAN  -d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL
REM       (same stimulus, DUT PERSIST_EN=0)             expect RC!=0 (negative control)
REM   U = M-PS1  mut_ps_noarmfin (drop !fin_sent_r from ps_arm)      expect RC!=0
REM   V = M-PS2  mut_ps_noarmrst (drop !rst_sent_r from ps_arm)      expect RC!=0
REM   W = M-PS3  mut_ps_nodsg    (drop ds_guard from probe_sel)     expect RC!=0
REM Contract: A/B/O/S RC==0; C..R + T..W RC!=0 except J (KNOWN GAP, not counted).
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
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
call :run L "%HERE%\mut\mut_w66_dead.v" "-d TCP_TX_OVL"
set RCL=%errorlevel%
call :run M "%HERE%\mut\mut_w66_nownd.v" "-d TCP_TX_OVL"
set RCM=%errorlevel%
call :run N "%HERE%\mut\mut_w67_always.v" "-d TCP_TX_OVL"
set RCN=%errorlevel%
call :run O "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL -d W67_CAP_SMALL"
set RCO=%errorlevel%
call :run P "%HERE%\mut\mut_w67_dead.v" "-d TCP_TX_OVL -d W67_CAP_SMALL"
set RCP=%errorlevel%
call :run Q "%HERE%\mut\mut_w69_atstart.v" "-d TCP_TX_OVL"
set RCQ=%errorlevel%
call :run R "%HERE%\mut\mut_w69_dead.v" "-d TCP_TX_OVL"
set RCR=%errorlevel%
REM --- P7B-PERSIST (2026-10-10) ---
call :run S "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_PERSIST"
set RCS=%errorlevel%
call :run T "%RTL%\tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL"
set RCT=%errorlevel%
call :run U "%HERE%\mut\mut_ps_noarmfin.v" "-d TCP_TX_OVL -d ARM_PERSIST"
set RCU=%errorlevel%
call :run V "%HERE%\mut\mut_ps_noarmrst.v" "-d TCP_TX_OVL -d ARM_PERSIST"
set RCV=%errorlevel%
call :run W "%HERE%\mut\mut_ps_nodsg.v" "-d TCP_TX_OVL -d ARM_PERSIST"
set RCW=%errorlevel%

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
echo   J M-C6  no rewgate RC=%RCJ% (KNOWN GAP: stimulus hits the resv window only twice; not counted)
echo   K M-C8  no rx_idle RC=%RCK% (expect nonzero)
echo   L M-W66-1 dead counter RC=%RCL% (expect nonzero; new W66 judge, build E)
echo   M M-W66-2 no !wnd_open RC=%RCM% (expect nonzero; semantic-wrong direction)
echo   N M-W67-1 no side term  RC=%RCN% (expect nonzero; build F)
echo   O CLEAN W67_CAP_SMALL   RC=%RCO% (expect 0; **cap-side arm** - W67 non-vacuous here)
echo   P M-W67-2 dead cap cnt  RC=%RCP% (expect nonzero; build F)
echo   Q M-W69-2 latch@start   RC=%RCQ% (expect nonzero; build F)
echo   R M-W69-1 dead latch    RC=%RCR% (expect nonzero; build F)
echo   S PERSIST clean arm     RC=%RCS% (expect 0; ARM_PERSIST)
echo   T PERSIST negctl        RC=%RCT% (expect nonzero; PERSIST_EN=0)
echo   U M-PS1 no !fin_sent_r  RC=%RCU% (expect nonzero; ARM_PERSIST)
echo   V M-PS2 no !rst_sent_r  RC=%RCV% (expect nonzero; ARM_PERSIST)
echo   W M-PS3 no ds_guard     RC=%RCW% (expect nonzero; ARM_PERSIST)

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
if "%RCK%"=="0" set /a FAILS+=1
if "%RCL%"=="0" set /a FAILS+=1
if "%RCM%"=="0" set /a FAILS+=1
if "%RCN%"=="0" set /a FAILS+=1
if not "%RCO%"=="0" set /a FAILS+=1
if "%RCP%"=="0" set /a FAILS+=1
if "%RCQ%"=="0" set /a FAILS+=1
if "%RCR%"=="0" set /a FAILS+=1
if not "%RCS%"=="0" set /a FAILS+=1
if "%RCT%"=="0" set /a FAILS+=1
if "%RCU%"=="0" set /a FAILS+=1
if "%RCV%"=="0" set /a FAILS+=1
if "%RCW%"=="0" set /a FAILS+=1

echo   ---- B key readings ----
findstr /C:"FRAMES" /C:"COV " /C:"MINGAP" /C:"CYCRX" /C:"CYCTX" /C:"FRAMEPERIOD" /C:"OVL " /C:"REDS" /C:"T8 " /C:"W66" /C:"W67" /C:"W69" /C:"TB_TCP_TX_OVL" "runB\xs.log"
echo   ---- arm O key readings (the W67_CAP_SMALL arm) ----
findstr /C:"W66" /C:"W67" /C:"W69" /C:"REDS " /C:"FRAMES" /C:"TB_TCP_TX_OVL" "runO\xs.log"
echo   ---- arm S key readings (P7B-PERSIST clean arm) ----
findstr /C:"PS1" /C:"PS2" /C:"PS3" /C:"PS4" /C:"PS5" /C:"PS6" /C:"REDS " /C:"FRAMES" /C:"TB_TCP_TX_OVL" "runS\xs.log"
echo   ---- arm T key readings (P7B-PERSIST negative control) ----
findstr /C:"PS2" /C:"PS3" /C:"PS6" /C:"REDS " /C:"TB_TCP_TX_OVL" "runT\xs.log"
echo   ---- mutant verdicts (REDS line + verdict + first FAIL lines) ----
for %%M in (C D E F G H I J K L M N O P Q R S T U V W) do (
  echo   [%%M]:
  findstr /C:"REDS " /C:"TB_TCP_TX_OVL:" /C:"T8 " "run%%M\xs.log"
)
if "%FAILS%"=="0" (echo TX_OVL_GATE: PASS & exit /b 0)
echo TX_OVL_GATE: FAIL count=%FAILS%
exit /b 1

REM =====================================================================
:run
set "NAME=%~1"
set "RSRC=%~2"
set "DEFS=%~3"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\..\rtl\tcb.v" "..\..\..\..\rtl\fifo_sync.v" "..\..\..\..\rtl\checksum16.v" "..\..\..\..\rtl\retx_ram.v" "..\..\..\..\tb\tb_tcp_tx_ovl.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
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
