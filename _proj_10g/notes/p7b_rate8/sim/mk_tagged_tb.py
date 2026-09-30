#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_tagged_tb.py -- 把 tb/tb_app_udp.v 的 chk 判据**标签**换成 ASCII 序号.

动因: xsim 的 $display 把中文写成 0xFF 填充的不可读字节, wide 模式下 pos 门红一条
      判不出是哪条。本脚本只替换 chk 的**消息字符串**(逻辑一字不动), 并把
      序号→原文 的对照写到 chk_map.txt, 于是日志里的 "CHK_37" 能精确回指原判据。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
SRC = os.path.join(ROOT, "tb", "tb_app_udp.v")
DST = os.path.join(HERE, "tb_app_udp_tagged.v")

lines = io.open(SRC, encoding="utf-8", newline="").read().split("\n")
out, m = [], []
n = 0
pat = re.compile(r'"([^"]*)"')
for ln in lines:
    if "chk(" in ln and ln.rstrip().endswith('");'):
        ms = list(pat.finditer(ln))
        if ms:
            last = ms[-1]
            n += 1
            m.append((n, last.group(1)))
            ln = ln[:last.start()] + '"CHK_%d"' % n + ln[last.end():]
    out.append(ln)

io.open(DST, "w", encoding="utf-8", newline="").write("\n".join(out))
with io.open(os.path.join(HERE, "chk_map.txt"), "w", encoding="utf-8") as f:
    for i, t in m:
        f.write("%d\t%s\n" % (i, t))
print("tagged TB -> %s ; %d chk labels -> chk_map.txt" % (DST, n))
