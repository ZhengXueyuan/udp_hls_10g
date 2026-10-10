#!/usr/bin/env python3
# pcap_tcp.py -- 微窗 stall 轮: 极简 pcap 解析 (Ethernet+IPv4+TCP), 无外部依赖
#   用法: python pcap_tcp.py <file.pcap> [summary|frames|acks|raw]
#   输出字段: t / 方向 / flags / seq / ack / win / len
import struct, sys, collections

def read_pcap(path):
    data = open(path, "rb").read()
    if len(data) < 24:
        return []
    magic, = struct.unpack("<I", data[:4])
    if magic == 0xa1b2c3d4:
        end = "<"
    elif magic == 0xd4c3b2a1:
        end = ">"
    else:
        end = "<"
    out = []
    off = 24
    while off + 16 <= len(data):
        ts_s, ts_us, incl, orig = struct.unpack(end + "IIII", data[off:off+16])
        off += 16
        pkt = data[off:off+incl]
        off += incl
        if len(pkt) < 34:
            continue
        eth_type = struct.unpack(">H", pkt[12:14])[0]
        if eth_type != 0x0800:
            continue
        ip = pkt[14:]
        if len(ip) < 20 or (ip[0] >> 4) != 4:
            continue
        ihl = (ip[0] & 0xF) * 4
        tot = struct.unpack(">H", ip[2:4])[0]
        proto = ip[9]
        src = ".".join(str(b) for b in ip[12:16])
        dst = ".".join(str(b) for b in ip[16:20])
        if proto != 6:
            out.append(dict(t=ts_s + ts_us/1e6, src=src, dst=dst, proto=proto))
            continue
        tcp = ip[ihl:]
        if len(tcp) < 20:
            continue
        sport, dport, seq, ack, off_flags, win = struct.unpack(">HHIIHH", tcp[:16])
        doff = (off_flags >> 12) * 4
        flags = off_flags & 0x1FF
        fl = []
        for bit, name in ((0x100, "NS"), (0x80, "CWR"), (0x40, "ECE"), (0x20, "URG"),
                          (0x10, "ACK"), (0x08, "PSH"), (0x04, "RST"), (0x02, "SYN"), (0x01, "FIN")):
            if flags & bit:
                fl.append(name)
        opts = tcp[20:doff] if doff > 20 else b""
        out.append(dict(t=ts_s + ts_us/1e6, src=src, dst=dst, sport=sport, dport=dport,
                        seq=seq, ack=ack, win=win, flags=".".join(fl) or "-",
                        plen=max(0, tot - ihl - doff), opts=opts))
    return out

def optstr(o):
    if not o:
        return "(无)"
    i = 0
    names = {0: "EOL", 1: "nop", 2: "mss", 3: "wscale", 4: "sackOK", 5: "sack", 8: "TS"}
    res = []
    while i < len(o):
        k = o[i]
        if k == 0:
            res.append("EOL"); break
        if k == 1:
            res.append("nop"); i += 1; continue
        if i + 1 >= len(o):
            break
        ln = o[i+1]
        if ln < 2 or i + ln > len(o):
            break
        body = o[i+2:i+ln]
        if k == 2:
            res.append("mss %d" % struct.unpack(">H", body[:2])[0])
        elif k == 3:
            res.append("wscale %d" % body[0])
        elif k == 4:
            res.append("sackOK")
        elif k == 8:
            res.append("TS val=%d ecr=%d" % struct.unpack(">II", body[:8]))
        else:
            res.append("opt%d(%s)" % (k, body.hex()))
        i += ln
    return ",".join(res)

def main():
    path, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "summary")
    pk = read_pcap(path)
    tcp = [p for p in pk if "seq" in p]
    print("# file=%s packets=%d (tcp=%d)" % (path, len(pk), len(tcp)))
    if not tcp:
        return
    t0 = tcp[0]["t"]
    # 谁是谁: **端口 8080 = 板**(服务端, 192.168.100.2); 客户端(对端 sink)用临时端口
    for p in tcp:
        p["dir"] = "BOARD->PEER" if p["sport"] == 8080 else "PEER->BOARD"
    if mode == "raw":
        for p in tcp:
            print("%.6f %-12s %-10s seq=%-10d ack=%-10d win=%-6d len=%-5d %s" % (
                p["t"] - t0, p["dir"], p["flags"], p["seq"], p["ack"], p["win"], p["plen"],
                optstr(p.get("opts", b"")) if ("SYN" in p["flags"]) else ""))
        return
    if mode == "frames":
        for p in tcp:
            if p["dir"] == "BOARD->PEER" and p["plen"] > 0:
                print("%.6f seq=%d len=%d flags=%s win=%d" % (p["t"]-t0, p["seq"], p["plen"], p["flags"], p["win"]))
        return
    if mode == "classify":
        # 逐帧分类: 板的每个数据帧 seq 相对"当时的对端 rcv_nxt 估计"(= 已见 ACK 的最大 ack 号)
        # 分类 = OLD(已交付过) / EDGE(恰在 rcv_nxt, 窗>0 会被收) / BEYOND(在 rcv_nxt 之后 = 洞)
        board = [p for p in tcp if p["dir"] == "BOARD->PEER" and p["plen"] > 0]
        peer = [p for p in tcp if p["dir"] == "PEER->BOARD"]
        rcvnxt = None; lastwin = None
        i = 0; hist = collections.Counter(); rows = []
        for p in board:
            while i < len(peer) and peer[i]["t"] <= p["t"]:
                q = peer[i]
                if q["win"] is not None:
                    lastwin = q["win"]
                if q["plen"] == 0 and q["ack"]:
                    rcvnxt = q["ack"] if rcvnxt is None else max(rcvnxt, q["ack"])
                i += 1
            if rcvnxt is None:
                cls = "PRE_ACK"
            elif p["seq"] + p["plen"] <= rcvnxt:
                cls = "OLD"
            elif p["seq"] == rcvnxt:
                cls = "EDGE"
            else:
                cls = "BEYOND"
            hist[cls] += 1
            rows.append((p["t"]-t0, p["seq"], p["plen"], rcvnxt, lastwin, cls))
        print("== 逐帧分类直方 (板 %d 个数据帧) ==" % len(board))
        for k, v in hist.most_common():
            print("   %-8s %5d" % (k, v))
        print("== 关键演示 (= 每个分类的首帧 + 末 6 帧) ==")
        print("   t_rel     seq          rcv_nxt(估)  last_win  class")
        show = []
        seen = set()
        for r in rows:
            if r[5] not in seen:
                seen.add(r[5]); show.append(r)
        show += rows[-6:]
        for t, seq, ln, rn, w, c in show:
            print("   %7.4f  %10d  %10s  %8s  %s" % (t, seq, rn, w, c))
        print("== 对端 rcv_nxt (ACK 号) 轨迹 (每 0.02 s 内最后一个 ACK) ==")
        prevt = -1; last = None
        for q in peer:
            if q["plen"] == 0 and q["ack"]:
                tt = q["t"] - t0
                if tt - prevt >= 0.02 and q["ack"] != last:
                    print("   t=%7.4f ack=%10d win=%-6d" % (tt, q["ack"], q["win"]))
                    prevt = tt; last = q["ack"]
        return
    if mode == "acks":
        for p in tcp:
            if p["dir"] == "PEER->BOARD" and p["plen"] == 0:
                print("%.6f ack=%d win=%d flags=%s" % (p["t"]-t0, p["ack"], p["win"], p["flags"]))
        return
    # summary
    b2p = [p for p in tcp if p["dir"] == "BOARD->PEER"]
    p2b = [p for p in tcp if p["dir"] == "PEER->BOARD"]
    print("== 握手 (SYN 行) ==")
    for p in tcp:
        if "SYN" in p["flags"]:
            print("  %.6f %-12s seq=%d ack=%d win=%d options[%s]" % (
                p["t"]-t0, p["dir"], p["seq"], p["ack"], p["win"], optstr(p["opts"])))
    print("== 方向统计 ==")
    print("  BOARD->PEER: %d 包 (data=%d, empty=%d)" % (
        len(b2p), sum(1 for p in b2p if p["plen"] > 0), sum(1 for p in b2p if p["plen"] == 0)))
    print("  PEER->BOARD: %d 包 (data=%d, empty=%d)" % (
        len(p2b), sum(1 for p in p2b if p["plen"] > 0), sum(1 for p in p2b if p["plen"] == 0)))
    print("== 逐 0.25 s 桶: 板数据帧数 / 对端 ACK 数 / 对端 win 集合 ==")
    buckets = collections.OrderedDict()
    for p in tcp:
        b = int((p["t"]-t0)/0.25)
        e = buckets.setdefault(b, dict(df=0, da=0, acks=0, wins=set(), seqs=[]))
        if p["dir"] == "BOARD->PEER" and p["plen"] > 0:
            e["df"] += 1; e["seqs"].append(p["seq"])
        if p["dir"] == "PEER->BOARD":
            if p["plen"] == 0:
                e["acks"] += 1; e["wins"].add(p["win"])
            else:
                e["da"] += 1
    for b, e in sorted(buckets.items()):
        seqinfo = ""
        if e["seqs"]:
            seqinfo = " seq[min=%d max=%d uniq=%d]" % (min(e["seqs"]), max(e["seqs"]), len(set(e["seqs"])))
        print("  t=%.2f-%.2f 板data=%4d 对端ACK=%4d 对端data=%3d win=%s%s" % (
            b*0.25, b*0.25+0.25, e["df"], e["acks"], e["da"], sorted(e["wins"])[:6], seqinfo))
    print("== 板数据帧: 唯一 seq 数 / 重复率 ==")
    seqs = [p["seq"] for p in b2p if p["plen"] > 0]
    if seqs:
        print("  frames=%d uniq_seq=%d dup_ratio=%.3f  seq_min=%d seq_max=%d" % (
            len(seqs), len(set(seqs)), len(seqs)/max(1, len(set(seqs))), min(seqs), max(seqs)))
    print("== 对端 ACK: ack 号取值集合 (前 12) / win 取值集合 ==")
    acks = [p["ack"] for p in p2b if p["plen"] == 0]
    wins = collections.Counter(p["win"] for p in p2b)
    if acks:
        c = collections.Counter(acks)
        print("  唯一 ack 数=%d; 出现最多的 ack: %s" % (len(c), c.most_common(8)))
        print("  win 直方: %s" % wins.most_common(8))
    print("== 最后一幕 (末 12 包) ==")
    for p in tcp[-12:]:
        print("  %.6f %-12s %-8s seq=%d ack=%d win=%d len=%d" % (
            p["t"]-t0, p["dir"], p["flags"], p["seq"], p["ack"], p["win"], p["plen"]))

if __name__ == "__main__":
    main()
