@echo off
setlocal
REM =====================================================================
REM run_rate8.bat -- cycles/frame before (A: no macro) vs after (B: P7B_10G)
REM TB 源码 = _proj_10g\notes\p7b_rate\  (另一路 agent 的文件, **只读不改**)
REM 工作目录 = 本目录下 runRA / runRB (独立 xsim.dir, 避免文件锁)
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "RATM=%ROOT%\_proj_10g\notes\p7b_rate"
set "MAC=%ROOT%\_proj_10g\p7b_mac\rtl"
cd /d "%HERE%"

call :run RA ""
set "RCA=%errorlevel%"
call :run RB "-d P7B_10G"
set "RCB=%errorlevel%"

echo ==================== RATE8 SUMMARY ====================
echo   [A] default build  RC=%RCA%
findstr /C:"frames measured" /C:"MEAN FRAME PERIOD" /C:"CYCLES PER" /C:"PAYLOAD RATE" /C:"delta app frames" /C:"FRAME PERIOD" "runRA\xsA.log"
echo   [B] P7B_10G build  RC=%RCB%
findstr /C:"frames measured" /C:"MEAN FRAME PERIOD" /C:"CYCLES PER" /C:"PAYLOAD RATE" /C:"delta app frames" /C:"FRAME PERIOD" "runRB\xsB.log"
exit /b 0

REM =====================================================================
:run
set "NAME=%~1"
set "DEFS=%~2"
if not exist "run%NAME%" mkdir "run%NAME%"
pushd "run%NAME%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% ^
  "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\crc32_8b.v" ^
  "%RTL%\udp_tx_cfg.v" "%RTL%\udp_tx_frame.v" "%RTL%\tx_arb.v" ^
  "%RTL%\app_udp_pattern.v" ^
  "%MAC%\crc32_64.v" "%MAC%\mac_tx_10g.v" ^
  "%RATM%\tb_lvl_app.v" "%RATM%\tb_lvl_full.v" "%RATM%\tb_lvl_mac.v" > xv.log 2>&1 || (type xv.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv.log & popd & exit /b 1)
for %%T in (lvl_app lvl_full lvl_mac) do (
  call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_%%T -s tb_%%T -log xe_%%T.log > NUL 2>&1 || (type xe_%%T.log & popd & exit /b 1)
  call "%XV%\xsim.bat" tb_%%T -runall -log xs_%%T.log > NUL 2>&1
)
copy /y xs_lvl_app.log xsA.log > NUL
copy /y xs_lvl_full.log xsB.log >> NUL
copy /y xs_lvl_app.log "xs_%NAME%_app.log" > NUL
copy /y xs_lvl_full.log "xs_%NAME%_full.log" > NUL
popd
exit /b 0
