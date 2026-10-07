#!/usr/bin/env python3
"""gap_probe.py -- 定位板纯 ACK 之间的最大间隔 (判据 (h')① 的取证件)。

对每个 pcap: 打最大的 N 个间隔的**位置与上下文** —— 间隔起止时刻 / 前后 ACK 的
ack+win / 间隔内双向包数 (peer->board 数据包数、board->peer 包数) / 时间占比。
用途: 区分"真停顿 (双向都静)"与"采集/形态-artifact"。

用法: python3 gap_probe.py <pcap> [--top N]
"""
import bisect
import struct
import sys

BOARD = b"\xc0\xa8\x64\x02"
PEER = b"\xc0\xa8\x64\x64"


def parse(fn):
    with open(fn, "rb") as f:
        d = f.read()
    m = d[:4]
    e = "<" if m == b"\xd4\xc3\xb2\xa1" else ">"
    pos = 24
    pk = []      # (t, dir, payload, ack, win)  dir: 'b2p' 板->对端 / 'p2b' 对端->板
    while pos + 16 <= len(d):
        ts_s, ts_us, incl, _o = struct.unpack(e + "IIII", d[pos:pos + 16])
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
        ack = struct.unpack(">I", p[t + 8:t + 12])[0]
        doff = (p[t + 12] >> 4) * 4
        win = struct.unpack(">H", p[t + 14:t + 16])[0]
        ip_tot = struct.unpack(">H", p[14 + 2:14 + 4])[0]
        payload = max(0, ip_tot - ihl - doff)
        tf = ts_s + ts_us / 1e6
        if src == BOARD and dst == PEER:
            pk.append((tf, "b2p", payload, ack, win))
        elif src == PEER and dst == BOARD:
            pk.append((tf, "p2b", payload, ack, win))
    return pk


TOPN = 8
argv = sys.argv[1:]
if "--top" in argv:
    i = argv.index("--top")
    TOPN = int(argv[i + 1])
    del argv[i:i + 2]

for fn in argv:
    pk = parse(fn)
    if not pk:
        print("FILE %s EMPTY" % fn)
        continue
    t0 = pk[0][0]
    times = [r[0] for r in pk]
    pre_p2b = [0]
    pre_pay = [0]
    pre_b2p = [0]
    for r in pk:
        pre_p2b.append(pre_p2b[-1] + (1 if r[1] == "p2b" else 0))
        pre_pay.append(pre_pay[-1] + (r[2] if r[1] == "p2b" else 0))
        pre_b2p.append(pre_b2p[-1] + (1 if r[1] == "b2p" else 0))
    acks = [(r[0], r[3], r[4], idx) for idx, r in enumerate(pk)
            if r[1] == "b2p" and r[2] == 0]
    gaps = sorted(((acks[i][0] - acks[i - 1][0], i) for i in range(1, len(acks))),
                  reverse=True)
    print("FILE %s PKTS %d BOARD_ACKS %d SPAN %.4f s" % (fn, len(pk), len(acks), pk[-1][0] - t0))
    for g, i in gaps[:TOPN]:
        a, b = acks[i - 1], acks[i]
        lo = bisect.bisect_right(times, a[0])
        hi = bisect.bisect_left(times, b[0])
        n_p2b = pre_p2b[hi] - pre_p2b[lo]
        pay = pre_pay[hi] - pre_pay[lo]
        n_b2p = pre_b2p[hi] - pre_b2p[lo]
        print("  GAP %.6f s  rel %.4f..%.4f  inside: p2b=%d(pay=%dB) b2p=%d | before ack=0x%08x win=%d -> after ack=0x%08x win=%d" % (
            g, a[0] - t0, b[0] - t0, n_p2b, pay, n_b2p, a[1], a[2], b[1], b[2]))
