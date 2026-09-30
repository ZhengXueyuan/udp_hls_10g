@echo off
setlocal
REM =====================================================================
REM run_rate_probe.bat -- per-stage TX rate measurement (156.25 MHz / 10G)
REM Owner: bottleneck-localization agent. Writes ONLY under
REM        _proj_10g\notes\p7b_rate\.  Read-only on rtl/ and _proj_10g/p7b_mac/.
REM Stages: lvl_app / lvl_frame / lvl_mac / lvl_full
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate repo root from %~f0
  echo   derived ROOT = %ROOT%
  exit /b 1
)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "MAC=%ROOT%\_proj_10g\p7b_mac\rtl"
cd /d "%HERE%"
if exist xsim.dir rmdir /s /q xsim.dir

call "%XV%\xvlog.bat" -work xil_defaultlib ^
  "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\crc32_8b.v" ^
  "%RTL%\udp_tx_cfg.v" "%RTL%\udp_tx_frame.v" "%RTL%\tx_arb.v" ^
  "%RTL%\app_udp_pattern.v" ^
  "%MAC%\crc32_64.v" "%MAC%\mac_tx_10g.v" ^
  tb_lvl_app.v tb_lvl_frame.v tb_lvl_mac.v tb_lvl_full.v tb_pred_full.v tb_pred_overlap.v > xv_out.log 2>&1
if errorlevel 1 ( type xv_out.log & exit /b 1 )
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_out.log & exit /b 1)

set "STAGES=%*"
if "%STAGES%"=="" set "STAGES=lvl_app lvl_frame lvl_mac lvl_full pred_full pred_overlap"
for %%T in (%STAGES%) do (
  call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_%%T -s tb_%%T -log xelab_%%T.log > NUL 2>&1
  if errorlevel 1 ( echo ELAB FAIL %%T & type xelab_%%T.log & exit /b 1 )
  findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab_%%T.log > NUL
  if not errorlevel 1 (echo ERROR: implicit wire in xelab %%T: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" xelab_%%T.log & exit /b 1)
  call "%XV%\xsim.bat" tb_%%T -runall -log xsim_%%T.log > NUL 2>&1
)
echo ==================== RESULTS ====================
set "STAGES=%*"
if "%STAGES%"=="" set "STAGES=lvl_app lvl_frame lvl_mac lvl_full pred_full pred_overlap"
for %%T in (%STAGES%) do (
  echo ---- %%T ----
  findstr /C:"DONE" /C:"clk period" /C:"FRAME RATE" /C:"LINE BYTES" /C:"UTX  FRAME" /C:"MAC  FRAME" /C:"XGMII WORDS" /C:"MEAN FRAME" /C:"FRAME PERIOD" /C:"WORDS PER FRAME" /C:"WIRE RATE" /C:"PAYLOAD RATE" /C:"CYCLES PER" /C:"delta " /C:"frames measured" /C:"utx frames" /C:"dbg_tx_last" /C:"APP FRAME" xsim_%%T.log
)
exit /b 0
