@echo off
setlocal
REM =====================================================================
REM run_ghost_arms.bat -- P7B-RETXHI-GHOST targeted arms (implementation round).
REM   PRE1 = pre-fix RTL + pre-fix TB   (-d TCP_TX_OVL -d ARM_PERSIST)  expect red
REM   PRE2 = pre-fix RTL + pre-fix TB   (-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL)
REM   S    = post-fix RTL + new TB      (same defs as PRE1)
REM   T    = post-fix RTL + new TB      (same defs as PRE2)
REM   M3   = mutant mut_ghost_m3   (ring bound := retx_hi)      expect e_ghost > 0
REM   M4   = mutant mut_ghost_norestore (no ring_restore)       expect e_replay_jump > 0
REM   M5   = mutant mut_ghost_noclamp (bare whi + stale whi)    expect e_ringhi > 0
REM   Usage:  run_ghost_arms.bat PRE1|PRE2|S|T|M3|M4|M5
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl\tcp_tx_frame.v"
set "TB=%ROOT%\tb\tb_tcp_tx_ovl.v"
set "PRTL=%HERE%\pre_fix\tcp_tx_frame_prefix.v"
set "PTB=%HERE%\pre_fix\tb_tcp_tx_ovl_prefix.v"
cd /d "%HERE%"
set "WHICH=%~1"
if "%WHICH%"=="PRE1" call :run2 PRE1 "%PRTL%" "%PTB%" "-d TCP_TX_OVL -d ARM_PERSIST" & goto :done
if "%WHICH%"=="PRE2" call :run2 PRE2 "%PRTL%" "%PTB%" "-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL" & goto :done
if "%WHICH%"=="S"    call :run2 S    "%RTL%"  "%TB%"  "-d TCP_TX_OVL -d ARM_PERSIST" & goto :done
if "%WHICH%"=="SDBG" call :run2 SDBG "%RTL%"  "%TB%"  "-d TCP_TX_OVL -d ARM_PERSIST -d GHOST_DBG" & goto :done
if "%WHICH%"=="T"    call :run2 T    "%RTL%"  "%TB%"  "-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL" & goto :done
if "%WHICH%"=="TDBG" call :run2 TDBG "%RTL%"  "%TB%"  "-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL -d GHOST_DBG" & goto :done
if "%WHICH%"=="M3"   call :run2 M3   "%HERE%\mut\mut_ghost_m3.v"         "%TB%" "-d TCP_TX_OVL -d ARM_PERSIST" & goto :done
if "%WHICH%"=="M4"   call :run2 M4   "%HERE%\mut\mut_ghost_norestore.v"  "%TB%" "-d TCP_TX_OVL -d ARM_PERSIST" & goto :done
if "%WHICH%"=="M5"   call :run2 M5   "%HERE%\mut\mut_ghost_noclamp.v"    "%TB%" "-d TCP_TX_OVL -d ARM_PERSIST" & goto :done
REM   RC/RCT = DIAG (TL ruling 1(b)): drop cfg_up clearing of epoch/snd_una_prev/rto_pend/rto_timer
REM           (keep whi_r clear) => separates candidate 2 for PS j9/j6
if "%WHICH%"=="RC"   call :run2 RC   "%HERE%\mut\mut_ghost_noclearothers.v" "%TB%" "-d TCP_TX_OVL -d ARM_PERSIST" & goto :done
if "%WHICH%"=="RCT"  call :run2 RCT  "%HERE%\mut\mut_ghost_noclearothers.v" "%TB%" "-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL" & goto :done
REM   YT = DIAG (TL ruling 1 final): M-4 (ring_restore := 0) under the T configuration
if "%WHICH%"=="YT"   call :run2 YT   "%HERE%\mut\mut_ghost_norestore.v" "%TB%" "-d TCP_TX_OVL -d ARM_PERSIST -d PERSIST_NEGCTL" & goto :done
echo unknown arm %WHICH% & exit /b 2
:done
exit /b %errorlevel%

:run2
set "NAME=%~1"
set "RSRC=%~2"
set "TSRC=%~3"
set "DEFS=%~4"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
if exist xs.log del /q xs.log
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..\..\..\..\rtl\tcb.v" "..\..\..\..\rtl\fifo_sync.v" "..\..\..\..\rtl\checksum16.v" "..\..\..\..\rtl\retx_ram.v" "%TSRC%" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)
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
