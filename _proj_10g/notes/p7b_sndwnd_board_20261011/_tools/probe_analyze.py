#!/usr/bin/env python3
# probe_analyze.py -- P7B-PERSIST 板级 A/B 轮: pcap 口径分析器 (J-P1/J-P2/P-C 判据的原料)
#   口径 (逐条写在输出里, 便于复核):
#     (1) 全解 TCP 段 (eth/ip/tcp), 按方向分组: BOARD->PEER / PEER->BOARD;
#     (2) SYN 窗口: 两个方向的 SYN/SYN-ACK 的 win 字段 (P-C(c1)/(c2a) 的 "SYN 就小" 见证);
#     (3) BOARD->PEER 的 **payload==1 段** = 探询候选 (J-P1: 55 B / flags 0x18 / seq==当时 snd_una);
#         逐条打印 t/seq/ack/win/flags/payload 字节, 并给出与"该连接首数据 seq"的偏移;
#     (4) PEER->BOARD 的注入候选: payload==0 且 win==0 的段 (stall_probe 注入) —— 打印其 t/seq/ack/win;
#     (5) 时间线: 每次探询前后 ±N ms 内的对端段 (J-P2: 对端 ACK 是否带回真窗);
#     (6) BOARD->PEER 数据段 (payload>0) 的长度直方图 + 每连接首/末数据时刻 (stal 起始的见证).
#   用法: python3 probe_analyze.py <TAG> <pcap> [<pcap> ...]
import struct
import sys
import collections

BOARD = "192.168.100.2"
PEER = "192.168.100.100"


def read_pcap(path):
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
            print("BAD_HEADER %s" % path)
            return
        magic = struct.unpack("<I", gh[:4])[0]
        if magic in (0xA1B2C3D4, 0xA1B23C4D):
            endian = "<"
        elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
            endian = ">"
        else:
            print("BAD_MAGIC %s 0x%08X" % (path, magic))
            return
        while True:
            hdr = f.read(16)
            if len(hdr) < 16:
                break
            ts, tu, caplen, origlen = struct.unpack(endian + "IIII", hdr)
            data = f.read(caplen)
            if len(data) < caplen:
                break
            yield (ts + tu * 1e-6, data, caplen, origlen)


def parse(eth):
    if len(eth) < 34:
        return None
    ip = eth[14:]
    if (ip[0] >> 4) != 4 or ip[9] != 6:
        return None
    ihl = (ip[0] & 0xF) * 4
    tot = struct.unpack(">H", ip[2:4])[0]
    src = ".".join(str(b) for b in ip[12:16])
    dst = ".".join(str(b) for b in ip[16:20])
    tcp = ip[ihl:]
    if len(tcp) < 20:
        return None
    sport, dport = struct.unpack(">HH", tcp[0:4])
    seq, ack = struct.unpack(">II", tcp[4:12])
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    win = struct.unpack(">H", tcp[14:16])[0]
    plen = max(0, tot - ihl - doff)
    payload = bytes(tcp[doff:doff + plen]) if plen else b""
    return dict(t=0.0, src=src, dst=dst, sport=sport, dport=dport, seq=seq, ack=ack,
                flags=flags, win=win, plen=plen, payload=payload)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    tag = sys.argv[1]
    files = sys.argv[2:]
    segs = []
    for p in files:
        for ts, data, caplen, origlen in read_pcap(p):
            r = parse(data)
            if r is None:
                continue
            r["t"] = ts
            r["pcap"] = p.split("/")[-1]
            r["trunc"] = (caplen < origlen)
            segs.append(r)
    segs.sort(key=lambda x: x["t"])
    print("### ANALYZE tag=%s files=%d segs=%d t=[%.3f,%.3f]" %
          (tag, len(files), len(segs), segs[0]["t"] if segs else 0, segs[-1]["t"] if segs else 0))

    b2p = [s for s in segs if s["src"] == BOARD]
    p2b = [s for s in segs if s["src"] == PEER]
    print("### DIR b2p=%d p2b=%d trunc=%d" % (len(b2p), len(p2b), sum(1 for s in segs if s["trunc"])))

    print("--- SYN/SYN-ACK 窗口 (P-C 的 'SYN 就小' 见证) ---")
    for s in segs:
        if s["flags"] & 0x02:
            print("  SYN  t=%.6f %s:%d -> %s:%d seq=0x%08x win=%d plen=%d" %
                  (s["t"], s["src"], s["sport"], s["dst"], s["dport"], s["seq"], s["win"], s["plen"]))
        if (s["flags"] & 0x12) == 0x12:
            print("  SYNACK t=%.6f %s:%d -> %s:%d seq=0x%08x ack=0x%08x win=%d" %
                  (s["t"], s["src"], s["sport"], s["dst"], s["dport"], s["seq"], s["ack"], s["win"]))

    print("--- (3) BOARD->PEER payload==1 段 = 探询候选 (J-P1) ---")
    probes = [s for s in b2p if s["plen"] == 1]
    print("  PROBE_N %d" % len(probes))
    for s in probes:
        print("  PROBE t=%.6f sport=%d seq=0x%08x ack=0x%08x win=%d flags=0x%02x pay=0x%02x" %
              (s["t"], s["sport"], s["seq"], s["ack"], s["win"], s["flags"], s["payload"][0]))

    print("--- (3b) BOARD->PEER 小载荷直方图 (plen 0..8, 10, 20) ---")
    h = collections.Counter(s["plen"] for s in b2p if s["plen"] <= 20)
    print("  " + str(dict(sorted(h.items()))))

    print("--- (4) PEER->BOARD 注入候选 (payload==0 且 win==0) ---")
    inj = [s for s in p2b if s["plen"] == 0 and s["win"] == 0]
    print("  INJ_N %d" % len(inj))
    for s in inj[:40]:
        print("  INJ  t=%.6f sport=%d dport=%d seq=0x%08x ack=0x%08x win=%d flags=0x%02x" %
              (s["t"], s["sport"], s["dport"], s["seq"], s["ack"], s["win"], s["flags"]))

    print("--- (4b) PEER->BOARD 全部小载荷段直方图 + win 取值集合 ---")
    h2 = collections.Counter(s["plen"] for s in p2b if s["plen"] <= 20)
    print("  hist " + str(dict(sorted(h2.items()))))
    wset = collections.Counter(s["win"] for s in p2b)
    top = wset.most_common(12)
    print("  PEER_WIN_TOP " + str(top))

    print("--- (5) 每次探询 ±80 ms 内的对端段 (J-P2: ACK 带回真窗?) ---")
    for s in probes:
        near = [x for x in p2b if abs(x["t"] - s["t"]) <= 0.080]
        print("  PROBE t=%.6f seq=0x%08x -> 邻域对端段 %d 条" % (s["t"], s["seq"], len(near)))
        if len(near) > 60:
            print("    (邻域过多, 只打前 20 条)")
            near = near[:20]
        for x in near:
            print("    PEER t=%+.6f ack=0x%08x win=%d plen=%d flags=0x%02x" %
                  (x["t"] - s["t"], x["ack"], x["win"], x["plen"], x["flags"]))

    print("--- (6) 每 sport 的数据段统计 (stall 起始 = 末个数据帧时刻) ---")
    byconn = collections.defaultdict(list)
    for s in b2p:
        if s["plen"] > 0:
            byconn[s["sport"]].append(s)
    for k in sorted(byconn):
        v = byconn[k]
        first = v[0]["t"]
        last = v[-1]["t"]
        lens = collections.Counter(x["plen"] for x in v)
        print("  CONN sport=%d n=%d bytes=%d t=[%.3f,%.3f] dur=%.3f" %
              (k, len(v), sum(x["plen"] for x in v), first, last, last - first))
        print("     plen_hist(top8) %s" % (sorted(lens.items(), key=lambda kv: -kv[1])[:8],))
        print("     GAP>0.3s 的间隔:")
        gaps = 0
        for i in range(1, len(v)):
            d = v[i]["t"] - v[i - 1]["t"]
            if d > 0.3:
                gaps += 1
                print("       @%.6f gap=%.3f s (前一帧 t=%.6f plen=%d; 后一帧 t=%.6f plen=%d)" %
                      (v[i]["t"], d, v[i - 1]["t"], v[i - 1]["plen"], v[i]["t"], v[i]["plen"]))
                if gaps > 8:
                    print("       ...")
                    break
    return 0


if __name__ == "__main__":
    sys.exit(main())
