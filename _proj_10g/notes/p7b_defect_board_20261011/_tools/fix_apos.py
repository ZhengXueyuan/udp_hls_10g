#!/usr/bin/env python3
# fix_apos.py -- 把报告正文里的占位串 @APOS@ 还原成单引号 (绕开 shell 引号限制, 不改其它字符)
import io, sys

p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
n = s.count("@APOS@")
s = s.replace("@APOS@", chr(39))
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
sys.stdout.write("FIX_APOS replaced=%d file=%s\n" % (n, p))
