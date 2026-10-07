#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_gate_bat.py -- 一次性补丁: 给 run_tx_ovl_gate.bat 加 M-C4/M-F1/probe 三臂.
   (写成文件跑, 避免 heredoc 吃反斜杠)  """
import io
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
P = r"D:\repo\XCKU5PMini\udp_hls_10g\sim\p7b_stagec_tx\run_tx_ovl_gate.bat"
s = io.open(P, encoding="utf-8", newline="").read().replace("\r\n", "\n")
BS = chr(92)          # backslash
NL = chr(13) + chr(10)  # CRLF (bat 行尾)

subs = []

subs.append((
"""REM   C..I = mutants (1 change each, from sim/p7b_stagec_tx/mut):
REM     C = M-S0a  advance write does not advance (OVL branch)
REM     D = M-S0b  same class in the DEFAULT branch (S0 sensitivity)
REM     E = M-C1   control reservation and data advance same cycle
REM     F = M-C7   drop !ctrl_slot_busy from start_ack
REM     G = M-C9   arbitration key = ctrl_slot_busy (no ctrl_tx_pend)
REM     H = M-C3   ping-pong degenerated to single bank
REM     I = M-C2   control reservation registered 8 cycles (form A)
REM Contract: A/B RC==0; C..I RC!=0.""",
"""REM   C..L = mutants (1 change each, from sim/p7b_stagec_tx/mut):
REM     C = M-S0a  advance write does not advance (OVL branch)
REM     D = M-S0b  same class in the DEFAULT branch (S0 sensitivity)
REM     E = M-C1   control reservation and data advance same cycle
REM     F = M-C7   drop !ctrl_slot_busy from start_ack
REM     G = M-C9   arbitration key = ctrl_slot_busy (no ctrl_tx_pend)
REM     H = M-C3   ping-pong degenerated to single bank
REM     I = M-C2   control reservation registered 8 cycles (form A)
REM     J = M-C6   drop the rewind gate (ctrl_adv_inflight)  [IN CONTRACT now]
REM     K = M-C8   drop rx_idle from start_ack
REM     L = M-C4   session self-lock (drain branch never clears retx_active)
REM   P/Q/R = F1 negative control (stimulus = review's flood probe, verbatim):
REM     P = probe vs current OVL RTL   expect NOFLOOD
REM     Q = probe vs mut_f1 (fix off)  expect FLOOD   <-- teeth of the F1 judge
REM     R = probe vs default serial    expect NOFLOOD
REM Contract: A/B/P/R RC==0; C..L/Q RC!=0."""))

subs.append((
"""call :run K "%HERE%""" + BS + """mut""" + BS + """mut_c8.v" "-d TCP_TX_OVL"
set RCK=%errorlevel%
""",
"""call :run K "%HERE%""" + BS + """mut""" + BS + """mut_c8.v" "-d TCP_TX_OVL"
set RCK=%errorlevel%
call :run L "%HERE%""" + BS + """mut""" + BS + """mut_c4.v" "-d TCP_TX_OVL"
set RCL=%errorlevel%
call :runp P "%RTL%""" + BS + """tcp_tx_frame.v" "-d TCP_TX_OVL" "FLOODPROBE: NOFLOOD"
set RCP=%errorlevel%
call :runp Q "%HERE%""" + BS + """mut""" + BS + """mut_f1.v" "-d TCP_TX_OVL" "FLOODPROBE: FLOOD"
set RCQ=%errorlevel%
call :runp R "%RTL%""" + BS + """tcp_tx_frame.v" "-d ARM_SERIAL" "FLOODPROBE: NOFLOOD"
set RCR=%errorlevel%
"""))

subs.append((
"""echo   J M-C6  no rewgate RC=%RCJ% (KNOWN GAP: stimulus hits the resv window only twice; not counted)
echo   K M-C8  no rx_idle RC=%RCK% (expect nonzero)
""",
"""echo   J M-C6  no rewgate RC=%RCJ% (expect nonzero; stimulus = in-slot FIN window + retx_req)
echo   K M-C8  no rx_idle RC=%RCK% (expect nonzero)
echo   L M-C4  self-lock RC=%RCL%  (expect nonzero; stuck judge)
echo   P probe OVL fixed RC=%RCP% (expect 0 = NOFLOOD)
echo   Q probe M-F1      RC=%RCQ% (expect nonzero = FLOOD)
echo   R probe serial    RC=%RCR% (expect 0 = NOFLOOD)
"""))

subs.append((
"""if not "%RCI%"=="0" set /a FAILS+=1
if "%RCK%"=="0" set /a FAILS+=1
""",
"""if "%RCI%"=="0" set /a FAILS+=1
if "%RCJ%"=="0" set /a FAILS+=1
if "%RCK%"=="0" set /a FAILS+=1
if "%RCL%"=="0" set /a FAILS+=1
if not "%RCP%"=="0" set /a FAILS+=1
if "%RCQ%"=="0" set /a FAILS+=1
if not "%RCR%"=="0" set /a FAILS+=1
"""))

subs.append((
'findstr /C:"FRAMES" /C:"COV " /C:"MINGAP" /C:"CYCRX" /C:"CYCTX" /C:"FRAMEPERIOD" /C:"OVL " /C:"REDS" /C:"T8 " /C:"TB_TCP_TX_OVL" "runB' + BS + 'xs.log"\n'
'echo   ---- mutant verdicts (REDS line + verdict + first FAIL lines) ----\n'
'for %%M in (C D E F G H I J K) do (',
'findstr /C:"FRAMES" /C:"COV " /C:"MINGAP" /C:"CYCRX" /C:"CYCTX" /C:"FRAMEPERIOD" /C:"OVL F1" /C:"OVL C6" /C:"OVL wsrc" /C:"REDS" /C:"T8 " /C:"TB_TCP_TX_OVL" "runB' + BS + 'xs.log"\n'
'echo   ---- F1 negative control (review flood probe: P fixed / Q mut_f1 / R serial) ----\n'
'for %%M in (P Q R) do (\n'
'  echo   [%%M]:\n'
'  findstr /C:"FLOODPROBE" "run%%M' + BS + 'xs.log"\n'
')\n'
'echo   ---- mutant verdicts (REDS line + verdict + first FAIL lines) ----\n'
'for %%M in (C D E F G H I J K L) do ('))

probe_helper = (
":runp\n"
"REM probe arm: %4 = expected verdict string in xs.log\n"
'set "NAME=%~1"\n'
'set "RSRC=%~2"\n'
'set "DEFS=%~3"\n'
'set "EXP=%~4"\n'
'if not exist "run%NAME%" mkdir "run%NAME%"\n'
'pushd "run%NAME%"\n'
'if exist xsim.dir rmdir /s /q xsim.dir\n'
'if exist xs.log del /q xs.log\n'
'call "%XV%' + BS + 'xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'tcb.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'fifo_sync.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'checksum16.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'retx_ram.v" "..' + BS + '..' + BS + '..' + BS + 'sim' + BS + 'p7b_stagec_tx' + BS + 'probe' + BS + 'tb_flood_probe.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)\n'
'findstr /I /C:"ERROR" xv_out.log > NUL\n'
'if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)\n'
'call "%XV%' + BS + 'xelab.bat" -debug typical xil_defaultlib.tb_flood_probe -s flood -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)\n'
'call "%XV%' + BS + 'xsim.bat" flood -runall -log xs.log > xs_out.log 2>&1\n'
'findstr /C:"%EXP%" xs.log > NUL\n'
'if errorlevel 1 (echo PROBE-VERDICT-MISMATCH [%NAME%] expected [%EXP%]: & findstr /C:"FLOODPROBE" xs.log & popd & exit /b 1)\n'
'findstr /C:"FLOODPROBE" xs.log\n'
'popd\n'
'exit /b 0\n'
"\n"
":run\n")

old_run_head = (
":run\n"
'set "NAME=%~1"\n'
'set "RSRC=%~2"\n'
'set "DEFS=%~3"\n'
'if not exist "run%NAME%" mkdir "run%NAME%"\n'
'pushd "run%NAME%"\n'
'if exist xsim.dir rmdir /s /q xsim.dir\n'
'if exist xs.log del /q xs.log\n'
'call "%XV%' + BS + 'xvlog.bat" -work xil_defaultlib %DEFS% "%RSRC%" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'tcb.v" ')
subs.append((old_run_head, probe_helper + old_run_head))

for i, (old, new) in enumerate(subs):
    n = s.count(old)
    if n != 1:
        print("MISS #%d hits=%d" % (i, n))
        sys.exit(1)
    s = s.replace(old, new)

s = s.replace("\r\n", "\n").replace("\n", "\r\n")
assert all(ord(c) < 128 for c in s), "non-ascii in bat"
io.open(P, "w", encoding="ascii", newline="").write(s)
print("gate bat patched, %d bytes" % len(s))
