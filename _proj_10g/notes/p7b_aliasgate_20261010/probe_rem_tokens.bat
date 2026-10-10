@echo off
echo [probe] A-before
REM variant A: a comment mentioning %~dp0 (the script's own directory)
echo [probe] A-after
REM variant B: a comment mentioning 'for %%I in (x) do set'
echo [probe] B-after
REM variant C: a comment mentioning the literal '%~fI'
echo [probe] C-after
echo [probe] DONE
