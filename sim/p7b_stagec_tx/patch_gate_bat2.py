#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_gate_bat2.py -- 第二轮补丁: 集成门 S/T + 三处口径修正.
   在 patch_gate_bat.py 之后跑 (顺序: 先 1 后 2)."""
import io
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
P = r"D:\repo\XCKU5PMini\udp_hls_10g\sim\p7b_stagec_tx\run_tx_ovl_gate.bat"
s = io.open(P, encoding="utf-8", newline="").read().replace("\r\n", "\n")
BS = chr(92)

subs = []

subs.append((
"""REM   P/Q/R = F1 negative control (stimulus = review's flood probe, verbatim):""",
"""REM   S/T = B5 same-batch INTEGRATION gate (real app_pattern P7B_10G -> real framer):
REM     S = integ tb vs current RTL    expect OK
REM     T = integ tb vs mut_s0a        expect nonzero  <-- teeth of the integ gate
REM   P/Q/R = F1 negative control (stimulus = review's flood probe, verbatim):"""))

subs.append((
'call :runp R "%RTL%' + BS + 'tcp_tx_frame.v" "-d ARM_SERIAL" "FLOODPROBE: NOFLOOD"\n'
'set RCR=%errorlevel%\n',
'call :runp R "%RTL%' + BS + 'tcp_tx_frame.v" "-d ARM_SERIAL" "FLOODPROBE: NOFLOOD"\n'
'set RCR=%errorlevel%\n'
'call :runi S "%RTL%' + BS + 'tcp_tx_frame.v"\n'
'set RCS=%errorlevel%\n'
'call :runi T "%HERE%' + BS + 'mut' + BS + 'mut_s0a.v"\n'
'set RCT=%errorlevel%\n'))

subs.append((
"""echo   P probe OVL fixed RC=%RCP% (expect 0 = NOFLOOD)
echo   Q probe M-F1      RC=%RCQ% (expect nonzero = FLOOD)
echo   R probe serial    RC=%RCR% (expect 0 = NOFLOOD)
""",
"""echo   P probe OVL fixed RC=%RCP% (expect 0 = NOFLOOD)
echo   Q probe M-F1      RC=%RCQ% (expect 0 = FLOOD verdict found; teeth)
echo   R probe serial    RC=%RCR% (expect 0 = NOFLOOD)
echo   S integ app to frm RC=%RCS% (expect 0 = OK)
echo   T integ + M-S0a   RC=%RCT% (expect nonzero)
"""))

# Q 的口径 = 判定串命中即 0
subs.append((
'if not "%RCR%"=="0" set /a FAILS+=1\n',
'if not "%RCR%"=="0" set /a FAILS+=1\n'
'if not "%RCS%"=="0" set /a FAILS+=1\n'
'if "%RCT%"=="0" set /a FAILS+=1\n'))

subs.append((
'if "%RCQ%"=="0" set /a FAILS+=1\n',
'if not "%RCQ%"=="0" set /a FAILS+=1\n'))

subs.append((
'echo   ---- mutant verdicts (REDS line + verdict + first FAIL lines) ----',
'echo   ---- integration gate (real app_pattern P7B_10G -> real tcp_tx_frame) ----\n'
'for %%M in (S T) do (\n'
'  echo   [%%M]:\n'
'  findstr /C:"FRAMES" /C:"WIRE" /C:"APP " /C:"T8" /C:"REDS" /C:"TB_INTEG_APP_TX" "run%%M' + BS + 'xs.log"\n'
')\n'
'echo   ---- mutant verdicts (REDS line + verdict + first FAIL lines) ----'))

subs.append((
'for %%M in (C D E F G H I J K L) do (',
'for %%M in (C D E F G H I J K L) do ('))

# :runi 助手 (集成门: -d P7B_10G -d TCP_TX_OVL + rtl/app_pattern.v + tb_integ_app_tx.v)
helper = (
":runi\n"
"REM integration gate arm (needs -d P7B_10G -d TCP_TX_OVL + rtl/app_pattern.v)\n"
'set "NAME=%~1"\n'
'set "RSRC=%~2"\n'
'if not exist "run%NAME%" mkdir "run%NAME%"\n'
'pushd "run%NAME%"\n'
'if exist xsim.dir rmdir /s /q xsim.dir\n'
'if exist xs.log del /q xs.log\n'
'call "%XV%' + BS + 'xvlog.bat" -work xil_defaultlib -d P7B_10G -d TCP_TX_OVL "%RSRC%" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'tcb.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'fifo_sync.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'checksum16.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'retx_ram.v" "..' + BS + '..' + BS + '..' + BS + 'rtl' + BS + 'app_pattern.v" "..' + BS + '..' + BS + '..' + BS + 'tb' + BS + 'tb_integ_app_tx.v" > xv_out.log 2>&1 || (type xv_out.log & popd & exit /b 1)\n'
'findstr /I /C:"ERROR" xv_out.log > NUL\n'
'if not errorlevel 1 (echo XVLOG-ERROR [%NAME%]: & type xv_out.log & popd & exit /b 1)\n'
'call "%XV%' + BS + 'xelab.bat" -debug typical xil_defaultlib.tb_integ_app_tx -s tb_integ -log xe.log > xe_out.log 2>&1 || (echo XELAB-ERROR [%NAME%]: & findstr /I /C:"ERROR" xe_out.log & popd & exit /b 1)\n'
'call "%XV%' + BS + 'xsim.bat" tb_integ -runall -log xs.log > xs_out.log 2>&1\n'
'findstr /C:"TB_INTEG_APP_TX: OK" xs.log > NUL\n'
'if errorlevel 1 (echo ---- INTEG detail [%NAME%]: & findstr /C:"[FAIL]" xs.log & findstr /C:"REDS" xs.log & findstr /C:"TB_INTEG_APP_TX" xs.log & popd & exit /b 1)\n'
'findstr /C:"TB_INTEG_APP_TX" xs.log\n'
'popd\n'
'exit /b 0\n'
"\n"
":runp\n")

subs.append((":runp\n", helper))

for i, (old, new) in enumerate(subs):
    n = s.count(old)
    if n != 1:
        print("MISS #%d hits=%d" % (i, n))
        sys.exit(1)
    s = s.replace(old, new)

s = s.replace("\r\n", "\n").replace("\n", "\r\n")
assert all(ord(c) < 128 for c in s), "non-ascii in bat"
io.open(P, "w", encoding="ascii", newline="").write(s)
print("patch2 applied, %d bytes" % len(s))
