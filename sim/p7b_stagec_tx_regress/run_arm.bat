@echo off
REM Stage C regression: run the MIRROR matrix entry, chain gate only.
REM The mirror copy of p4env.bat self-locates -> REPO_ROOT = mirror root.
setlocal
call "%~dp0mirror\sim\p4gates\run_matrix_p4dfix.bat" -only chain
set RC=%errorlevel%
echo ARM_MIRROR_EXIT=%RC%
exit /b %RC%
