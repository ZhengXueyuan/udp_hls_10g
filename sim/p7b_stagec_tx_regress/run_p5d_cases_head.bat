@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
for %%C in (neg_wq neg_mgn neg_mgn0 known_idle_fifo) do (
  call "%~dp0extra_head\p5d_multi\run.bat" %%C > "%~dp0head_log_p5d_%%C.txt" 2>&1
  echo HEAD p5d %%C EXIT=!errorlevel!
)
echo P5D_HEAD_CASES_DONE
exit /b 0
