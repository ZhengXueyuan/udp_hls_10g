@echo off
REM run_s5_pcs64.bat -- rerun ONLY the PCS/PMA-64 probe (stale impl-only xdc removed).
setlocal
cd /d %~dp0
set P7B_ONLY=pcs64
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set LOG=..\logs\s5_pcs64
call %VIV% -mode batch -source s5_build.tcl -log %LOG%.log -journal %LOG%.jou > %LOG%_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"S5_ONLY" /C:"S5_REMOVE_STALE" /C:"S5_IBUFDS" /C:"S5_IMPL_ONLY" /C:"S4_VERDICT" /C:"S4_LICLINE" /C:"S4_TIMING " /C:"S4_UTIL " /C:"S4_BIT " /C:"S4_SYNTH_STATUS" /C:"S4_IMPL_STATUS" /C:"S4_IMPL_PROGRESS" /C:"bitstream generation is not permitted" /C:"require licenses greater than" /C:"Fatal" /C:"ERROR:" ..\logs\s5_pcs64_stdout.txt
exit /b %RC%
