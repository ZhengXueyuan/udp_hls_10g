#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 F —— 主验证器 `run_tx_ovl_gate.bat` 加 5 臂 (N..R, 全部围绕 W67/W69 的判据).
   A..M 十三臂**一字不动** (逐位不变契约)。"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
P = "sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat"

E = []


def add(old, new, n=1):
    E.append((old, new, n))


add("REM   L = M-W66-1  stat_winstall never counts (build E)\r\n"
    "REM   M = M-W66-2  stat_winstall predicate drops !wnd_open (build E)\r\n"
    "REM Contract: A/B RC==0; C..M RC!=0 (J = KNOWN GAP, not counted).\r\n",
    "REM   L = M-W66-1  stat_winstall never counts (build E)\r\n"
    "REM   M = M-W66-2  stat_winstall predicate drops !wnd_open (build E)\r\n"
    "REM   --- build F (W67/W69 judges + the W67_CAP_SMALL arm) ---\r\n"
    "REM   N = M-W67-1  split predicate drops the side term (expect nonzero; has teeth in arm B)\r\n"
    "REM   O = CLEAN  -d TCP_TX_OVL -d W67_CAP_SMALL  expect RC 0  (the ONLY arm where the\r\n"
    "REM       board-cap side is non-empty: cap 8192 is reachable, so W67 is NOT an empty judge)\r\n"
    "REM   P = M-W67-2  cap-side counter never counts (expect nonzero; teeth ONLY in arm O)\r\n"
    "REM   Q = M-W69-2  op-point latch enabled by start_data instead of the wait cycle\r\n"
    "REM   R = M-W69-1  op-point latch never updates\r\n"
    "REM Contract: A/B/O RC==0; C..R RC!=0 except J (KNOWN GAP, not counted).\r\n", 1)

add("call :run M \"%HERE%\\mut\\mut_w66_nownd.v\" \"-d TCP_TX_OVL\"\r\n"
    "set RCM=%errorlevel%\r\n",
    "call :run M \"%HERE%\\mut\\mut_w66_nownd.v\" \"-d TCP_TX_OVL\"\r\n"
    "set RCM=%errorlevel%\r\n"
    "call :run N \"%HERE%\\mut\\mut_w67_always.v\" \"-d TCP_TX_OVL\"\r\n"
    "set RCN=%errorlevel%\r\n"
    "call :run O \"%RTL%\\tcp_tx_frame.v\" \"-d TCP_TX_OVL -d W67_CAP_SMALL\"\r\n"
    "set RCO=%errorlevel%\r\n"
    "call :run P \"%HERE%\\mut\\mut_w67_dead.v\" \"-d TCP_TX_OVL -d W67_CAP_SMALL\"\r\n"
    "set RCP=%errorlevel%\r\n"
    "call :run Q \"%HERE%\\mut\\mut_w69_atstart.v\" \"-d TCP_TX_OVL\"\r\n"
    "set RCQ=%errorlevel%\r\n"
    "call :run R \"%HERE%\\mut\\mut_w69_dead.v\" \"-d TCP_TX_OVL\"\r\n"
    "set RCR=%errorlevel%\r\n", 1)

add("echo   M M-W66-2 no !wnd_open RC=%RCM% (expect nonzero; semantic-wrong direction)\r\n",
    "echo   M M-W66-2 no !wnd_open RC=%RCM% (expect nonzero; semantic-wrong direction)\r\n"
    "echo   N M-W67-1 no side term  RC=%RCN% (expect nonzero; build F)\r\n"
    "echo   O CLEAN W67_CAP_SMALL   RC=%RCO% (expect 0; **cap-side arm** - W67 non-vacuous here)\r\n"
    "echo   P M-W67-2 dead cap cnt  RC=%RCP% (expect nonzero; build F)\r\n"
    "echo   Q M-W69-2 latch@start   RC=%RCQ% (expect nonzero; build F)\r\n"
    "echo   R M-W69-1 dead latch    RC=%RCR% (expect nonzero; build F)\r\n", 1)

add("if \"%RCM%\"==\"0\" set /a FAILS+=1\r\n",
    "if \"%RCM%\"==\"0\" set /a FAILS+=1\r\n"
    "if not \"%RCN%\"==\"0\" set /a FAILS+=1\r\n"
    "if not \"%RCO%\"==\"0\" set /a FAILS+=1\r\n"
    "if \"%RCP%\"==\"0\" set /a FAILS+=1\r\n"
    "if \"%RCQ%\"==\"0\" set /a FAILS+=1\r\n"
    "if \"%RCR%\"==\"0\" set /a FAILS+=1\r\n", 1)

FIND_OLD = ('findstr /C:"FRAMES" /C:"COV " /C:"MINGAP" /C:"CYCRX" /C:"CYCTX" /C:"FRAMEPERIOD" '
            '/C:"OVL " /C:"REDS" /C:"T8 " /C:"W66" /C:"TB_TCP_TX_OVL" "runB' + chr(92) + 'xs.log"' + "\r\n")
FIND_NEW = ('findstr /C:"FRAMES" /C:"COV " /C:"MINGAP" /C:"CYCRX" /C:"CYCTX" /C:"FRAMEPERIOD" '
            '/C:"OVL " /C:"REDS" /C:"T8 " /C:"W66" /C:"W67" /C:"W69" /C:"TB_TCP_TX_OVL" "runB' + chr(92) + 'xs.log"' + "\r\n"
            "echo   ---- arm O key readings (the W67_CAP_SMALL arm) ----\r\n"
            'findstr /C:"W66" /C:"W67" /C:"W69" /C:"REDS " /C:"FRAMES" /C:"TB_TCP_TX_OVL" "runO' + chr(92) + 'xs.log"' + "\r\n")
add(FIND_OLD, FIND_NEW, 1)

add("for %%M in (C D E F G H I J K L M) do (\r\n",
    "for %%M in (C D E F G H I J K L M N O P Q R) do (\r\n", 1)


def main():
    check = "--check" in sys.argv[1:]
    p = os.path.join(REPO, P.replace("/", os.sep))
    b = open(p, "rb").read()
    nl = b"\r\n" if b.count(b"\r\n") else b"\n"
    s = b.decode("utf-8")
    fails = 0
    for old, new, n in E:
        old2 = old.replace("\r\n", nl.decode())
        new2 = new.replace("\r\n", nl.decode())
        k = s.count(old2)
        print("%s hits=%d/%d  %s" % ("OK  " if k == n else "FAIL", k, n, old.split("\r\n")[0][:52]))
        if k != n:
            fails += 1
            continue
        if not check:
            s = s.replace(old2, new2)
    if not check and not fails:
        io.open(p, "w", encoding="utf-8", newline="").write(s)
        print("BAT_WRITTEN")
    print("APPLY_GATE %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(E), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
