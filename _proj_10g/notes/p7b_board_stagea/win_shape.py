#!/usr/bin/env python3
"""win_shape.py -- J6-ladder (h') 形态判据的**独立实现** (不依赖 tshark / 别人的脚本)。

判据口径 (P7B_BIZ_PLAN.md §4.1c, 逐字):
  (h')① 无 >100 ms 静默段  => 板纯 ACK 之间 gap > 0.100 s 的**段数** = 0, 并记 MAX_GAP
  (h')② 低窗恢复 <= 1 ms    => 口径 = `win_raw < 1460` -> **首个** `win_raw >= 1460` 的间隔
         (⚠️ 不是 win==0 口径: win==0 口径下两臂都 ~200us => 不可分)

本件只做**读数**, 判定由报告里的人写 (机器不打 PASS/FAIL, 免得"判据安静失效")。

用法: python3 win_shape.py <pcap> [<pcap> ...]
输出: 每 pcap 一行块 (供逐字引用):
  FILE <name> PKTS n CONNS n BOARD_ACKS n
  WIN  min/max/med  LT1460 n  EQ0 n
  SILENT100 n  MAX_GAP s  SPAN s
  RECOV n_recovered n_unrecovered  min/med/max  (+ p90)
"""
import struct
import sys

BOARD = b"\xc0\xa8\x64\x02"   # 192.168.100.2
PEER = b"\xc0\xa8\x64\x64"    # 192.168.100.100
MSS = 1460
SILENT_T = 0.100


def parse(fn):
    with open(fn, "rb") as f:
        d = f.read()
    if len(d) < 24:
        return None
    m = d[:4]
    if m == b"\xd4\xc3\xb2\xa1":
        e = "<"
    elif m == b"\xa1\xb2\xc3\xd4":
        e = ">"
    else:
        return None
    pos = 24
    pkts = 0
    conns = set()
    acks = []          # (t, ack, win)
    t0 = None
    tlast = None
    while pos + 16 <= len(d):
        ts_s, ts_us, incl, _orig = struct.unpack(e + "IIII", d[pos:pos + 16])
        pos += 16
        if pos + incl > len(d):
            break
        p = d[pos:pos + incl]
        pos += incl
        if incl < 54 or p[12:14] != b"\x08\x00":
            continue
        ihl = (p[14] & 0xF) * 4
        if len(p) < 14 + ihl + 20 or p[14 + 9] != 6:
            continue
        src = p[14 + 12:14 + 16]
        dst = p[14 + 16:14 + 20]
        t = 14 + ihl
        sport, dport = struct.unpack(">HH", p[t:t + 4])
        ack = struct.unpack(">I", p[t + 8:t + 12])[0]
        doff = (p[t + 12] >> 4) * 4
        win = struct.unpack(">H", p[t + 14:t + 16])[0]
        ip_tot = struct.unpack(">H", p[14 + 2:14 + 4])[0]
        payload = ip_tot - ihl - doff
        if payload < 0:
            payload = 0
        tf = ts_s + ts_us / 1e6
        if t0 is None:
            t0 = tf
        tlast = tf
        pkts += 1
        conns.add(tuple(sorted([(src, sport), (dst, dport)])))
        if src == BOARD and dst == PEER and payload == 0:
            acks.append((tf, ack, win))
    return {"pkts": pkts, "conns": len(conns), "acks": acks,
            "span": (tlast - t0) if t0 is not None else 0.0}


def analyze(fn):
    r = parse(fn)
    if r is None:
        print("FILE %s UNPARSEABLE" % fn)
        return
    a = r["acks"]
    wins = [w for (_t, _a, w) in a]
    wmin = min(wins) if wins else None
    wmax = max(wins) if wins else None
    wmed = sorted(wins)[len(wins) // 2] if wins else None
    lt = sum(1 for w in wins if w < MSS)
    eq0 = sum(1 for w in wins if w == 0)
    # (h')① 静默段
    silent = 0
    maxgap = 0.0
    for i in range(1, len(a)):
        g = a[i][0] - a[i - 1][0]
        if g > maxgap:
            maxgap = g
        if g > SILENT_T:
            silent += 1
    # (h')② 低窗恢复 (<1460 -> 首个 >=1460)
    rec = []
    unrecovered = 0
    i = 0
    n = len(a)
    while i < n:
        if a[i][2] < MSS:
            j = i
            while j < n and a[j][2] < MSS:
                j += 1
            if j < n:
                rec.append(a[j][0] - a[i][0])
            else:
                unrecovered += 1
            i = j + 1
        else:
            i += 1
    rec.sort()
    def q(x):
        return rec[min(len(rec) - 1, int(len(rec) * x))] if rec else None
    print("FILE %s PKTS %d CONNS %d BOARD_ACKS %d" % (fn, r["pkts"], r["conns"], len(a)))
    print("  WIN min=%s med=%s max=%s LT1460=%d EQ0=%d" % (wmin, wmed, wmax, lt, eq0))
    print("  SILENT100 %d  MAX_GAP %.6f s  SPAN %.4f s" % (silent, maxgap, r["span"]))
    print("  RECOV n=%d (unrecovered=%d)  min=%.6f med=%.6f p90=%.6f max=%.6f" % (
        len(rec), unrecovered,
        rec[0] if rec else -1, q(0.5) if rec else -1,
        q(0.9) if rec else -1, rec[-1] if rec else -1))


for fn in sys.argv[1:]:
    analyze(fn)
