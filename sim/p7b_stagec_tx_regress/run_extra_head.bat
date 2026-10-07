@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
for %%G in (p5_wrapper p5_pattern) do (
  call "%~dp0extra_head\%%G\run.bat" > "%~dp0head_log_%%G.txt" 2>&1
  echo HEAD %%G EXIT=!errorlevel!
)
echo HEAD_EXTRA_DONE
exit /b 0
