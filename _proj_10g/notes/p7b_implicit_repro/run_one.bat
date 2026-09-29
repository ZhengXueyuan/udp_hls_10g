@echo off
REM Caller must cd into the case directory first.
REM NOTE: the redirect target must NOT be "xvlog.log" -- that is the launcher's
REM own default -log name and the two handles collide (Common 17-183).
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call "%XV%\xvlog.bat" %~1 > xv_case.log 2>&1
echo XVLOG_RC=%errorlevel%
endlocal
