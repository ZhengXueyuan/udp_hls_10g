#!/usr/bin/env python3
"""head_probe.py -- 逐包重建 pcap 开头 (定位"静默段"是真停顿还是启动形态)。

用法: python3 head_probe.py <pcap> [N]     # 默认打前 24 个包 (双方各半)
输出: rel_t dir len seq ack win flags
"""
import struct
import sys

BOARD = b"\xc0\xa8\x64\x02"
PEER = b"\xc0\xa8\x64\x64"


def parse(fn, nmax):
    with open(fn, "rb") as f:
        d = f.read()
    m = d[:4]
    e = "<" if m == b"\xd4\xc3\xb2\xa1" else ">"
    pos = 24
    out = []
    t0 = None
    while pos + 16 <= len(d) and len(out) < nmax:
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
        sport, dport = struct.unpack(">HH", p[t:t + 4])
        seq = struct.unpack(">I", p[t + 4:t + 8])[0]
        ack = struct.unpack(">I", p[t + 8:t + 12])[0]
        fl = p[t + 13]
        doff = (p[t + 12] >> 4) * 4
        win = struct.unpack(">H", p[t + 14:t + 16])[0]
        ip_tot = struct.unpack(">H", p[14 + 2:14 + 4])[0]
        payload = max(0, ip_tot - ihl - doff)
        tf = ts_s + ts_us / 1e6
        if t0 is None:
            t0 = tf
        d0 = "B->P" if src == BOARD else ("P->B" if src == PEER else "??")
        flags = ""
        for bit, ch in ((0x02, "S"), (0x10, "A"), (0x01, "F"), (0x04, "R"), (0x08, "P")):
            if fl & bit:
                flags += ch
        out.append("  t=%9.6f %s %d->%d len=%4d seq=0x%08x ack=0x%08x win=%6d %s" % (
            tf - t0, d0, sport, dport, payload, seq, ack, win, flags))
    return out


fn = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 24
print("HEAD %s" % fn)
for line in parse(fn, n):
    print(line)
