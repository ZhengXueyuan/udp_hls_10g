#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性补丁: 让 .frm 只记录"覆盖前 CAP 字节"的帧 + 判据改用记录帧数 + 回环下限放宽到两模式都够得着."""
import io

p = "tb_app8_equiv.v"
s = io.open(p, encoding="utf-8", newline="").read()


def rep1(a, b, tag):
    global s
    n = s.count(a)
    assert n == 1, "[%s] hits=%d" % (tag, n)
    s = s.replace(a, b)


rep1("    integer dcount [0:6], fcount [0:6], fcur [0:6];",
     "    integer dcount [0:6], fcount [0:6], fcur [0:6];\n"
     "    integer frec [0:6];                  // 已写入 .frm 的帧数 (只记覆盖前 CAP 字节的帧)\n"
     "    reg     ffull [0:6];                 // 该配置的 .frm 已收口", "decl")

rep1('                $fwrite(ffd[idx], "%0d\\n", fcur[idx]);      // 本帧载荷字节数\n'
     "                fcount[idx] = fcount[idx] + 1;",
     "                // 只记录「覆盖前 CAP 字节」的那些帧 —— 此后跑完的帧数是**时序量**\n"
     "                // (与 8 字节/拍这件事同源), 不是设计判据。\n"
     "                if (!ffull[idx]) begin\n"
     '                    $fwrite(ffd[idx], "%0d\\n", fcur[idx]);  // 本帧载荷字节数\n'
     "                    frec[idx] = frec[idx] + 1;\n"
     "                    if (dcount[idx] >= CAP) ffull[idx] = 1'b1;\n"
     "                end\n"
     "                fcount[idx] = fcount[idx] + 1;", "frm")

rep1("            dcount[i] = 0; fcount[i] = 0; fcur[i] = 0;",
     "            dcount[i] = 0; fcount[i] = 0; fcur[i] = 0; frec[i] = 0; ffull[i] = 1'b0;",
     "init")

rep1("            if (i != 5) chk(fcount[i] > 3,",
     "            if (i != 5) chk(frec[i] > 3,", "chk1")
rep1("        chk(fcount[5] == 2,", "        chk(frec[5] == 2,", "chk2")

rep1("chk(l0_txb > 32'd100000,  \"L0 回环确实跑了 (txb > 100000)\");",
     "chk(l0_txb > 32'd10000,   \"L0 回环确实跑了 (txb > 10000: A/B 速度本就不同)\");", "l0thr")

for i in range(7):
    rep1("dcount[%d], fcount[%d]);" % (i, i),
         "dcount[%d], frec[%d]);" % (i, i), "disp%d" % i)

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("TB PATCHED OK")
