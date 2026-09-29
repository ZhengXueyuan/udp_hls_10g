@echo off
REM run_lint_p7a.bat -- elaboration-level lint for EVERY P7a rtl file, including
REM   p7a_top.v (which the unit gate cannot analyze because it needs the VIO and
REM   GT IP modules, so it never appears in the gate's xvlog run).
REM
REM   Hard failures, same launcher as board\run_lint_p6e.bat:
REM     "implicitly"  -> an undeclared net (silently becomes a 1-bit wire)
REM     "10-3091"     -> bit-width mismatch
REM     ERROR         -> any xvlog error
REM   Exit: 0 = LINT-OK, 1 = a check fired, 97 = precondition refused.
REM
REM   Paths are absolute (from %~dp0) so the cd into lint\ cannot break them.
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\tcl\run_lint_p7a.bat'
setlocal
set HERE=%~dp0
set RTL=%~dp0..\rtl
set XV=C:\AMDDesignTools\2025.2\Vivado\bin

if not exist "%RTL%\p7a_top.v" (echo [PATHGUARD FAIL] missing p7a_top.v & exit /b 97)
if not exist "%RTL%\p7a_counters.v" (echo [PATHGUARD FAIL] missing p7a_counters.v & exit /b 97)

if not exist "%HERE%lint" mkdir "%HERE%lint"
cd /d "%HERE%lint"
del /q files.f xvlog.txt >nul 2>&1

echo %RTL%\p7a_top.v> files.f
for %%F in (p7a_counters.v p7a_tgl_sync.v p7a_bit_sync.v p7a_vio_ctrl.v p7a_ref_bucket.v clk_gen_p6b.v gt_10gbr_prbs_any.v gt_10gbr_example_stimulus_64b66b_async.v gt_10gbr_example_checking_64b66b_async.v gt_10gbr_example_reset_sync.v) do echo %RTL%\%%F>> files.f
echo ---- files.f ----
type files.f

call %XV%\xvlog.bat -i %RTL% -f files.f > xvlog.txt 2>&1
echo ---- xvlog exit=%ERRORLEVEL% ----
findstr /I /C:"implicitly" xvlog.txt >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"implicitly" xvlog.txt & exit /b 1)
findstr /C:"10-3091" xvlog.txt >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"10-3091" xvlog.txt & exit /b 1)
findstr /I /C:"ERROR" xvlog.txt >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog.txt & exit /b 1)
echo LINT-OK: no implicit nets, no width mismatch, no errors
exit /b 0
