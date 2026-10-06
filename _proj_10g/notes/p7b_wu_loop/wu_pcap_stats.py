#!/usr/bin/env python3
"""wu_pcap_stats.py -- J6-ladder pcap 形态统计 (判据 (c) 单连接 + (h) 窗形态)。

自写 pcap 解析器 (不依赖 tshark; 对端只有 python3)。
输出 (每文件一行块):
  FILE / PKTS / CONNS(=1 断言) / UPBYTES(对端->板 TCP 载荷字节) / BOARD_ACKS
  / WIN_MIN / WIN_MED / WIN_LT1460 / SILENT100 (板纯ACK 之间 >100ms 的间隔数)
  / MAX_GAP_S / T_SPAN_S / UPLINK_MBPS (对端->板 载荷字节 / 时间跨度)
用法: python3 wu_pcap_stats.py <pcap> [<pcap> ...]
"""
import struct
import sys


def parse(fn):
    d = open(fn, "rb").read()
    if len(d) < 24:
        return None
    magic = d[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        le = True
    elif magic == b"\xa1\xb2\xc3\xd4":
        le = False
    else:
        return None
    e = "<" if le else ">"
    pos = 24
    pkts = 0
    conns = set()
    upbytes = 0
    board_acks = []          # (t, ack, win)
    ts0 = ts1 = None
    BOARD = b"\xc0\xa8\x64\x02"    # 192.168.100.2
    PEER = b"\xc0\xa8\x64\x64"     # 192.168.100.100
    while pos + 16 <= len(d):
        ts_s, ts_us, incl, orig = struct.unpack(e + "IIII", d[pos:pos + 16])
        pos += 16
        if pos + incl > len(d):
            break
        p = d[pos:pos + incl]
        pos += incl
        if incl < 54:
            continue
        if p[12:14] != b"\x08\x00":
            continue
        ihl = (p[14] & 0xF) * 4
        if len(p) < 14 + ihl + 20:
            continue
        proto = p[14 + 9]
        if proto != 6:                     # TCP only
            continue
        src = p[14 + 12:14 + 16]
        dst = p[14 + 16:14 + 20]
        t = 14 + ihl
        # ⚠️ IP/TCP 头内字段一律**网络序(大端)**, 与 pcap record header 的字节序无关
        sport, dport = struct.unpack(">HH", p[t:t + 4])
        ack = struct.unpack(">I", p[t + 8:t + 12])[0]
        doff = (p[t + 12] >> 4) * 4
        win = struct.unpack(">H", p[t + 14:t + 16])[0]
        ip_tot = struct.unpack(">H", p[14 + 2:14 + 4])[0]
        payload = ip_tot - ihl - doff
        if payload < 0:
            payload = 0
        tf = ts_s + ts_us / 1e6
        if ts0 is None:
            ts0 = tf
        ts1 = tf
        pkts += 1
        # 归一化四元组 (无序)
        key = tuple(sorted([(src, sport), (dst, dport)]))
        conns.add(key)
        if src == PEER and dst == BOARD:
            upbytes += payload
        elif src == BOARD and dst == PEER and payload == 0:
            board_acks.append((tf, ack, win))
    # 板 ACK 静默段 (>100ms)
    sil = 0
    max_gap = 0.0
    for i in range(1, len(board_acks)):
        g = board_acks[i][0] - board_acks[i - 1][0]
        if g > max_gap:
            max_gap = g
        if g > 0.100:
            sil += 1
    wins = sorted(w for (_t, _a, w) in board_acks)
    med = wins[len(wins) // 2] if wins else None
    span = (ts1 - ts0) if (ts0 is not None) else 0.0
    return {
        "pkts": pkts, "conns": len(conns), "upbytes": upbytes,
        "acks": len(board_acks), "win_min": wins[0] if wins else None,
        "win_med": med, "win_lt1460": sum(1 for w in wins if w < 1460),
        "silent100": sil, "max_gap": max_gap, "span": span,
    }


for fn in sys.argv[1:]:
    r = parse(fn)
    if r is None:
        print("FILE %s UNPARSEABLE" % fn)
        continue
    mbps = (r["upbytes"] * 8 / r["span"] / 1e6) if r["span"] > 0 else 0
    print("FILE %s" % fn)
    print("  PKTS %d CONNS %d UPBYTES %d UPLINK_MBPS %.3f" % (
        r["pkts"], r["conns"], r["upbytes"], mbps))
    print("  BOARD_ACKS %d WIN_MIN %s WIN_MED %s WIN_LT1460 %d" % (
        r["acks"], r["win_min"], r["win_med"], r["win_lt1460"]))
    print("  SILENT100 %d MAX_GAP_S %.4f T_SPAN_S %.4f" % (
        r["silent100"], r["max_gap"], r["span"]))
