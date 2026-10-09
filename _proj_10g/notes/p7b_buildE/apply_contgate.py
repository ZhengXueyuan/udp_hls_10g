#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""构建 E: run_cont_gate.bat 适配 A3 的**无条件行为修复** (实测后才动笔).

实测 (2026-10-10 首跑): 冻结锚 arm G 现在
  ① TB RC = 1, 红的**恰好**是 A13a/A13b 两条 (新判据对"改动前"行为的定向反例);
  ② A vs G 的 24 文件里有**恰好 5 个**不同: d7.hex d8.hex f7.txt f8.txt + stats.txt
     (后者的差异只有 I7/I8 两行 —— 那就是 u_rec1/u_rec2 两臂).
⇒ 原判据 "24 文件全同 + G RC 0" 已不成立; 改成**更强**的两条 (不掩盖差异, 而是钉住它):
  ① G 的角色从"等价锚"改成"**A3 的改动前负对照**": RC 必须 != 0, 且红必须**恰好** A13a/A13b;
  ② A vs G: **19 个未受影响的文件**仍须逐字节相同 (任何别的漂移 ⇒ 红); 差异集合必须**恰好**
     = {d7,d8,f7,f8} (它们必须**不同**), 且 stats.txt 去掉 I7/I8 行后必须相同.
新的判据比旧的**更严**: 旧版只要"全同", 新版把"哪几个该不同、为什么"钉成可判签名。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
P = os.path.join(REPO, "sim", "p7b_longsend", "run_cont_gate.bat")
b = open(P, "rb").read()
nl = "\r\n"
s = b.decode("utf-8")

EDITS = []


def E(old, new, n=1):
    EDITS.append((old, new, n))


# ---- 1) 头注释: G 的角色 + 判据 1/2 ----
E("REM   G = FROZEN anchor file, no macro           expect RC 0 AND byte-identical to A\n"
  "REM   M1..M5 = mutants under APP_CONT_ARM       expect RC != 0\n"
  "REM Criteria:\n"
  "REM   1) A/B/C/G RC 0\n"
  "REM   2) A vs G: 24 dump/stats/rate files byte-identical (fc /b) = \u7b49\u4ef7\u951a (\u8bbe\u8ba1\u4ef6 \u00a74.3)\n",
  "REM   G = FROZEN anchor file (= A3 \u4fee\u590d**\u4e4b\u524d**), no macro\n"
  "REM       expect RC != 0 AND the reds are EXACTLY the A13a/A13b pair\n"
  "REM       (2026-10-10 build E: A3 = **unconditional behaviour fix**; the frozen anchor\n"
  "REM        is therefore a *negative control for A3*, not an equivalence anchor)\n"
  "REM   M1..M5 = mutants under APP_CONT_ARM       expect RC != 0\n"
  "REM Criteria:\n"
  "REM   1) A/B/C RC 0; G RC != 0 (with exactly the A13a/A13b reds -- see criterion 2b)\n"
  "REM   2) A vs G: (a) the **19 unaffected files** still byte-identical (fc /b);\n"
  "REM      (b) the delta must be EXACTLY {d7.hex d8.hex f7.txt f8.txt} (they must DIFFER)\n"
  "REM          + stats.txt identical after dropping its I7/I8 lines.\n"
  "REM      \u539f\u5224\u636e = \"24 files byte-identical\" = \u7b49\u4ef7\u951a (\u8bbe\u8ba1\u4ef6 \u00a74.3) -- \u5df2\u4e0d\u6210\u7acb (\u89c1\u4e0a)\u3002\n")

# ---- 2) 判据 1: G 的 RC 期望翻转 (从"A/B/C/G 都 0"改成"G 必须 != 0") ----
E("echo   G frozen anchor    RC=%RCG%   (expect 0)\n",
  "echo   G frozen anchor    RC=%RCG%   (expect nonzero: A3 改动前锚)\n", 1)
E("if not \"%RCA%\"==\"0\"  set /a FAILS+=1\nif not \"%RCB%\"==\"0\"  set /a FAILS+=1\n"
  "if not \"%RCC%\"==\"0\"  set /a FAILS+=1\nif not \"%RCG%\"==\"0\"  set /a FAILS+=1\n",
  "if not \"%RCA%\"==\"0\"  set /a FAILS+=1\nif not \"%RCB%\"==\"0\"  set /a FAILS+=1\n"
  "if not \"%RCC%\"==\"0\"  set /a FAILS+=1\n", 1)

# ---- 3) 判据 2 本体 ----
E("REM ---- 2) A vs G: \u5168\u90e8 dump/stats/rate \u6587\u4ef6\u9010\u5b57\u8282\u76f8\u540c (\u7b49\u4ef7\u951a) ----\n"
  "set \"EQ=1\"\n"
  "for %%F in (d0.hex d1.hex d2.hex d3.hex d4.hex d5.hex d6.hex d7.hex d8.hex d9.hex f0.txt f1.txt f2.txt f3.txt f4.txt f5.txt f6.txt f7.txt f8.txt f9.txt stats.txt rate.txt z_zero_c.txt z_zero_d.txt) do (\n"
  "  fc /b \"runA\\%%F\" \"runG\\%%F\" > NUL\n"
  "  if errorlevel 1 (echo   [DIFF] %%F & set \"EQ=0\")\n"
  ")\n"
  "if \"%EQ%\"==\"1\" (echo   [PASS] equivalence anchor: A vs G byte-identical on 24 files) else (echo   [FAIL] A vs G differ & set /a FAILS+=1)\n",
  "REM ---- 2a) A vs G: **19 \u4e2a\u672a\u53d7\u5f71\u54cd\u7684\u6587\u4ef6**\u9010\u5b57\u8282\u76f8\u540c ----\n"
  "REM   (\u6392\u9664 d7/d8/f7/f8 = u_rec1/u_rec2 \u4e24\u81c2 + stats.txt \u7684 I7/I8 \u4e24\u884c; \u89c1\u4e0b 2b)\n"
  "set \"EQ=1\"\n"
  "for %%F in (d0.hex d1.hex d2.hex d3.hex d4.hex d5.hex d6.hex d9.hex f0.txt f1.txt f2.txt f3.txt f4.txt f5.txt f6.txt f9.txt rate.txt z_zero_c.txt z_zero_d.txt) do (\n"
  "  fc /b \"runA\\%%F\" \"runG\\%%F\" > NUL\n"
  "  if errorlevel 1 (echo   [DIFF] %%F & set \"EQ=0\")\n"
  ")\n"
  "if \"%EQ%\"==\"1\" (echo   [PASS] equivalence anchor: A vs G byte-identical on the 19 unaffected files) else (echo   [FAIL] A vs G differ on a file A3 does NOT explain & set /a FAILS+=1)\n"
  "\n"
  "REM ---- 2b) A3 \u767b\u8bb0\u5dee\u5f02\u5fc5\u987b**\u6070\u597d** ----\n"
  "set \"A3OK=1\"\n"
  "for %%F in (d7.hex d8.hex f7.txt f8.txt) do (\n"
  "  fc /b \"runA\\%%F\" \"runG\\%%F\" > NUL\n"
  "  if not errorlevel 1 (echo   [DIFF-MISSING] %%F: A == G (A3 \u7684\u767b\u8bb0\u5dee\u5f02\u6d88\u5931\u4e86?) & set \"A3OK=0\")\n"
  ")\n"
  "findstr /V /C:\"I7 \" /C:\"I8 \" \"runA\\stats.txt\" > a_stats_norec.txt\n"
  "findstr /V /C:\"I7 \" /C:\"I8 \" \"runG\\stats.txt\" > g_stats_norec.txt\n"
  "fc /b \"a_stats_norec.txt\" \"g_stats_norec.txt\" > NUL\n"
  "if errorlevel 1 (echo   [DIFF] stats.txt (I7/I8 \u4e4b\u5916\u7684\u884c) & set \"A3OK=0\")\n"
  "if \"%A3OK%\"==\"1\" (echo   [PASS] A3 delta exactly as registered (d7 d8 f7 f8 + stats I7/I8)) else (echo   [FAIL] A3 delta is not exactly as registered & set /a FAILS+=1)\n"
  "\n"
  "REM ---- 2c) \u51bb\u7ed3\u951a\u7684\u7ea2\u5fc5\u987b\u6070\u597d\u662f A13a/A13b \u4e24\u6761 ----\n"
  "if \"%RCG%\"==\"0\"  set /a FAILS+=1\n"
  "findstr /C:\"[FAIL]\" \"runG\\xs.log\" > g_reds.txt\n"
  "set /a GNF=0\n"
  "for /f %%C in (g_reds.txt) do set /a GNF+=1\n"
  "if \"%GNF%\"==\"2\" (echo   [PASS] arm G reds == 2) else (echo   [FAIL] arm G reds=%GNF% (expect exactly 2) & set /a FAILS+=1)\n"
  "findstr /C:\"A13a\" /C:\"A13b\" \"runG\\xs.log\" > NUL\n"
  "if errorlevel 1 (echo   [FAIL] arm G: the reds are NOT the A13a/A13b pair & set /a FAILS+=1) else (echo   [PASS] arm G: reds are the A13a/A13b pair)\n")

fails = []
for old, new, n in EDITS:
    old2 = old.replace("\r\n", "\n").replace("\n", nl)
    new2 = new.replace("\r\n", "\n").replace("\n", nl)
    k = s.count(old2)
    tag = "OK  " if k == n else "FAIL"
    print("%s hits=%d/%d  %s" % (tag, k, n, old.split("\n")[0][:60]))
    if k != n:
        fails.append(old.split("\n")[0][:70])
        continue
    s = s.replace(old2, new2)

if "--check" not in sys.argv[1:]:
    if fails:
        print("APPLY_CONTGATE FAIL (no write)")
    else:
        io.open(P, "w", encoding="utf-8", newline="").write(s)
        print("APPLY_CONTGATE OK (%d edits)" % len(EDITS))
else:
    print("APPLY_CONTGATE check-only, %d fail" % len(fails))
sys.exit(1 if fails else 0)
