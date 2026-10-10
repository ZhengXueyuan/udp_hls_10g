#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_gate_ghost.py -- 给 run_tx_ovl_gate.bat 加 P7B-RETXHI-GHOST 的三条变异臂 X/Y/Z.
   契约: X/Y/Z 期望 RC != 0 (都是"给新仪器配牙"的变异臂).
   ⚠️ 只改 run_tx_ovl_gate.bat (ASCII + CRLF 保持), 不动任何期望值/不放宽既有判据."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
G = os.path.join(HERE, "run_tx_ovl_gate.bat")
NL = "\r\n"
t = open(G, "rb").read().decode("ascii")
bad = 0

def sub(name, old, new, hits=1):
    global t, bad
    n = t.count(old)
    print("%s%-40s hits=%d (declared %d)" % ("OK " if n == hits else "!! ", name, n, hits))
    if n != hits:
        bad += 1
        print("   anchor head:", repr(old[:120]))
        return
    t = t.replace(old, new)

# 1) 头部契约注释
sub("header contract",
    "REM Contract: A/B/O/S RC==0; C..R + T..W RC!=0 except J (KNOWN GAP, not counted).",
    "REM   --- P7B-RETXHI-GHOST (2026-10-10 impl round) ---\r\n"
    "REM   X = M-GHOST-3  ring_hi := retx_hi (defect semantics) expect RC!=0 (e_ghost teeth)\r\n"
    "REM   Y = M-GHOST-4  no ring_restore (drop drain restore) expect RC!=0 (e_replay_jump fires)\r\n"
    "REM   Z = M-GHOST-5  no ring_hi clamp + stale whi      expect RC!=0 (e_ringhi fires)\r\n"
    "REM Contract: A/B/O/S RC==0; C..R + T..Z RC!=0 except J (KNOWN GAP, not counted).")

# 2) 新增三条 call
sub("call X/Y/Z",
    "call :run W \"%HERE%\\mut\\mut_ps_nodsg.v\" \"-d TCP_TX_OVL -d ARM_PERSIST\"\r\n"
    "set RCW=%errorlevel%\r\n",
    "call :run W \"%HERE%\\mut\\mut_ps_nodsg.v\" \"-d TCP_TX_OVL -d ARM_PERSIST\"\r\n"
    "set RCW=%errorlevel%\r\n"
    "REM --- P7B-RETXHI-GHOST (2026-10-10 impl round) ---\r\n"
    "call :run X \"%HERE%\\mut\\mut_ghost_m3.v\" \"-d TCP_TX_OVL -d ARM_PERSIST\"\r\n"
    "set RCX=%errorlevel%\r\n"
    "call :run Y \"%HERE%\\mut\\mut_ghost_norestore.v\" \"-d TCP_TX_OVL -d ARM_PERSIST\"\r\n"
    "set RCY=%errorlevel%\r\n"
    "call :run Z \"%HERE%\\mut\\mut_ghost_noclamp.v\" \"-d TCP_TX_OVL -d ARM_PERSIST\"\r\n"
    "set RCZ=%errorlevel%\r\n")

# 3) SUMMARY 行
sub("summary echo",
    "echo   W M-PS3 no ds_guard     RC=%RCW% (expect nonzero; ARM_PERSIST)",
    "echo   W M-PS3 no ds_guard     RC=%RCW% (expect nonzero; ARM_PERSIST)\r\n"
    "echo   X M-GHOST-3 ring:=retx  RC=%RCX% (expect nonzero; e_ghost teeth)\r\n"
    "echo   Y M-GHOST-4 no restore  RC=%RCY% (expect nonzero; e_replay_jump)\r\n"
    "echo   Z M-GHOST-5 no clamp    RC=%RCZ% (expect nonzero; e_ringhi)")

# 4) FAILS 记账
sub("FAILS accounting",
    "if \"%RCW%\"==\"0\" set /a FAILS+=1\r\n",
    "if \"%RCW%\"==\"0\" set /a FAILS+=1\r\n"
    "if \"%RCX%\"==\"0\" set /a FAILS+=1\r\n"
    "if \"%RCY%\"==\"0\" set /a FAILS+=1\r\n"
    "if \"%RCZ%\"==\"0\" set /a FAILS+=1\r\n")

# 5) mutant verdicts 循环 (加 X Y Z)
sub("verdict loop",
    "for %%M in (C D E F G H I J K L M N O P Q R S T U V W) do (",
    "for %%M in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (")

# 6) arm S 关键读数块加 ghost/ringhi 显示 (Z 臂另开一块)
sub("arm S readings + Z block",
    "echo   ---- arm T key readings (P7B-PERSIST negative control) ----\r\n"
    "findstr /C:\"PS2\" /C:\"PS3\" /C:\"PS6\" /C:\"REDS \" /C:\"TB_TCP_TX_OVL\" \"runT\\xs.log\"",
    "echo   ---- arm T key readings (P7B-PERSIST negative control) ----\r\n"
    "findstr /C:\"PS2\" /C:\"PS3\" /C:\"PS6\" /C:\"REDS \" /C:\"TB_TCP_TX_OVL\" \"runT\\xs.log\"\r\n"
    "echo   ---- arms X/Y/Z key readings (RETXHI-GHOST mutant teeth) ----\r\n"
    "findstr /C:\"REDS \" /C:\"TB_TCP_TX_OVL\" /C:\"ghost \" /C:\"ringhi\" \"runX\\xs.log\"\r\n"
    "findstr /C:\"REDS \" /C:\"TB_TCP_TX_OVL\" /C:\"RETXFIX jump\" \"runY\\xs.log\"\r\n"
    "findstr /C:\"REDS \" /C:\"TB_TCP_TX_OVL\" /C:\"ringhi\" \"runZ\\xs.log\"")

if bad:
    print("*** %d mismatch => nothing written ***" % bad)
    sys.exit(1)
badc = [c for c in t if ord(c) > 126]
if badc:
    print("*** non-ASCII in bat: %r ***" % badc[:8])
    sys.exit(1)
out = t.encode("ascii")
open(G, "wb").write(out)
print("WROTE run_tx_ovl_gate.bat bytes=%d lines=%d CR=%d CRLF=%d" %
      (len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
