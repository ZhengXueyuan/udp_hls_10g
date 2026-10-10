@echo off
setlocal
set "F=%~dp0..\..\..\simliasgate\_selftest
eg_stdout.txt"
echo F=%F%
if not exist "%F%" (echo FILE-MISSING & exit /b 3)
for /f "tokens=3" %%N in ('find /c "REVERSED" "%F%"') do echo TOKENS3=%%N
echo PROBE-DONE
