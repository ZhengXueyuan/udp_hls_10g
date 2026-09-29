@echo off
REM idiom D: if-block + ( ... & exit /b 1 ) inside one parenthesised branch
set "LOG=%~1"
findstr /C:"VRFC 10-3091] actual bit length 1 differs" "%LOG%" >NUL
if not errorlevel 1 (echo FORM-D-HIT & exit /b 1)
echo FORM-D-CLEAN
exit /b 0
