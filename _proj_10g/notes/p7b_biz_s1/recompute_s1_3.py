#!/usr/bin/env python3
"""recompute_s1_3.py — 复算 `s1_3_udp_up.txt` 的 4 段对账（落盘脚本）。

为什么有这个文件：`P7B_W13_AUDIT.md` §④-7 指出，V16（BIZ S1 的 J8/J9）那条
"4 段 ΔW11_i == S_i 逐段精确相等" 当时**只有离线手算、脚本没落盘** ⇒ 后人无法复跑。
本文件就是那条复算的落盘版（**只复算，不重跑板子**）。

判据（全部来自原始件，不引入任何新口径）：
  ① 每段  ΔW11_i == S_i       （S_i = 对端 `UDP_SUM pay_bytes`）
  ② 每段  ΔW10_i == pkts_i    （板侧收帧 == 对端发出的 datagram 数）
  ③ ΣΔW11 == ΣS == 最后一段的 off_end == 2,501,222,400
  ④ 全程 ΔW13（udpapp_mismatch）—— ⚠️ **只在同窗 ΔW10 > 0 时才是判据**（否则空判据）

用法:  python3 recompute_s1_3.py [s1_3_udp_up.txt]        # 无参则用同目录下的原始件
"""
import os
import re
import sys

# 工程坑 16: GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError ⇒ 退出码变 1 (按 exit code 判 PASS 的自动化误报 FAIL)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

P = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "s1_3_udp_up.txt")
W, S = {}, []
for ln in open(P, encoding="utf-8", errors="replace"):
    m = re.match(r"(W\d+)\s+0x[0-9A-Fa-f]{2}\s+\S+\s+0x([0-9A-Fa-f]+)", ln)
    if m:
        W.setdefault(m.group(1), []).append(int(m.group(2), 16))
    m = re.match(r"UDP_SUM .*pkts=(\d+) .*pay_bytes=(\d+) .*off_start=(\d+) off_end=(\d+)", ln)
    if m:
        S.append(tuple(int(x) for x in m.groups()))
assert len(W["W11"]) == len(S) + 1, "快照数与 UDP_SUM 段数不匹配: %d vs %d" % (len(W["W11"]), len(S))
d = lambda k, i: W[k][i + 1] - W[k][i]
print("段   ΔW10      pkts      ①✓  ΔW11            S_i(i=pay_bytes) ①✓")
for i, (pk, pay, _o0, o1) in enumerate(S):
    d10, d11 = d("W10", i), d("W11", i)
    print("%d  %8d  %8d  %s  %12d  %12d  %s" % (i + 1, d10, pk, "OK" if d10 == pk else "BAD", d11, pay, "OK" if d11 == pay else "BAD"))
tot10, tot11, sumS, off_end = W["W10"][-1] - W["W10"][0], W["W11"][-1] - W["W11"][0], sum(s[1] for s in S), S[-1][3]
d13 = W["W13"][-1] - W["W13"][0]
print("ΣΔW10=%d ΣΔW11=%d ΣS=%d off_end=%d ⇒ ③%s" % (tot10, tot11, sumS, off_end, "OK" if tot11 == sumS == off_end else "BAD"))
print("⓸ ΔW13=%d —— %s (ΔW10=%d)" % (d13, "有判别力(真的喂了)" if tot10 > 0 else "空判据(没喂进 app, 不得当正证据)", tot10))
