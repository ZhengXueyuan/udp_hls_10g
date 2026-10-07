#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_rx8.py -- Stage B / R1 的**独立复算** (不依赖 xsim 的任何模型).

三条互不依赖的路径互证:
  O) peer.exe --pat-selftest  -> 图案序列前 16 字节 oracle (peer 自己的生成路径)
  P) 本脚本用 python 重写同一递推 (先取后推进) -> 必须与 O 逐字节相同
  R) xsim 的 dump 文件:
       - dump_tx.hex : TX 载荷字节流 -> 必须 == P 的同一序列前缀 (前 12000 字节)
       - dump_tx.frm : 每帧字节数    -> 必须 == [1460]*9 (30000B 会话的前 9 帧)
       - acc_w{0,1}.txt / acc_w{2,3}.txt: 每个 RX 实例**被接受的字流** ->
         本脚本按合同 (每字取 pop8(tkeep) 个字节, 与模型逐字节比) 独立重放,
         得到的 bytes/mismatch 必须与 stats.txt 里 DUT 自报的读数**逐数相等**。
  ⇒ "DUT 说它比完了 N 字节 / 失配 M 个" 这件事由一条完全独立的 Python 路径复核。

用法: python check_rx8.py [runB]     (默认 runB; 目录由 run_rx8_gate.bat 生成)
"""
import io
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1
PEER = os.path.join(ROOT, "tools", "cpp_peer", "peer.exe")

RUN = sys.argv[1] if len(sys.argv) > 1 else "runB"
RD = os.path.join(HERE, RUN)

bad = 0


def xs(s):
    t = (s ^ (s << 13)) & M64
    t = (t ^ (t >> 7)) & M64
    return (t ^ (t << 17)) & M64


def seq_bytes(n):
    out = bytearray()
    s = SEED
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s = xs(s)
    return bytes(out)


# ---- O) peer.exe oracle ----
out = subprocess.run([PEER, "--pat-selftest"], capture_output=True, text=True).stdout
oracle = None
for ln in out.splitlines():
    if "first 16 RTL:" in ln:
        oracle = bytes(int(x, 16) for x in ln.split(":", 1)[1].split())
assert oracle is not None and len(oracle) == 16, out
ref = seq_bytes(16)
print("peer.exe oracle (first 16) = %s" % oracle.hex(" ").upper())
print("python  order model (16)   = %s" % ref.hex(" ").upper())
if ref != oracle:
    bad += 1
    print("  [FAIL] python 序列与 peer oracle 不一致")
else:
    print("  [ok] 两条独立路径逐字节一致")

CAP_TX = 12000
ref_tx = seq_bytes(CAP_TX + 16)


def rd_hex_bytes(p):
    t = io.open(p, encoding="utf-8").read().replace("\n", "").replace(" ", "")
    return bytes.fromhex(t) if t else b""


# ---- TX dump ----
txh = rd_hex_bytes(os.path.join(RD, "dump_tx.hex"))
if txh != ref_tx[:CAP_TX]:
    bad += 1
    i = next((k for k in range(min(len(txh), CAP_TX)) if txh[k] != ref_tx[k]), -1)
    print("  [FAIL] dump_tx.hex != model (len=%d, first diff @%d)" % (len(txh), i))
else:
    print("  [ok] TX payload dump %d bytes == model prefix" % len(txh))

txf = [int(x) for x in io.open(os.path.join(RD, "dump_tx.frm"), encoding="utf-8").read().split()]
if txf != [1460] * 9:
    bad += 1
    print("  [FAIL] dump_tx.frm = %s (expect 9 x 1460)" % txf[:12])
else:
    print("  [ok] TX frame lengths == 9 x 1460")


def byte_at(d, i):
    return (d >> (56 - 8 * i)) & 0xFF


def replay(path, reset_at=None):
    """按合同独立重放: 每字 pop8(tkeep) 字节, 逐字节与模型比.

    reset_at = 第 N 个字 (0-based) 起模型从 SEED 重开 —— 对应 u_ev 的 ev_up 撞车
    (测试规格: ev_up 压在第 4 次握手那一拍, 该字起走新会话流)。
    """
    got_b = got_mm = 0
    s = SEED
    nw = 0
    for ln in io.open(path, encoding="utf-8"):
        ln = ln.split()
        if len(ln) != 2:
            continue
        if reset_at is not None and nw == reset_at:
            s = SEED
        hi, lo = ln[0].split("_")
        d = (int(hi, 16) << 32) | int(lo, 16)
        k = int(ln[1], 16)
        n = bin(k).count("1")
        for i in range(n):
            exp = (s >> 24) & 0xFF
            if byte_at(d, i) != exp:
                got_mm += 1
            s = xs(s)
        got_b += n
        nw += 1
    return nw, got_b, got_mm


# ---- stats.txt / rate.txt (DUT 自报) ----
st = {}
for fn in ("stats.txt", "rate.txt"):
    for ln in io.open(os.path.join(RD, fn), encoding="utf-8"):
        f = ln.split()
        if f and f[0] in ("RX0", "RX1", "I0", "I1", "EV", "RATE"):
            st.setdefault(f[0], {}).update(
                {kv.split("=")[0]: int(kv.split("=")[1]) for kv in f[1:]})

print("")
print(" inst   words   DUT_rxb  model_rxb   DUT_mm  model_mm   verdict")
MAP = [("RX0", "acc_w0.txt", None), ("RX1", "acc_w1.txt", None),
       ("I0", "acc_w2.txt", None), ("I1", "acc_w3.txt", None),
       ("EV", "acc_w4.txt", 3)]
for inst, fn, rat in MAP:
    nw, mb, mm = replay(os.path.join(RD, fn), rat)
    db, dm = st[inst]["rxb"], st[inst]["mm"]
    ok = (mb == db) and (mm == dm)
    if not ok:
        bad += 1
    print(" %-5s %6d %9d %10d %8d %9d   %s"
          % (inst, nw, db, mb, dm, mm, "ok" if ok else "[FAIL]"))

# RATE: 无字流 dump, 只复核自洽性 (mm=0 且 rxb==TB 侧字节计数)
r = st["RATE"]
ok = (r["mm"] == 0) and (r["rxb"] == r["bytes"])
if not ok:
    bad += 1
print(" RATE  words=%d bytes=%d rxb=%d mm=%d dcyc=%d -> %s"
      % (r["words"], r["bytes"], r["rxb"], r["mm"], r["dcyc"], "ok" if ok else "[FAIL]"))
if r["dcyc"] not in (20 * 187, 20 * 1643):
    bad += 1
    print("  [FAIL] dcyc=%d 既不是 wide 3740 也不是默认 32860" % r["dcyc"])
else:
    print("  [ok] cycles/segment = %d (%s build)" % (r["dcyc"] // 20,
          "P7B_10G" if r["dcyc"] == 20 * 187 else "default"))

print("")
print("INDEPENDENT-RECHECK (%s): %s" % (RUN, "OK" if bad == 0 else "FAIL x%d" % bad))
sys.exit(1 if bad else 0)
