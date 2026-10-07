#!/usr/bin/env python3
# an_stall_forensics.py -- P7B-RETXFIX §3.9 停摆溯源 (纯本地; 在 tshark TSV 上跑)
#
# 背景: r4 臂实测 ~20 × 100.0 ms 停摆 (= 板侧 RTO_LIM 量子) 吃掉 94% 墙钟。
#   本脚本从 pcap 逐帧回答两个问题:
#   (a) 每条连接的形态 (快 4 ms / 慢 103 ms 奇偶交替);
#   (b) **停摆间隙内对端到底发了几个 ACK** —— 这是"板侧阈值问题"vs"对端供给枯竭"的判决量。
# 判决结论 (2026-10-07, RXK.pcap): 间隙内 ACK 直方图 {0:72, 1:24, 2:5} ⇒ 供给枯竭,
#   唯一活杠杆 = 修复延迟本身 (r5: RTO_LIM 100→20 ms)。详见 P7B_RETXFIX.md §3.9。
#
# TSV 生成 (pcap = RXK.pcap 等本目录 pcap; 按既定策略不入库):
#   tshark -r RXK.pcap -T fields -E separator=';' \
#     -e frame.number -e frame.time_relative -e ip.src -e tcp.srcport \
#     -e tcp.seq_raw -e tcp.ack_raw -e tcp.len -e frame.len > RXK_full.tsv
#
# 用法:
#   python an_stall_forensics.py RXK_full.tsv --conns            # 连接序 (端口/t0)
#   python an_stall_forensics.py RXK_full.tsv --conn 60138       # 单连接时间线 (gap>5ms 全打)
#   python an_stall_forensics.py RXK_full.tsv --gaps             # 全量停摆直方图 + 端点 seq
#
# ⚠️ 板侧 ISN 对所有连接相同 (0x12345678) ⇒ board 帧无法按端口分;
#    分流法 = board 帧的 ack 字段 == 该连接对端 ISN+1。
import sys


def load(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            p = ln.rstrip("\n").split(";")
            if len(p) >= 8:
                try:
                    rows.append(dict(fno=int(p[0]), t=float(p[1]), src=p[2], sp=p[3],
                                     seq=int(p[4]), ack=int(p[5]), ln=int(p[6]), flen=int(p[7])))
                except ValueError:
                    pass
    return rows


def conns(rows):
    seen = {}
    for r in rows:
        if r["src"] == "192.168.100.100" and r["sp"] not in seen:
            seen[r["sp"]] = r["t"]
    out = sorted(seen.items(), key=lambda x: x[1])
    for i, (p, t) in enumerate(out):
        print(f"{i:2d} port={p} t0={t:.4f}")


def timeline(rows, P):
    peer = [r for r in rows if r["sp"] == P]
    if not peer:
        print("no such port"); return
    conn_ack = peer[0]["seq"] + 1
    brd = [r for r in rows if r["src"] == "192.168.100.2" and r["ack"] == conn_ack]
    tl = sorted(brd + peer, key=lambda r: r["t"])
    print(f"conn {P}: pkts={len(tl)} span={(tl[-1]['t']-tl[0]['t'])*1000:.1f}ms "
          f"(peer ISN={hex(peer[0]['seq'])}, board frames={len(brd)})")
    prev = None
    for i, r in enumerate(tl):
        d = (r["t"] - prev) * 1000 if prev is not None else 0.0
        prev = r["t"]
        if d > 5 or i < 20 or i > len(tl) - 14:
            who = "BRD " if r["src"] == "192.168.100.2" else "PEER"
            tag = f"  <<<<GAP {d:.1f}ms" if d > 5 else ""
            print(f"[{i}] t={r['t']:.6f} {who} seq={hex(r['seq'])} ack={hex(r['ack'])} "
                  f"len={r['ln']}{tag}")


def gaps(rows, thr=0.05):
    # ⭐ r5 追加: thr 可调 (r5 的停摆量子 = 20 ms ⇒ 默认 50 ms 阈值会漏掉全部)
    #   用法: python an_stall_forensics.py X_full.tsv --gaps --gap-ms 3
    ports = sorted(set(r["sp"] for r in rows if r["src"] == "192.168.100.100"))
    hist = {}
    per_conn = {}
    dur = {}
    tot = 0
    for P in ports:
        peer = [r for r in rows if r["sp"] == P]
        conn_ack = peer[0]["seq"] + 1
        b = [r for r in rows if r["src"] == "192.168.100.2" and r["ack"] == conn_ack
             and r["ln"] > 0]
        acks = [r for r in peer if r["ln"] == 0]
        n = 0
        for i in range(1, len(b)):
            d = b[i]["t"] - b[i - 1]["t"]
            if d > thr:
                n += 1
                tot += 1
                inside = [a for a in acks if b[i - 1]["t"] < a["t"] < b[i]["t"]]
                hist[len(inside)] = hist.get(len(inside), 0) + 1
                k = round(d * 1000)          # 1 ms 桶
                dur[k] = dur.get(k, 0) + 1
                print(f"port={P} gap={d*1000:.1f}ms  间隙内对端 ACK={len(inside)}  "
                      f"gap_end_seq={hex(b[i]['seq'])}")
        per_conn[P] = n
    dist = {}
    for v in per_conn.values():
        dist[v] = dist.get(v, 0) + 1
    print(f"总停摆={tot} (阈值 {thr*1000:.0f} ms)  间隙内 ACK 数直方图={hist}")
    print(f"每连停摆数分布 (停摆数:连接数)={dict(sorted(dist.items()))}")
    print(f"停摆时长直方图 (ms:次数)={dict(sorted(dur.items()))}")


if __name__ == "__main__":
    rows = load(sys.argv[1])
    args = sys.argv[2:]
    if "--conns" in args:
        conns(rows)
    elif "--conn" in args:
        timeline(rows, args[args.index("--conn") + 1])
    elif "--gaps" in args:
        thr = 0.05
        if "--gap-ms" in args:
            thr = float(args[args.index("--gap-ms") + 1]) / 1000.0
        gaps(rows, thr)
    else:
        print(__doc__)
