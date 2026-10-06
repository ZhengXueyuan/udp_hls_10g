#!/usr/bin/env python3
"""win_tl.py -- 100 ms 桶的窗口/速率时间线 (W54 轮 EPIPE 调查; 自写, 只读)。

用法: python3 win_tl.py <pcap> [bucket_s]
输出: t_bucket | boardACK数 | min_win | max_win | peer_data_B | peer_seg数 | 重传段数(seq<max_seq_of_stream)
"""
import struct
import sys

BOARD = b"\xc0\xa8\x64\x02"
PEER = b"\xc0\xa8\x64\x64"


def scan(fn, bucket=0.1):
    d = open(fn, "rb").read()
    le = d[:4] == b"\xd4\xc3\xb2\xa1"
    e = "<" if le else ">"
    pos = 24
    ts0 = None
    rows = {}
    max_seq = 0
    while pos + 16 <= len(d):
        ts_s, ts_us, incl, _o = struct.unpack(e + "IIII", d[pos:pos + 16])
        pos += 16
        if pos + incl > len(d):
            break
        p = d[pos:pos + incl]
        pos += incl
        if incl < 54 or p[12:14] != b"\x08\x00" or p[14 + 9] != 6:
            continue
        t = ts_s + ts_us * 1e-6
        if ts0 is None:
            ts0 = t
        rel = t - ts0
        ihl = (p[14] & 0xF) * 4
        T = 14 + ihl
        src = p[14 + 12:14 + 16]
        plen = max(0, incl - T - 20)
        flags = p[T + 13]
        seq = struct.unpack(">I", p[T + 4:T + 8])[0]
        win = struct.unpack(">H", p[T + 14:T + 16])[0]
        b = rows.setdefault(int(rel / bucket), [0, 1 << 30, 0, 0, 0, 0])
        if src == BOARD and (flags & 0x10):      # board ACK
            b[0] += 1
            b[1] = min(b[1], win)
            b[2] = max(b[2], win)
        if src == PEER and plen > 0 and not (flags & 0x02):
            b[3] += plen
            b[4] += 1
            if (seq - max_seq) % (1 << 32) < 100:   # 回退 => 重传(或乱序)
                b[5] += 1
            if ((seq + plen - max_seq) % (1 << 32)) < (1 << 31):
                max_seq = max(max_seq, seq + plen)
    print("t_s  ackN  winMin  winMax  peerKB  segN  retxN")
    for k in sorted(rows):
        b = rows[k]
        wmin = "" if b[1] == (1 << 30) else b[1]
        print("%6.1f %5d %7s %7d %7.1f %5d %5d" % (
            k * bucket, b[0], wmin, b[2], b[3] / 1024.0, b[4], b[5]))


if __name__ == "__main__":
    scan(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 0.1)
