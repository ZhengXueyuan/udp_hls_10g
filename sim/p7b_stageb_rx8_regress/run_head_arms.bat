@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
for %%G in (p5_pattern_head p5_wrapper_head) do (
  call "%~dp0extra\%%G\run.bat" > "%~dp0head_log_%%G.txt" 2>&1
  echo HEAD %%G EXIT=!errorlevel!
)
for %%C in (neg_wq neg_mgn neg_mgn0 known_idle_fifo) do (
  call "%~dp0extra\p5d_multi_head\run.bat" %%C > "%~dp0head_log_p5d_%%C.txt" 2>&1
  echo HEAD p5d_%%C EXIT=!errorlevel!
)
echo HEAD_ARMS_DONE
exit /b 0
