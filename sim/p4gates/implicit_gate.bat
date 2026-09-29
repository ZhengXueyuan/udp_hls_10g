@echo off
REM ===========================================================================
REM implicit_gate.bat -- canonical detector for the project trap-24 defect class:
REM   "a missing declaration silently becomes a 1-bit net" (implicit net).
REM
REM usage:  implicit_gate.bat <logfile> [label]
REM exit :  0 = clean    1 = implicit-net signature found    2 = log file missing
REM
REM MEASURED against Vivado 2025.2 on 2026-09-29.  See
REM   _proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md   (raw repro logs + controls)
REM
REM WHY THE OLD KEYWORD IS GONE
REM   Before 2025.2 the signature was the phrase "implicitly declared".
REM   Vivado 2025.2 no longer prints that phrase ANYWHERE (grep count = 0 on
REM   every log measured), so a gate that greps it can never fire again.
REM
REM WHAT 2025.2 PRINTS INSTEAD (two different forms, two different detectors)
REM   form A: undeclared net used as a PORT CONNECTION  (the silent truncation)
REM     xvlog : NOTHING AT ALL  (exit code 0, empty log -- this is the trap)
REM     xelab : WARNING: [VRFC 10-3091] actual bit length 1 differs from
REM             formal bit length 64 for port 'q'      <-- only detector here
REM     synth : INFO: [Synth 8-11241] undeclared symbol 'mid', assumed
REM             default net type 'wire'                <-- only detector here
REM   form B: undeclared identifier inside an EXPRESSION
REM     xvlog : ERROR: [VRFC 10-2989] 'pay_sel' is not declared (fatal)
REM     synth : ERROR: [Synth 8-36] 'pay_sel' is not declared (fatal)
REM
REM KEYS DELIBERATELY *NOT* USED (measured too broad -> false positives)
REM   VRFC 10-3091 is used ONLY in its NARROW form
REM     "VRFC 10-3091] actual bit length 1 differs from formal bit length"
REM   because the bare key was measured to fire on BENIGN unsized literals:
REM   board/util_gmii_to_rgmii.v lines 188/189/190/192/203/207/216/220/232/
REM   234/235/245/247/248 are .CE(1)/.D1(1)/.D2(0)/.R(0)/.S(0) -> "actual bit
REM   length 32 differs from formal bit length 1" x14 on EVERY xelab of the
REM   default (K7) config.  An implicit net is ALWAYS 1 bit, so "actual = 1"
REM   is the exact trap-24 signature and no equal-width case can match it.
REM   VRFC 10-3645 "port ... remains unconnected" is the xelab-side twin of
REM   8-7129 and fires 20x on the CLEAN real P6e design -> excluded too.
REM   8-7129 "unconnected or has no load"  fires on ANY unused port, including
REM          legitimate ones (measured on a benign control design)
REM   8-6014 "Unused sequential element ... removed"   benign optimisation notice
REM   8-3917 "port ... driven by constant"             benign optimisation notice
REM   "implicitly declared" is kept ONLY for pre-2025.2 tools; it is dead in 2025.2.
REM ===========================================================================
setlocal
set LOG=%~1
set LABEL=%~2
if "%LABEL%"=="" set LABEL=IMPLICIT-GATE
if "%~1"=="" (echo %LABEL%: USAGE implicit_gate.bat ^<logfile^> [label] & exit /b 2)
if not exist "%LOG%" (echo %LABEL%: LOG-MISSING %LOG% & exit /b 2)
set KEYS=/I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared"
findstr %KEYS% "%LOG%" >NUL 2>&1
if errorlevel 1 (
  echo %LABEL%: OK  no implicit-net signature in %LOG%
  exit /b 0
)
echo %LABEL%: IMPLICIT-NET-FAIL  log=%LOG%
findstr %KEYS% "%LOG%"
exit /b 1
