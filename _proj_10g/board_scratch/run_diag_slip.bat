@echo off
REM run_diag_slip.bat -- P7a post-negctrl-A diagnostic (VIO only; DOES NOT PROGRAM)
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
if not exist logs mkdir logs
call %VIV% -mode batch -source diag_slip.tcl -log logs\diag_slip.log -journal logs\diag_slip.jou > logs\diag_slip_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
type logs\diag_slip_stdout.txt
exit /b %RC%
