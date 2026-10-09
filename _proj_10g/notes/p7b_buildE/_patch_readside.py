#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性补丁: 修 apply_readside.py 的两处 (anchor 对齐 + 删掉无意义的 0X10 编辑)。"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "apply_readside.py")
s = io.open(p, encoding="utf-8", newline="").read()

# 1) 把 selftest.sh 那条 edit 的 old 改成**含前导文本**的原文 (原锚点漏了前半句)
old = '"  #    现役 = **0x18** (构建 D 66 字'
assert s.count(old) == 1, s.count(old)
s = s.replace(old, '"而\\"正例必须 0 FAIL\\"是本脚本的断言⑤)。现役 = **0x18** (构建 D 66 字')
old = '"  #    现役 = **0x19** (构建 E 67 字'
assert s.count(old) == 1, s.count(old)
s = s.replace(old, '"而\\"正例必须 0 FAIL\\"是本脚本的断言⑤)。现役 = **0x19** (构建 E 67 字')

# 2) 删掉 fix2 的 0X10 编辑 (0x10 = HW_STATUS, 只是 INFO; D 轮也没动它 ⇒ 不做无意义改动)
old10 = ('E("_proj_pcie/p6e_snap_selftest_fix2.sh",\n'
         '  "  0X10) V=0x00000018;;",\n'
         '  "  0X10) V=0x00000019;;", 1)\n')
assert s.count(old10) == 1, s.count(old10)
s = s.replace(old10, "")

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("PATCH OK")
