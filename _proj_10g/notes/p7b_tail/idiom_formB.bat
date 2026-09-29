@echo off
REM idiom B: findstr >NUL && echo NOTE   [print-only = the dumb gate]
set "LOG=%~1"
findstr /C:"VRFC 10-3091] actual bit length 1 differs" "%LOG%" >NUL && echo FORM-B-NOTE
echo FORM-B-REACHED-END
exit /b 0
