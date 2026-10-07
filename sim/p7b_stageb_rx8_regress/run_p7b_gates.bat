@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
for %%G in (p7b_chain p7b_appsplit) do (
  pushd "%~dp0extra\%%G"
  call run_tb_%%G.bat > "%~dp0p7b_log_%%G.txt" 2>&1
  echo P7B %%G EXIT=!errorlevel!
  popd
)
echo P7B_GATES_DONE
exit /b 0
