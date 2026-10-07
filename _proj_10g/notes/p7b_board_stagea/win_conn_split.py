#!/usr/bin/env python3
"""win_conn_split.py -- 按连接拆分的窗口形态读数 (对 (c) "单连接" 断言做机械核对)。

win_shape.py 只打**全局**统计; 若一跑里混进上一连接的解体尾巴 (FIN 重传),
全局统计的 (h')① 静默段会被**另一个连接的 ACK 填缝**而失真。
本件按归一化四元组分组, 每组给: 包数 / 首末时刻 / 端口 / 板纯 ACK 数 / win 统计 /
SILENT100 / MAX_GAP / 低窗恢复。

用法: python3 win_conn_split.py <pcap> [...]
"""
import struct
import sys

BOARD = b"\xc0\xa8\x64\x02"
PEER = b"\xc0\xa8\x64\x64"
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
    rows = []           # (key, t, is_board_ack, win)
    t0 = None
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
        sport, dport = struct.unpack(">HH", p[t:t + 4])
        doff = (p[t + 12] >> 4) * 4
        win = struct.unpack(">H", p[t + 14:t + 16])[0]
        ip_tot = struct.unpack(">H", p[14 + 2:14 + 4])[0]
        payload = ip_tot - ihl - doff
        if payload < 0:
            payload = 0
        tf = ts_s + ts_us / 1e6
        if t0 is None:
            t0 = tf
        key = tuple(sorted([(bytes(src), sport), (bytes(dst), dport)]))
        is_ba = (src == BOARD and dst == PEER and payload == 0)
        rows.append((key, tf - t0, is_ba, win))
    return rows


def stats(acks):
    """acks = [(t, win)] 板纯 ACK (已按时间排序)"""
    wins = [w for (_t, w) in acks]
    silent = 0
    maxgap = 0.0
    for i in range(1, len(acks)):
        g = acks[i][0] - acks[i - 1][0]
        if g > maxgap:
            maxgap = g
        if g > SILENT_T:
            silent += 1
    rec = []
    unre = 0
    i = 0
    n = len(acks)
    while i < n:
        if acks[i][1] < MSS:
            j = i
            while j < n and acks[j][1] < MSS:
                j += 1
            if j < n:
                rec.append(acks[j][0] - acks[i][0])
            else:
                unre += 1
            i = j + 1
        else:
            i += 1
    rec.sort()
    return {
        "n": len(acks), "min": min(wins) if wins else None,
        "med": wins[len(wins) // 2] if wins else None,
        "lt": sum(1 for w in wins if w < MSS),
        "eq0": sum(1 for w in wins if w == 0),
        "silent": silent, "maxgap": maxgap,
        "rec": len(rec), "unre": unre,
        "rec_min": rec[0] if rec else None,
        "rec_med": rec[len(rec) // 2] if rec else None,
        "rec_max": rec[-1] if rec else None,
    }


for fn in sys.argv[1:]:
    rows = parse(fn)
    if rows is None:
        print("FILE %s UNPARSEABLE" % fn)
        continue
    groups = {}
    for (key, t, is_ba, win) in rows:
        g = groups.setdefault(key, {"n": 0, "t0": t, "t1": t, "acks": []})
        g["n"] += 1
        g["t1"] = t
        if is_ba:
            g["acks"].append((t, win))
    print("FILE %s PKTS %d CONNS %d" % (fn, len(rows), len(groups)))
    for key, g in sorted(groups.items(), key=lambda kv: -kv[1]["n"]):
        (a1, p1), (a2, p2) = key
        s = stats(g["acks"])
        print("  CONN %s:%d <-> %s:%d  pkts=%d  span=%.4f..%.4f s  BOARD_ACKS=%d" % (
            ".".join(str(b) for b in a1), p1, ".".join(str(b) for b in a2), p2,
            g["n"], g["t0"], g["t1"], s["n"]))
        print("       WIN min=%s med=%s LT1460=%d EQ0=%d | SILENT100=%d MAX_GAP=%.6f" % (
            s["min"], s["med"], s["lt"], s["eq0"], s["silent"], s["maxgap"]))
        print("       RECOV n=%d (unrec=%d) min=%s med=%s max=%s" % (
            s["rec"], s["unre"],
            "%.6f" % s["rec_min"] if s["rec_min"] is not None else "-",
            "%.6f" % s["rec_med"] if s["rec_med"] is not None else "-",
            "%.6f" % s["rec_max"] if s["rec_max"] is not None else "-"))
