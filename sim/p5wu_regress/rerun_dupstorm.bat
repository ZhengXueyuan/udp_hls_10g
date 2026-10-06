@echo off
set "REPO_ROOT=%~dp0..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
set "P4_WORKDIR=%~dp0dupstorm_rerun"
if not exist "%P4_WORKDIR%" mkdir "%P4_WORKDIR%"
call "%REPO_ROOT%\sim\p4sim\run_tb_p4_burst.bat" 200 0 0 4000 608 dup
set "RC=%ERRORLEVEL%"
echo RERUN_DUPSTORM_EXIT=%RC%
exit /b %RC%
