@echo off
REM run_build_p7b_ku5p.bat - P7b 10G front end (official xxv_ethernet PCS + our own
REM   64-bit XGMII MAC) merged with the 64-bit datapath.  THIS SCRIPT DOES NOT
REM   PROGRAM THE BOARD (no program_hw_devices, no QSPI).
REM   from Git Bash: cmd //c 'board\run_build_p7b_ku5p.bat'
setlocal
cd /d %~dp0
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
REM ---- pre-build archive (global lesson #54) ---------------------------------
REM   build_p7b_ku5p.tcl does `create_project -force` => impl_1/ and synth_1/
REM   are WIPED at the very start of every build.  Anything not copied out
REM   BEFORE the vivado call is gone forever (that is exactly how the
REM   "FF +142 came from where" question became unjudgeable on the previous
REM   round).  This block is the machine-checked version of "remember to
REM   archive": it runs on EVERY invocation, before vivado starts.
REM   Output: _proj_10g\notes\p7b_build_archive\<stamp>\  +  SHA256SUMS.txt
REM   Best effort: a failure here does NOT block the build, but it prints
REM   ARCHIVE_* lines that are easy to grep afterwards.
set REPO=%~dp0..
set IMPL=%REPO%\vivado_prj\p7b_ku5p_prj.runs\impl_1
set SYN=%REPO%\vivado_prj\p7b_ku5p_prj.runs\synth_1
set ARCROOT=%REPO%\_proj_10g\notes\p7b_build_archive
set STAMP=
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>NUL') do set STAMP=%%i
if "%STAMP%"=="" set STAMP=nostamp
set ARCDIR=%ARCROOT%\%STAMP%
if not exist "%IMPL%\wrapper_p4.bit" (
  echo ARCHIVE_SKIP no previous bitstream at "%IMPL%\wrapper_p4.bit"
  goto :arc_skip
)
mkdir "%ARCDIR%" 2>NUL
if not exist "%ARCDIR%" (
  echo ARCHIVE_FAIL mkdir "%ARCDIR%"
  goto :arc_skip
)
copy /Y "%IMPL%\wrapper_p4_timing_summary_routed.rpt" "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_utilization_placed.rpt"    "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_clock_utilization_routed.rpt" "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_control_sets_placed.rpt"   "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_drc_routed.rpt"            "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_power_routed.rpt"          "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_route_status.rpt"          "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4_routed.dcp"                "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\wrapper_p4.bit"                       "%ARCDIR%\" >NUL 2>&1
copy /Y "%IMPL%\runme.log"                            "%ARCDIR%\runme_impl_1.log" >NUL 2>&1
copy /Y "%SYN%\wrapper_p4_utilization_synth.rpt"      "%ARCDIR%\" >NUL 2>&1
copy /Y "%SYN%\wrapper_p4.dcp"                        "%ARCDIR%\wrapper_p4_synth.dcp" >NUL 2>&1
copy /Y "%SYN%\runme.log"                             "%ARCDIR%\runme_synth_1.log" >NUL 2>&1
copy /Y "%~dp0p7b_ku5p_timing.rpt"                    "%ARCDIR%\" >NUL 2>&1
copy /Y "%~dp0p7b_ku5p_util.rpt"                      "%ARCDIR%\" >NUL 2>&1
copy /Y "%~dp0p7b_ku5p_drc.rpt"                       "%ARCDIR%\" >NUL 2>&1
copy /Y "%~dp0p7b_ku5p_clkinteract.rpt"               "%ARCDIR%\" >NUL 2>&1
copy /Y "%~dp0p7b_ku5p_stdout.txt"                    "%ARCDIR%\" >NUL 2>&1
powershell -NoProfile -Command "Get-ChildItem -File -LiteralPath '%ARCDIR%' | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() + ' *' + $_.Name } | Set-Content -Encoding Ascii -LiteralPath '%ARCDIR%\SHA256SUMS.txt'" >NUL 2>&1
if exist "%ARCDIR%\SHA256SUMS.txt" (echo ARCHIVE_SHA256_OK) else (echo ARCHIVE_SHA256_MISSING)
set ARCN=0
for %%F in ("%ARCDIR%\*") do set /a ARCN+=1
echo ARCHIVE_DONE %STAMP% files=%ARCN% dir=%ARCDIR%
:arc_skip

if not exist p7b_ku5p_stdout.txt del /q p7b_ku5p_stdout.txt
call "%VV%" -mode batch -source "%~dp0build_p7b_ku5p.tcl" -nojournal -nolog > p7b_ku5p_stdout.txt 2>&1
echo BUILD_EXIT=%ERRORLEVEL%

REM ---- hard gates (a hit is a FAILURE, not a note) --------------------------
findstr /I /C:"12-4739" p7b_ku5p_stdout.txt >NUL && (echo DROPPED-CONSTRAINT-FAIL & findstr /I /C:"12-4739" p7b_ku5p_stdout.txt)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" p7b_ku5p_stdout.txt >NUL && (echo IMPLICIT-NET-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" p7b_ku5p_stdout.txt)
findstr /I /C:"NSTD-1" /C:"UCIO-1" /C:"AVAL-326" /C:"Opt 31-155" /C:"Opt 31-67" /C:"Route 35-7" p7b_ku5p_stdout.txt >NUL && (echo DRC-KEY-FAIL & findstr /I /C:"NSTD-1" /C:"UCIO-1" /C:"AVAL-326" /C:"Opt 31-155" /C:"Opt 31-67" /C:"Route 35-7" p7b_ku5p_stdout.txt)

REM ---- readings (must be present in the log, not merely in a report file) ---
findstr /B /C:"P7B_WNS" /C:"P7B_WHS" /C:"P7B_WPWS" /C:"P7B_BIT_EXISTS" /C:"P7B_VERDICT" /C:"P7B_CONVERGED_AT_ROUND" /C:"P7B_IS_LOCKED_POSTGEN" /C:"P7B DONE" p7b_ku5p_stdout.txt

if not exist "..\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4.bit" (echo NO-BITSTREAM & exit /b 1)
echo BITSTREAM-OK
exit /b 0
