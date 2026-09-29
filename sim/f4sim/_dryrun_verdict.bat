@echo off
REM dry-run: 只跑套件尾部的 VERDICT 段 (复用已有日志), 证明 exit 码能传播
setlocal
set R=D:\repo\XCKU5PMini\udp_hls_10g
set P=%R%\sim\f4sim
set PY=C:\Users\zhxue\anaconda3\python.exe
%PY% "%P%\f4_verdict.py" --stim main > "%P%\_dry_main.txt" 2>&1
set V1=%errorlevel%
%PY% "%P%\f4_verdict.py" --stim f2probe > "%P%\_dry_probe.txt" 2>&1
set V2=%errorlevel%
if "%V1%%V2%"=="00" goto :verdict_ok
echo F4-SUITE-VERDICT: FAIL ^(main=%V1% probe=%V2%^)
exit /b 1
:verdict_ok
echo F4-SUITE-VERDICT: PASS (positive PASS + all four mutants caught)
exit /b 0
