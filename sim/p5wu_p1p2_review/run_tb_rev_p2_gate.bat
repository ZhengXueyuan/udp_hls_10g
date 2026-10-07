@echo off
REM run_tb_rev_p2_gate.bat -- adversarial-review TB for the P2 progress gate (wu_act)
REM   arms: u_dut = rtl/app_ctrl.v worktree (fixed) / u_base = git HEAD file (renamed module)
REM   dedicated work dir sim\p5wu_p1p2_review\run
set "REPO_ROOT=%~dp0..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  exit /b 1
)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set SIM=%REPO_ROOT%\sim\p5wu_p1p2_review\run

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\fifo_sync.v ^
  %RTL%\app_ctrl.v ^
  %REPO_ROOT%\sim\p5wu_p1p2\app_ctrl_base.v ^
  %~dp0tb_rev_p2_gate.v > xvlog_rev.log 2>&1 || (type xvlog_rev.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_rev_p2_gate -s tb_rev_p2_gate -log xelab_rev.log > NUL 2>&1 || (type xelab_rev.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_rev.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_rev.log & exit /b 1)

call %XV%\xsim.bat tb_rev_p2_gate -runall -log xsim_rev.log > NUL 2>&1 || (type xsim_rev.log & exit /b 1)

type xsim_rev.log
findstr /C:"REV_P2_GATE OK" xsim_rev.log > NUL
if errorlevel 1 (echo REV_P2_GATE FAIL & exit /b 1)
echo REV_P2_GATE PASS
