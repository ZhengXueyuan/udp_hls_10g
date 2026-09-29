@echo off
REM idiom C: detect through a PIPE (exit code comes from the LAST stage)
set "LOG=%~1"
findstr /C:"VRFC 10-3091" "%LOG%" | findstr /C:"actual bit length 1 differs" >NUL
echo PIPE-RC=%ERRORLEVEL%
if errorlevel 1 (echo FORM-C-HIT & exit /b 1)
echo FORM-C-CLEAN
exit /b 0
