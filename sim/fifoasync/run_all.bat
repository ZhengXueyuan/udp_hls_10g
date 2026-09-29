@echo off
REM ---------------------------------------------------------------------------
REM run_all.bat -- run the whole fifo_async gate: 7 positive cases + 3 mutation
REM   checks, each in its own case_<name> directory, and print a verdict table.
REM   Runs are SEQUENTIAL (Vivado sim licenses + xsim.dir locks).
REM Exit 0 = every positive case PASS_ALL and every mutant CAUGHT.
REM bat rules: ASCII only + CRLF.
REM ---------------------------------------------------------------------------
setlocal enabledelayedexpansion
set HERE=%~dp0
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set BAD=0
REM evidence freshness: the gate log must be NEWER than the sources it claims to verify.
REM Record hashes of the exact sources used (an agent may edit them between runs).
REM NOTE: ROOT must be set here too -- forgetting it makes certutil fail silently-ish
REM and the "freshness" record becomes a lie (this happened on the first try).
certutil -hashfile "%ROOT%\rtl\fifo_async.v" SHA256 > "%HERE%fingerprint.txt"
certutil -hashfile "%ROOT%\tb\tb_fifo_async.v" SHA256 >> "%HERE%fingerprint.txt"
echo run at %DATE% %TIME% >> "%HERE%fingerprint.txt"
type "%HERE%fingerprint.txt"
echo ================= fifo_async gate: positive cases =================
for %%C in (bal wrfast rdfast bound reset clkstop lat early) do (
  echo ---- case %%C
  call "%HERE%run_tb_fifo_async.bat" %%C
  if errorlevel 1 (echo CASE-%%C-FAIL & set BAD=1) else (echo CASE-%%C-PASS)
)
echo ================= fifo_async gate: mutation checks =================
REM NOTE: run_mut_rst1.bat is deliberately NOT here -- it is a probe with no verdict
REM (reset-sync depth is not observable in a zero-delay simulator; see its header).
for %%M in (run_mut_gray.bat run_mut_full.bat run_mut_empty1.bat run_mut_full1.bat run_mut_noovf.bat run_mut_pref1.bat) do (
  echo ---- %%M
  call "%HERE%%%M"
  if errorlevel 1 (echo MUT-%%M-FAIL & set BAD=1) else (echo MUT-%%M-PASS)
)
echo ===================================================================
if "!BAD!"=="1" (echo FIFO_ASYNC_GATE_ALL: FAIL & exit /b 1)
echo FIFO_ASYNC_GATE_ALL: OK
exit /b 0
