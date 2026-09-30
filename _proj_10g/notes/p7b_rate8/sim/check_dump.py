#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_dump.py -- P7B 8 字节/拍改造的**独立复算** (不依赖 xsim 的任何模型).

三条独立路径互证:
  O) peer.exe --pat-selftest  -> 前 16 字节 oracle (peer 自己的生成路径)
  P) 本脚本用 python 重写同一递推 (先取后推进) -> 必须与 O 逐字节相同
  R) xsim dump (A=逐字节构建 / B=P7B_10G 构建) -> 必须与 P 的**同一序列前缀**
     逐字节相同; 且每帧字节数必须与 P 的帧长模型相同

用法: python check_dump.py   (在 sim/ 目录下; 需要 runA/ runB/ 已由门生成)
"""
import io
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1
CAP = 12000
PLEN_MAX = 1500
PEER = os.path.join(ROOT, "tools", "cpp_peer", "peer.exe")


def xs(s):
    t = (s ^ (s << 13)) & M64
    t = (t ^ (t >> 7)) & M64
    return (t ^ (t << 17)) & M64


# ---- O) peer.exe oracle ----
out = subprocess.run([PEER, "--pat-selftest"], capture_output=True, text=True).stdout
oracle = None
for ln in out.splitlines():
    if "first 16 RTL:" in ln:
        oracle = bytes(int(x, 16) for x in ln.split(":", 1)[1].split())
assert oracle is not None and len(oracle) == 16, out
print("peer.exe oracle (first 16) = %s" % oracle.hex(" ").upper())

# ---- P) python 独立实现 ----
seq = []
s = SEED
for _ in range(CAP * 2 + 64):
    seq.append((s >> 24) & 0xFF)
    s = xs(s)
assert bytes(seq[:16]) == oracle, "python 序列与 peer.exe oracle 不一致!"
print("python 复算前 16 字节      = %s   -> 与 peer oracle 逐字节一致" % bytes(seq[:16]).hex(" ").upper())


def stream_and_frames(paylen, tx_bytes, cap):
    """按模块的帧长语义产 (字节流, 帧长序列): 覆盖前 cap 字节所需的那些帧."""
    out = bytearray()
    lens = []
    pos = 0          # 图案流偏移
    remain = tx_bytes
    first = True
    while len(out) < cap:
        if tx_bytes == 0:
            seg = paylen
        else:
            eff = tx_bytes if first else remain
            seg = paylen if eff >= 4096 else eff
        first = False
        if seg <= PLEN_MAX:
            out += bytes(seq[pos:pos + seg])
            pos += seg
        else:
            out += bytes([0xA5] * seg)          # PLEN_MAX 冻结 + 常数填充
        lens.append(seg)
        if tx_bytes != 0:
            remain -= seg
            if remain <= 0:
                break
    return bytes(out), lens


def rd_hex(p):
    t = io.open(p, encoding="utf-8").read().replace("\n", "").replace(" ", "")
    return bytes.fromhex(t)


def rd_frm(p):
    return [int(x) for x in io.open(p, encoding="utf-8").read().split()]


CFG = [
    ("T0", 1472, 0,    CAP, 0),
    ("T1", 1477, 0,    CAP, 0),
    ("T2", 5,    0,    CAP, 0),
    ("T3", 8,    0,    CAP, 0),
    ("T4", 1501, 0,    CAP, 0),
    ("T5", 1472, 4419, 4419, 0),
    ("T6", 1472, 0,    CAP, 7),
]

bad = 0
print("")
print(" cfg paylen TX_BYTES  dump(B)  frames(B)  B==python  A==B  frm==model  A==python")
for tag, paylen, txb, exp_cap, gap in CFG:
    full, lens = stream_and_frames(paylen, txb, exp_cap)
    b = rd_hex(os.path.join(HERE, "runB", "dump_%s.hex" % tag))
    a = rd_hex(os.path.join(HERE, "runA", "dump_%s.hex" % tag))
    fb = rd_frm(os.path.join(HERE, "runB", "dump_%s.frm" % tag))
    fa = rd_frm(os.path.join(HERE, "runA", "dump_%s.frm" % tag))
    exp = full[:exp_cap]
    ok_b = (b == exp)
    ok_a = (a == exp)
    ok_ab = (a == b)
    ok_f = (fb == lens and fa == lens)
    for ok in (ok_b, ok_a, ok_ab, ok_f):
        if not ok:
            bad += 1
    print(" %-4s %5d %8d %8d %10d  %-9s %-5s %-10s %s"
          % (tag, paylen, txb, len(b), len(fb), ok_b, ok_ab, ok_f, ok_a))
    if not ok_b:
        i = next(k for k in range(min(len(b), len(exp))) if b[k] != exp[k])
        print("      B 首个不符: idx=%d got=%02X exp=%02X" % (i, b[i], exp[i]))
    if not ok_f:
        print("      frm B=%s" % fb[:12])
        print("      frm model=%s" % lens[:12])

print("")
print("INDEPENDENT-RECHECK: %s" % ("OK (全部逐字节一致)" if bad == 0 else "FAIL x%d" % bad))
sys.exit(1 if bad else 0)
