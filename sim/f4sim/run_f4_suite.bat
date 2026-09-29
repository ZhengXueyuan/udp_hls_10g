@echo off
REM F4 full suite: main gate x5 variants + A/B + bitexact + mac regress x3 + F4-2 probe x3 + chain x2
setlocal
set R=D:\repo\XCKU5PMini\udp_hls_10g
set P=%R%\sim\f4sim
echo ########## F4 GATE (main stimulus: 0..64 payload sweep + phase sweep + nodrain) ##########
for %%M in (new old mut nogate mutcrs) do call "%P%\run_tb_f4_mac.bat" %%M > "%P%\F4_GATE_%%M.log" 2>&1
call "%P%\run_f4_ab.bat" new  > "%P%\AB_new_vs_old.log" 2>&1
call "%P%\run_f4_bitexact.bat" > "%P%\BITEXACT.log" 2>&1
echo ########## F4-2 PROBE (mini stimulus: TERM-wait vs new-frame phase) ##########
set STIM=f2probe
for %%M in (old new mut nogate) do call "%P%\run_tb_f4_mac.bat" %%M > "%P%\PROBE_%%M.log" 2>&1
set STIM=
echo ########## MAC REGRESS ##########
for %%M in (NOSTALL STALL STALL2) do call "%P%\run_tb_mac_f4regress.bat" %%M > "%P%\MACREG_%%M.log" 2>&1
echo ########## CHAIN ##########
call "%R%\sim\f4chain\run_tb_f4_chain.bat" new > "%R%\sim\f4chain\CHAIN_new.log" 2>&1
call "%R%\sim\f4chain\run_tb_f4_chain.bat" old > "%R%\sim\f4chain\CHAIN_prefix_rtl.log" 2>&1
echo ########## VERDICT (tripwire: running a gate is not judging it) ##########
set PY=C:\Users\zhxue\anaconda3\python.exe
%PY% "%P%\f4_verdict.py" --stim main
set V1=%errorlevel%
%PY% "%P%\f4_verdict.py" --stim f2probe
set V2=%errorlevel%
if "%V1%%V2%"=="00" goto :verdict_ok
echo F4-SUITE-VERDICT: FAIL ^(main=%V1% probe=%V2%^)
exit /b 1
:verdict_ok
echo F4-SUITE-VERDICT: PASS (positive PASS + all four mutants caught)
echo SUITE DONE
exit /b 0
