@echo off
REM idiom A: findstr >NUL && (echo MARK & findstr ... & exit /b 1)   [the repo's hard-fail idiom]
set "LOG=%~1"
set KEYS=/I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"Synth 8-11241"
findstr %KEYS% "%LOG%" >NUL && (echo FORM-A-HIT & findstr %KEYS% "%LOG%" & exit /b 1)
echo FORM-A-CLEAN
exit /b 0
