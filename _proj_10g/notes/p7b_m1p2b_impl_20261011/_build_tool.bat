@echo off
REM _build_tool.bat -- local (mingw) compile of the PC-side mirror dump tool for --selftest
REM   (deployment recipe = _proj_10g/notes/p7b_affinity/BUILD.md; this one is Windows-only)
REM   NOTE (2026-10-11, measured): g++ needs C:\msys64\mingw64\bin on PATH, otherwise
REM   cc1plus.exe dies silently ("libmpfr-6.dll not found", EMPTY stderr, RC=1) --
REM   the classic silent-failure shape; do not remove the PATH line below.
setlocal
set G=C:\msys64\mingw64\bin\g++.exe
set SRC=D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\p7b_biz\p7b_mir_dump.cpp
set OUT=%~dp0mir_dump_selftest.exe
set PATH=C:\msys64\mingw64\bin;%PATH%
"%G%" -O2 -pthread -o "%OUT%" "%SRC%"
echo GPP_RC=%ERRORLEVEL%
if exist "%OUT%" (echo GPP_EXE_OK) else (echo GPP_EXE_MISSING)
"%OUT%" --selftest
echo SELFTEST_RC=%ERRORLEVEL%

