#!/usr/bin/env python3
"""win_diag.py -- 板纯 ACK 的 win 低值形态诊断 (判据 (h) 的口径审查)。

对每份 pcap 打印:
  - 板纯ACK 总数 / win==0 数 / win<1460 数
  - 低窗 ACK 的时间分布 (按 10 桶)
  - 最早 12 个低窗 ACK 的 (t, win, ack)
  - 该连接的 SYN-ACK 的 win 值 (若有)
用法: python3 win_diag.py <pcap> [...]
"""
import struct
import sys

BOARD = b"\xc0\xa8\x64\x02"
PEER = b"\xc0\xa8\x64\x64"


def scan(fn):
    d = open(fn, "rb").read()
    le = d[:4] == b"\xd4\xc3\xb2\xa1"
    e = "<" if le else ">"
    pos = 24
    ts0 = None
    acks = []          # (t, win, ack, flags_tcp_syn)
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
        if p[14 + 9] != 6:
            continue
        src = p[14 + 12:14 + 16]
        dst = p[14 + 16:14 + 20]
        t = 14 + ihl
        ack = struct.unpack(">I", p[t + 8:t + 12])[0]
        doff = (p[t + 12] >> 4) * 4
        win = struct.unpack(">H", p[t + 14:t + 16])[0]
        flags = p[t + 13]
        ip_tot = struct.unpack(">H", p[14 + 2:14 + 4])[0]
        payload = ip_tot - ihl - doff
        tf = ts_s + ts_us / 1e6
        if ts0 is None:
            ts0 = tf
        if src == BOARD and dst == PEER and payload == 0:
            acks.append((tf - ts0, win, ack, flags))
    return acks


for fn in sys.argv[1:]:
    acks = scan(fn)
    n = len(acks)
    w0 = [a for a in acks if a[1] == 0]
    wl = [a for a in acks if a[1] < 1460]
    print("FILE %s ACKS %d WIN0 %d WIN<1460 %d" % (fn, n, len(w0), len(wl)))
    if not acks:
        continue
    span = acks[-1][0]
    # 分 10 桶
    bucket = [0] * 10
    for a in wl:
        b = min(9, int(a[0] / span * 10)) if span > 0 else 0
        bucket[b] += 1
    print("  WIN<1460 per decile: %s" % bucket)
    print("  first 12 low-win ACKs (t, win, ackhex, flags):")
    for a in wl[:12]:
        print("    t=%8.4f win=%6d ack=0x%08x fl=0x%02x" % (a[0], a[1], a[2], a[3]))
    # 低窗连续段: 统计"win==0 之后的第一个 win>=1460 的间隔"
    gaps = []
    i = 0
    while i < n:
        if acks[i][1] == 0:
            j = i
            while j < n and acks[j][1] < 1460:
                j += 1
            if j < n:
                gaps.append(acks[j][0] - acks[i][0])
            i = j
        else:
            i += 1
    if gaps:
        gaps.sort()
        print("  low-win episodes %d  recover-gap s: min=%.4f med=%.4f max=%.4f" % (
            len(gaps), gaps[0], gaps[len(gaps) // 2], gaps[-1]))
