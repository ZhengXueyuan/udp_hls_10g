@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM run_sysmon.bat - read the on-chip System Monitor (die temp + VCCINT/VCCAUX/VCCBRAM)
REM over JTAG. No design change, no bitstream change, no extra FFs, so it cannot
REM perturb the phenomenon being measured.
REM
REM WHY THIS EXISTS AS A .bat: on 2026-09-27 all 8 v4 rounds reported
REM "sysmon read failed" because tools/board_round.sh passed the whole Windows
REM command line to `cmd //c "..."` with DOUBLE quotes plus variable expansion --
REM MSYS2 path conversion mangled it. This is the same root cause as the
REM documented pit (double quotes + command substitution). The proven-correct
REM pattern is a .bat with hardcoded full paths, invoked from Git Bash with
REM SINGLE quotes. tools/sysmon_read.tcl itself was verified working separately.
REM
REM The XADC MIN/MAX latches reset on reconfiguration, so because every measurement
REM round starts with a reprogram, current+min+max bracket exactly that round.
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
REM Delete first so the self-check below can only ever read THIS run's log.
del /q vivado_sysmon.log 2>NUL
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -log vivado_sysmon.log -nojournal -source %REPO_ROOT%\tools\sysmon_read.tcl
findstr /C:"SYSMON T=" vivado_sysmon.log > NUL || (echo SYSMON_READ_FAILED & exit /b 1)
exit /b 0
