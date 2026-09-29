@echo off
REM run_tb_p7a_counters.bat -- P7a unit gate (PRBS chain + counters + atomic snapshot)
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\sim\run_tb_p7a_counters.bat'
REM
REM   Self-locating: everything is relative to %~dp0, and a missing source file is a
REM   hard refusal (exit 97) rather than a silent compile of somebody else's tree.
REM   Exit codes: 0 = gate PASS, 1 = gate FAIL, 97 = precondition refused.
REM
REM   Reads all RTL from ..\rtl  (the same files the bitstream is built from).
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=..\rtl

for %%F in (p7a_counters.v p7a_tgl_sync.v p7a_vio_ctrl.v p7a_ref_bucket.v p7a_bit_sync.v gt_10gbr_prbs_any.v gt_10gbr_example_stimulus_64b66b_async.v gt_10gbr_example_checking_64b66b_async.v gt_10gbr_example_reset_sync.v) do (
    if not exist "%RTL%\%%F" (echo [PATHGUARD FAIL] missing %RTL%\%%F & exit /b 97)
)
if not exist tb_p7a_counters.v (echo [PATHGUARD FAIL] missing tb_p7a_counters.v & exit /b 97)

if exist xsim.dir rmdir /s /q xsim.dir
del /q xvlog.txt xelab.txt xsim_run.txt 2>nul

call %XV%\xvlog.bat -i %RTL% ^
    %RTL%\p7a_counters.v %RTL%\p7a_tgl_sync.v %RTL%\p7a_vio_ctrl.v %RTL%\p7a_bit_sync.v ^
    %RTL%\p7a_ref_bucket.v %RTL%\gt_10gbr_prbs_any.v ^
    %RTL%\gt_10gbr_example_stimulus_64b66b_async.v %RTL%\gt_10gbr_example_checking_64b66b_async.v ^
    %RTL%\gt_10gbr_example_reset_sync.v tb_p7a_counters.v > xvlog.txt 2>&1
echo ---- xvlog exit=%ERRORLEVEL% ----
findstr /I /C:"implicitly" xvlog.txt >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"implicitly" xvlog.txt & exit /b 1)
findstr /C:"10-3091" xvlog.txt >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"10-3091" xvlog.txt & exit /b 1)
findstr /I /C:"ERROR" xvlog.txt >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog.txt & exit /b 1)

call %XV%\xelab.bat -s tb_p7a work.tb_p7a_counters > xelab.txt 2>&1
echo ---- xelab exit=%ERRORLEVEL% ----
findstr /I /C:"ERROR" xelab.txt >NUL && (echo XELAB-ERROR-FAIL & findstr /I /C:"ERROR" xelab.txt & exit /b 1)

call %XV%\xsim.bat tb_p7a -R > xsim_run.txt 2>&1
echo ---- xsim exit=%ERRORLEVEL% ----
type xsim_run.txt

findstr /C:"GATE PASS" xsim_run.txt >NUL
if %ERRORLEVEL% NEQ 0 (
    echo GATE-FAIL: no "GATE PASS" in xsim_run.txt
    exit /b 1
)
echo GATE-OK
exit /b 0
