@echo off
REM run_synth.bat -- M1 synthesis checkpoint (synth-only; no impl; no bitstream)
REM   usage: run_synth.bat pre   = tree BEFORE the M1 edits (same-flow control arm)
REM          run_synth.bat m1    = tree AFTER the M1 edits
REM   -tclargs must be the LAST vivado argument (it greedily eats later flags).
REM   gate: stdout must contain M1SYNTH_DONE and M1SYNTH_WNS.
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %~dp0
set ARM=%1
if "%ARM%"=="" set ARM=m1
call %XV%\vivado.bat -mode batch -source synth_only_ku5p.tcl -nojournal -nolog -tclargs %ARM% > synth_stdout_%ARM%.txt 2>&1
findstr /C:"M1SYNTH_DONE" synth_stdout_%ARM%.txt >NUL || (echo M1SYNTH-FAIL & exit /b 1)
findstr /C:"M1SYNTH_WNS" synth_stdout_%ARM%.txt >NUL || (echo M1SYNTH-NO-WNS & exit /b 1)
findstr /C:"M1SYNTH_WNS" /C:"M1SYNTH_WHS" /C:"M1SYNTH_MIR_PINS" /C:"M1SYNTH_MIR_IMPORTED" synth_stdout_%ARM%.txt
exit /b 0
