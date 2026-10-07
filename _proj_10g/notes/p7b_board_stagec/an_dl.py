#!/usr/bin/env python3
"""an_dl.py -- Stage C 下行 pcap 分析 (本机, tshark 提取的 TSV 上跑)。

输入: tshark -T fields 的 TSV (列见 FIELDS)。
输出: 每连接摘要 + 全窗统计 + (可选) 关键事件时间线。
用法: python an_dl.py <fields.tsv> [--conn N] [--events]
"""
import sys
from collections import defaultdict

FIELDS = ["fno", "t", "src", "sport", "dport", "flags", "seq", "ack", "len", "win"]


def load(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            p = ln.rstrip("\n").split(";")
            if len(p) < 10:
                continue
            r = dict(zip(FIELDS, p))
            try:
                r["t"] = float(r["t"]); r["seq"] = int(r["seq"]); r["ack"] = int(r["ack"])
                r["len"] = int(r["len"]); r["win"] = int(r["win"]); r["fno"] = int(r["fno"])
            except ValueError:
                continue
            rows.append(r)
    return rows


BRD = "192.168.100.2"


def main():
    path = sys.argv[1]
    want_conn = None
    show_events = False
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--conn":
            want_conn = int(sys.argv[i + 1]); i += 2
        elif sys.argv[i] == "--events":
            show_events = True; i += 1
        else:
            i += 1

    rows = load(path)
    print("# packets=%d span=%.3f s" % (len(rows), rows[-1]["t"] - rows[0]["t"]) if rows else "EMPTY")
    # 连接分组: 用 (client_port) 作 key (板侧固定 8080)
    conns = defaultdict(list)
    for r in rows:
        port = r["sport"] if r["src"] != BRD else r["dport"]
        conns[port].append(r)

    print("# conns=%d" % len(conns))
    tot_data_segs = tot_uniq = 0
    for port in sorted(conns, key=lambda q: conns[q][0]["t"]):
        rs = conns[port]
        brd_data = [r for r in rs if r["src"] == BRD and r["len"] > 0]
        brd_ackonly = [r for r in rs if r["src"] == BRD and r["len"] == 0 and "A" in r["flags"]]
        peer_acks = [r for r in rs if r["src"] != BRD and r["len"] == 0 and "A" in r["flags"]]
        peer_fin = [r for r in rs if r["src"] != BRD and "F" in r["flags"]]
        brd_fin = [r for r in rs if r["src"] == BRD and "F" in r["flags"]]
        if not brd_data:
            continue
        segs = len(brd_data)
        # 唯一字节 (按 seq 区间)
        uniq = len(set(r["seq"] for r in brd_data))
        dup = segs - uniq
        t0 = brd_data[0]["t"]; t1 = brd_data[-1]["t"]
        span = max(t1 - t0, 1e-9)
        mbps = uniq * 1460 * 8 / span / 1e6
        # ACK 前进轨迹: 最大 ack, 以及最后 ack 时间
        maxack = max((r["ack"] for r in peer_acks), default=0)
        wmin = min((r["win"] for r in peer_acks), default=-1)
        wmax = max((r["win"] for r in peer_acks), default=-1)
        tot_data_segs += segs; tot_uniq += uniq
        line = ("CONN port=%s t0=%.6f span_ms=%.3f data_segs=%d uniq=%d dup=%d "
                "uniq_Mbps=%.1f peer_acks=%d brd_ackonly=%d peer_win[%d..%d] brd_fin=%d peer_fin=%d"
                % (port, t0, span * 1e3, segs, uniq, dup, mbps,
                   len(peer_acks), len(brd_ackonly), wmin, wmax, len(brd_fin), len(peer_fin)))
        if want_conn is None or str(want_conn) == str(port):
            print(line)
        if show_events and want_conn is not None and str(want_conn) == str(port):
            print("---- events (port=%s) ----" % port)
            for r in rs:
                who = "BRD" if r["src"] == BRD else "PEER"
                print("%8.6f %s %s seq=%d ack=%d len=%d win=%d fno=%d"
                      % (r["t"] - t0 if r["t"] >= t0 else r["t"] - t0, who, r["flags"],
                         r["seq"], r["ack"], r["len"], r["win"], r["fno"]))
    print("# TOTAL data_segs=%d uniq=%d dup_ratio=%.3f" % (tot_data_segs, tot_uniq,
          (tot_data_segs - tot_uniq) / max(tot_data_segs, 1)))


if __name__ == "__main__":
    main()
