#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_mut_m5_value.py -- 把 M-5 的注入常量 0xF000_0000 改成 0x8000_0000, 并记录回绕几何依据.
   原因 (实施轮实测): A4 是**回绕安全**比较; 0xF000_0000 对 snd_nxt≈0x4EBB9 落在半圈之外
   => 不变式不破 (e_ringhi 实测 = 0, 无牙); 0x8000_0000 对 0/1/3 号连接落在半圈之内 => 违反."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
MK = os.path.join(HERE, "mk_mut_tx.py")
t = open(MK, encoding="utf-8").read()
bad = 0

OLD = r'''"                whi_r[cfg_up_id]         <= 32'hF000_0000;   // M-5: 注入陈旧高水位\n"'''
NEW = r'''"                whi_r[cfg_up_id]         <= 32'h8000_0000;   // M-5: 注入陈旧高水位\n"'''
n = t.count(OLD)
print("%s M-5 constant  hits=%d (declared 1)" % ("OK " if n == 1 else "!! ", n))
if n == 1:
    t = t.replace(OLD, NEW)
else:
    bad += 1

OLD2 = r'''#   两处改动 = 同一条通路 ("陈旧/异常高水位活下来"): ① 钳位删掉; ② cfg_up 清位改成注入
#   0xF000_0000 (模拟上一会话的高水位漏进新会话 = 设计件 E3-6 的危险方向)。
'''
NEW2 = r'''#   两处改动 = 同一条通路 ("陈旧/异常高水位活下来"): ① 钳位删掉; ② cfg_up 清位改成注入
#   0x8000_0000 (模拟上一会话的高水位漏进新会话 = 设计件 E3-6 的危险方向)。
#   ⭐ 选值依据 (回绕几何; 实施轮实测 + 推导): A4 是**回绕安全**比较 ⟹ 注入常量必须
#      "在 snd_nxt 之前不到半圈" (即 (snd_nxt − whi) mod 2^32 ≥ 2^31) 才构成违反。
#      实测: 0xF000_0000 对 snd_nxt≈0x4EBB9 落在**半圈之外** ⇒ 不变式不破 (ringhi=0, 无牙);
#      0x8000_0000 对 0/1/3 号连接 (snd_nxt < 2^31) 均落在半圈之内 ⇒ 违反 ⇒ 必命中。
'''
n2 = t.count(OLD2)
print("%s M-5 comment  hits=%d (declared 1)" % ("OK " if n2 == 1 else "!! ", n2))
if n2 == 1:
    t = t.replace(OLD2, NEW2)
else:
    bad += 1

if bad:
    print("*** %d 处不符 => 不落盘 ***" % bad)
    sys.exit(1)
open(MK, "w", encoding="utf-8", newline="\n").write(t)
print("WROTE mk_mut_tx.py")
