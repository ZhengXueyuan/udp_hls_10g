@echo off
REM ============================================================
REM p5close -- P5c-T2 directed falsification gate for the two TCP
REM   close-semantics defects (xsim, unit level: tcp_tx_frame + tcb + tcp_cam)
REM
REM   G1 (tb_close_g1.v): FIN sent and not ACKed, RTO, svc rewinds
REM     snd_nxt to fin_seq; on the SINGLE "ring drain beat" (ring_eval and
REM     not ring_start) an ack_req pulse steals the ackq write, so the FIN
REM     re-push entry is lost, fin_retx_pend stays 1 and retx_active drops;
REM     then snd_nxt equals snd_una, so the RTO arming condition is always false,
REM     no further svc ever happens and the FIN is never retransmitted.
REM     GATE PASS means FIN frame count is 2 or more (close can complete).
REM
REM   G9 (tb_close_g9.v): blocked (epoch[0] = 15, i.e. 16 svc sessions with no
REM     snd_una progress) while the FIN is in flight, so svc_rewind = 0 (no
REM     rewind) while retx_hi = fin_seq is BELOW snd_nxt = fin_seq+1, so
REM     ring_delta underflows to 0xFFFFFFFF, ring_start = 1 and the DUT
REM     replays the retransmit ring at 1460 B per frame (stale ACKed payload).
REM     GATE PASS means no 1460B data frame after the FIN.
REM
REM Usage: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5close\run_tb_tcp_close.bat'
REM Exit : 0 = both gates PASS (fix present)
REM        1 = at least one gate FAIL (defect reproduced on current RTL)
REM        2 = xvlog/xelab/xsim error, or verdict line missing
REM
REM Read-only consumers: rtl/ tb/ board/ tools/ are NOT modified.
REM   xvlog compiles the CURRENT working tree rtl/ (-work xil_defaultlib).
REM ============================================================
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set P5C=D:\repo\ECO\udp_hls_10g\sim\p5close
set RTLFILES=%RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\retx_ram.v %RTL%\tcp_cam.v %RTL%\tcb.v %RTL%\tcp_tx_frame.v
set RC=0

REM ================= G1 =================
cd /d %P5C%\g1run
rmdir /s /q xsim.dir 2>nul
del /q tb_close_g1.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTLFILES% %P5C%\tb_close_g1.v > xvlog_g1.log 2>&1
if errorlevel 1 goto g1_xvlog_err
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_close_g1 -s tb_close_g1 -log xelab_g1.log > NUL 2>&1
if errorlevel 1 goto g1_xelab_err
call "%VIV_BIN%\xsim.bat" tb_close_g1 -runall -log xsim_g1.log > NUL 2>&1
if errorlevel 1 goto g1_xsim_err
findstr /c:"GATE tb_close_g1: PASS" xsim_g1.log >nul
if not errorlevel 1 goto g1_pass
findstr /c:"GATE tb_close_g1: FAIL" xsim_g1.log >nul
if not errorlevel 1 goto g1_fail
goto g1_noverdict

:g1_pass
echo [G1] PASS -- FIN retransmitted (close can complete)
findstr /c:"GATE tb_close_g1:" xsim_g1.log
echo [G1] log: %P5C%\g1run\xsim_g1.log
goto g9_start

:g1_fail
echo [G1] FAIL -- FIN never retransmitted (defect reproduced on current RTL)
findstr /c:"G1 FIN frames" xsim_g1.log
findstr /c:"GATE tb_close_g1:" xsim_g1.log
echo [G1] log: %P5C%\g1run\xsim_g1.log
set RC=1
goto g9_start

:g1_xvlog_err
echo [G1] xvlog FAILED
type xvlog_g1.log
exit /b 2
:g1_xelab_err
echo [G1] xelab FAILED
type xelab_g1.log
exit /b 2
:g1_xsim_err
echo [G1] xsim FAILED
type xsim_g1.log
exit /b 2
:g1_noverdict
echo [G1] no verdict line found in xsim_g1.log
type xsim_g1.log
exit /b 2

REM ================= G9 =================
:g9_start
cd /d %P5C%\g9run
rmdir /s /q xsim.dir 2>nul
del /q tb_close_g9.wdb 2>nul
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTLFILES% %P5C%\tb_close_g9.v > xvlog_g9.log 2>&1
if errorlevel 1 goto g9_xvlog_err
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_close_g9 -s tb_close_g9 -log xelab_g9.log > NUL 2>&1
if errorlevel 1 goto g9_xelab_err
call "%VIV_BIN%\xsim.bat" tb_close_g9 -runall -log xsim_g9.log > NUL 2>&1
if errorlevel 1 goto g9_xsim_err
findstr /c:"GATE tb_close_g9: PASS" xsim_g9.log >nul
if not errorlevel 1 goto g9_pass
findstr /c:"GATE tb_close_g9: FAIL" xsim_g9.log >nul
if not errorlevel 1 goto g9_fail
goto g9_noverdict

:g9_pass
echo [G9] PASS -- no ring_delta underflow replay after FIN
findstr /c:"GATE tb_close_g9:" xsim_g9.log
echo [G9] log: %P5C%\g9run\xsim_g9.log
goto done

:g9_fail
echo [G9] FAIL -- ring_delta underflow replay flood after FIN (defect reproduced)
findstr /c:"G9 ring_delta" xsim_g9.log
findstr /c:"G9 replay flood" xsim_g9.log
findstr /c:"GATE tb_close_g9:" xsim_g9.log
echo [G9] log: %P5C%\g9run\xsim_g9.log
set RC=1
goto done

:g9_xvlog_err
echo [G9] xvlog FAILED
type xvlog_g9.log
exit /b 2
:g9_xelab_err
echo [G9] xelab FAILED
type xelab_g9.log
exit /b 2
:g9_xsim_err
echo [G9] xsim FAILED
type xsim_g9.log
exit /b 2
:g9_noverdict
echo [G9] no verdict line found in xsim_g9.log
type xsim_g9.log
exit /b 2

REM ================= summary =================
:done
echo ------------------------------------------------------------
if "%RC%"=="0" echo p5close gate summary: ALL PASS
if not "%RC%"=="0" echo p5close gate summary: FAIL (defect reproduced on current RTL)
echo logs: %P5C%\g1run\xsim_g1.log  %P5C%\g9run\xsim_g9.log
exit /b %RC%
