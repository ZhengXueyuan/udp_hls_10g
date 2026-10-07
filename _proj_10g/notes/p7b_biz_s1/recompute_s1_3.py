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

# ⛔ 2026-10-07 订正 (P7B StB 判据修正轮): 原句 (保留) = `d = lambda k, i: W[k][i+1] - W[k][i]`
#    —— **裸减法**。W10/W11/W13 都是 32 位 ⇒ 段内 >2.86 Gbps (2^32 B/12 s; 本轮的段窗纪律是
#    ≤2.5 s ⇒ 门槛 ≈13.7 Gbps, 当时安全) 或**总窗**更长时, 差值会回卷。裸减法在回卷时给出
#    "负 / 巨小"值 ⇒ 至少是**响亮的假 FAIL**(不是静默), 但仍是错读数。现改为 mod 2^32 +
#    用对端 64 位口径 (pay_bytes / pkts, 都是板外独立量) 还原 k·2^32; raw 与 k 一并打印。
M32 = 1 << 32


def d32(a, b, ref=None):
    """32 位差分: 先取 mod 2^32 余数; `ref` 非空 (板外 64 位口径) 时按 k·2^32 还原。
    返回 (值, k, wrapped_visible)。⚠️ 误选 k 必差 2^32 ≫ 对账容差 (0) ⇒ 判别力不减;
    盲区 = 真偏差恰 ≈ j·2^32 (原理极限)。"""
    raw = (b - a) % M32
    k = 0 if ref is None else max(0, int(round((ref - raw) / float(M32))))
    return raw + k * M32, k, (b < a)


d = lambda k, i: W[k][i + 1] - W[k][i]          # ← 原句保留 (历史口径, 只供逐字对照)
print("段   ΔW10      pkts      ①✓  ΔW11            S_i(i=pay_bytes) ①✓   [raw/k]")
for i, (pk, pay, _o0, o1) in enumerate(S):
    d10, k10, w10 = d32(W["W10"][i], W["W10"][i + 1], pk)
    d11, k11, w11 = d32(W["W11"][i], W["W11"][i + 1], pay)
    print("%d  %8d  %8d  %s  %12d  %12d  %s   [%s/%d,%s%s/%d%s]"
          % (i + 1, d10, pk, "OK" if d10 == pk else "BAD", d11, pay, "OK" if d11 == pay else "BAD",
             W["W10"][i], k10, W["W11"][i], "" if not w11 else "!wrap", k11, "" if not w11 else "!"))
sumS, off_end = sum(s[1] for s in S), S[-1][3]
tot10 = d32(W["W10"][0], W["W10"][-1], sum(s[0] for s in S))[0]
tot11 = d32(W["W11"][0], W["W11"][-1], sumS)[0]
d13 = d32(W["W13"][0], W["W13"][-1])[0]
print("ΣΔW10=%d ΣΔW11=%d ΣS=%d off_end=%d ⇒ ③%s" % (tot10, tot11, sumS, off_end, "OK" if tot11 == sumS == off_end else "BAD"))
print("⓸ ΔW13=%d —— %s (ΔW10=%d)" % (d13, "有判别力(真的喂了)" if tot10 > 0 else "空判据(没喂进 app, 不得当正证据)", tot10))
