@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
call "%~dp0extra\p5_wrapper\run.bat" > "%~dp0r2_log_p5_wrapper.txt" 2>&1
echo R2 p5_wrapper EXIT=!errorlevel!
call "%~dp0extra\p7b_appsplit\run.bat" > "%~dp0r2_log_p7b_appsplit.txt" 2>&1
echo R2 p7b_appsplit EXIT=!errorlevel!
call "%~dp0extra\p7b_chain\run.bat" > "%~dp0r2_log_p7b_chain.txt" 2>&1
echo R2 p7b_chain EXIT=!errorlevel!
call "%~dp0extra\p5d_multi\run.bat" main > "%~dp0r2_log_p5d_main.txt" 2>&1
echo R2 p5d_main EXIT=!errorlevel!
for %%C in (neg_wq neg_mgn neg_mgn0 known_idle_fifo) do (
  call "%~dp0extra\p5d_multi\run.bat" %%C > "%~dp0r2_log_p5d_%%C.txt" 2>&1
  echo R2 p5d_%%C EXIT=!errorlevel!
)
echo R2_BATCH_DONE
exit /b 0
