#!/usr/bin/env python3
"""rst_scan.py -- pcap 里找 RST/FIN 与"塌速"时标 (W54 轮 EPIPE 调查; 自写, 只读)。

用法: python3 rst_scan.py <pcap> [<pcap> ...]
输出: 每文件 —— 包数 / RST 数(带方向与时标) / FIN 数 / 每条 TCP 流的首末包时刻 /
      最后 12 个包 (t_rel, src->dst, flags, seq, ack, win)。
"""
import struct
import sys

BOARD = "192.168.100.2"
PEER = "192.168.100.100"


def ipstr(b):
    return ".".join(str(x) for x in b)


def scan(fn):
    d = open(fn, "rb").read()
    if len(d) < 24:
        print("%s: too short" % fn)
        return
    le = d[:4] == b"\xd4\xc3\xb2\xa1"
    e = "<" if le else ">"
    pos = 24
    ts0 = None
    n = 0
    rst = []
    fin = []
    tail = []
    flows = {}
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
        t = ts_s + ts_us * 1e-6
        if ts0 is None:
            ts0 = t
        n += 1
        src = ipstr(p[14 + 12:14 + 16])
        dst = ipstr(p[14 + 16:14 + 20])
        T = 14 + ihl
        seq, ack = struct.unpack(">II", p[T + 4:T + 12])
        win = struct.unpack(">H", p[T + 14:T + 16])[0]
        flags = p[T + 13]
        fl = []
        if flags & 0x02:
            fl.append("S")
        if flags & 0x10:
            fl.append("A")
        if flags & 0x01:
            fl.append("F")
        if flags & 0x04:
            fl.append("R")
        if flags & 0x08:
            fl.append("P")
        fstr = "".join(fl)
        key = (src, dst)
        if key not in flows:
            flows[key] = [t - ts0, t - ts0, 0, 0]
        flows[key][1] = t - ts0
        flows[key][2] += 1
        flows[key][3] += max(0, incl - T - 20) if not (flags & 0x02) else 0
        if flags & 0x04:
            rst.append((t - ts0, src, dst, fstr))
        if flags & 0x01:
            fin.append((t - ts0, src, dst, fstr))
        tail.append((t - ts0, src, dst, fstr, seq, ack, win))
    print("== %s" % fn)
    print("   pkts=%d  span=%.3f s" % (n, (tail[-1][0] if tail else 0)))
    for k, v in sorted(flows.items()):
        print("   flow %s -> %s : first=%.3f last=%.3f pkts=%d payload~%d" % (
            k[0], k[1], v[0], v[1], v[2], v[3]))
    print("   RST count=%d" % len(rst))
    for r in rst[:10]:
        print("     RST t=%.3f %s -> %s flags=%s" % r)
    print("   FIN count=%d" % len(fin))
    for f in fin[:10]:
        print("     FIN t=%.3f %s -> %s flags=%s" % f)
    print("   last 12 pkts:")
    for r in tail[-12:]:
        print("     t=%.3f %s -> %s %-4s seq=%u ack=%u win=%u" % r)


if __name__ == "__main__":
    for fn in sys.argv[1:]:
        scan(fn)
