@echo off
REM run_lint_p7a.bat -- elaboration-level lint for EVERY P7a rtl file, including
REM   p7a_top.v (which the unit gate cannot analyze because it needs the VIO and
REM   GT IP modules, so it never appears in the gate's xvlog run).
REM
REM   Hard failures, same launcher as board\run_lint_p6e.bat:
REM     "8-11241/10-3091"  -> an undeclared net (silently becomes a 1-bit wire)
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

REM ---- P7B: the IP sources p7a_top.v needs in order to ELABORATE ----
REM   gt_10gbr  = the IP's own verilog (synth wrapper + hdl helper modules)
REM   vio_p7a   = the synthesis STUB (the VIO core is not delivered as RTL)
set IP=%~dp0..\vivado_prj\p7a_prj.gen\sources_1\ip
set GTHDL=%IP%\gt_10gbr\hdl

REM ---- alias-direction face (P7b aliasgate 2026-10-10) ----------------------
REM   A NEW face, not a new key: the five keys used above are structurally
REM   blind to an UNDRIVEN net (measured 2026-10-10 -- the sibling entry
REM   board\run_lint_p6e.bat compiles exactly the buggy wrapper branch and
REM   still prints LINT-OK).  It runs BEFORE this entry's own preconditions on
REM   purpose: they refuse (97) on a box without p7a_prj, and a face placed
REM   behind them would never execute here -- residency that is not real.
REM   Self-contained (text only, ~2 s).  exit 1 = a reversed/multi-driven alias.
call "%~dp0..\..\sim\aliasgate\run_aliasgate.bat" || exit /b 1

if not exist "%RTL%\p7a_top.v" (echo [PATHGUARD FAIL] missing p7a_top.v & exit /b 97)
if not exist "%RTL%\p7a_counters.v" (echo [PATHGUARD FAIL] missing p7a_counters.v & exit /b 97)
REM   the xelab face needs the generated IP; refuse (97) rather than pass blind
if not exist "%IP%\gt_10gbr\hdl\gtwizard_ultrascale_v1_7_gtwiz_reset.v" (echo [PATHGUARD FAIL] missing gt_10gbr hdl sources -- build p7a_prj first & exit /b 97)
if not exist "%IP%\vio_p7a\vio_p7a_stub.v" (echo [PATHGUARD FAIL] missing vio_p7a_stub.v -- build p7a_prj first & exit /b 97)

if not exist "%HERE%lint" mkdir "%HERE%lint"
cd /d "%HERE%lint"
del /q files.f xvlog.txt xelab.txt >nul 2>&1

echo %RTL%\p7a_top.v> files.f
for %%F in (p7a_counters.v p7a_tgl_sync.v p7a_bit_sync.v p7a_vio_ctrl.v p7a_ref_bucket.v clk_gen_p6b.v gt_10gbr_prbs_any.v gt_10gbr_example_stimulus_64b66b_async.v gt_10gbr_example_checking_64b66b_async.v gt_10gbr_example_reset_sync.v) do echo %RTL%\%%F>> files.f
dir /b /s "%IP%\gt_10gbr\synth\*.v" >> files.f
dir /b /s "%GTHDL%\*.v" >> files.f
echo %IP%\vio_p7a\vio_p7a_stub.v >> files.f
echo ---- files.f ----
type files.f

call %XV%\xvlog.bat -work xil_defaultlib -i %RTL% -f files.f > xvlog.txt 2>&1
echo ---- xvlog exit=%ERRORLEVEL% ----
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog.txt >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog.txt & exit /b 1)
findstr /C:"10-3091" xvlog.txt >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"10-3091" xvlog.txt & exit /b 1)
findstr /I /C:"ERROR" xvlog.txt >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog.txt & exit /b 1)
REM
REM ---- xelab face (P7B): the PORT-CONNECTION form of trap 24 prints NOTHING
REM   in xvlog (exit 0, empty log), so xvlog alone structurally cannot catch it.
REM   Measured ~23 s.  vio_p7a_stub.v is a black box: we lint OUR rtl, not the
REM   VIO core internals.
call %XV%\xvlog.bat -work xil_defaultlib -i "%GTHDL%" "%XV%\..\data\verilog\src\glbl.v" >> xvlog.txt 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver -L secureip xil_defaultlib.p7a_top xil_defaultlib.glbl -s lint_p7a -log xelab.txt > NUL 2>&1
if errorlevel 1 (echo XELAB-FAIL & type xelab.txt & exit /b 1)
REM   positive evidence: an empty/absent xelab log must NOT read as clean
findstr /C:"Built simulation snapshot" xelab.txt >NUL || (echo XELAB-NO-SNAPSHOT & type xelab.txt & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab.txt >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab.txt & exit /b 1)
echo LINT-OK: no implicit nets, no width mismatch, no errors
exit /b 0
