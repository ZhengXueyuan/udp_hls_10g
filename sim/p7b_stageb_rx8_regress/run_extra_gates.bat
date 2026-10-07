@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
for %%G in (p5_pattern_mutB p5_pattern_mutS p5_pattern_head p5_status p5_wrapper) do (
  call "%~dp0extra\%%G\run.bat" > "%~dp0extra_log_%%G.txt" 2>&1
  echo ARM %%G EXIT=!errorlevel!
)
echo EXTRA_GATES_DONE
exit /b 0
