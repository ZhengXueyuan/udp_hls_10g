@echo off
set HERE=%~dp0
echo HERE1=[%HERE%]
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
echo HERE2=[%HERE%]
set "TAG=%1"
echo TAG=[%TAG%]
cd /d "%HERE%\run_%TAG%"
echo CWD=[%CD%]
