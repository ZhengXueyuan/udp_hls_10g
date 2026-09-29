@echo off
setlocal
rem ===========================================================================
rem run_legacy_tb_rxclass.bat -- cross-check v2 against the EXISTING verified gate
rem   (tb/tb_rx_classify.v + the independent cycle model in
rem    tools/gen_stim_p4_rxclass.py).
rem   That gate judges the ACCEPTED-BEAT LINE SEQUENCE (content), not cycle
rem   numbers, so a content-preserving throughput fix must still PASS it.
rem   DUT here = legacy\rx_classify.v, which is the v2 source with the module
rem   name rewritten (module rx_classify_v2 -> module rx_classify) so the
rem   unmodified legacy TB binds to it. No repo file is modified; all products
rem   land under legacy\.
rem   NOTE: ASCII only (project bat pitfall). Run from the repo root as
rem     cmd //c '_proj_10g\p7b_rxcls\sim\run_legacy_tb_rxclass.bat'
rem ===========================================================================
set REPO_ROOT=%~dp0..\..\..
for %%I in ("%REPO_ROOT%") do set REPO_ROOT=%%~fI
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  exit /b 1
)
cd /d %~dp0legacy
if defined P7B_LEGACY_DIR cd /d %P7B_LEGACY_DIR%
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib rx_classify.v %REPO_ROOT%\rtl\fifo_sync.v %REPO_ROOT%\tb\tb_rx_classify.v > xvlog_legacy.log 2>&1 || (type xvlog_legacy.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_rx_classify -s tb_rx_classify -log xelab_legacy.log > NUL 2>&1 || (type xelab_legacy.log & exit /b 1)
call %XV%\xsim.bat tb_rx_classify -runall -log xsim_legacy_nostall.log > NUL 2>&1
call %XV%\xsim.bat tb_rx_classify -runall -testplusarg STALL -log xsim_legacy_stall.log > NUL 2>&1
call %XV%\xsim.bat tb_rx_classify -runall -testplusarg HARD  -log xsim_legacy_hard.log  > NUL 2>&1
echo [LEGACY CROSSCHECK] 3 modes run; products in this dir (resp_rc_*.memh)
exit /b 0
