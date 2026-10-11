#!/usr/bin/env python3
# arm_analyze.py -- P7b snd_wnd 守卫板级轮: 逐臂行为分析 (探询 / 注入帧上线 / 注入窗内板帧 / 数据帧间隙)
#   口径:
#     (1) PROBE  = 板->对端 payload==1 ∧ flags==0x18 (显式声明: 此口径只看字节数, 不判语义)
#     (2) INJ    = 对端->板 payload==0 且 (ack,win) == 探针日志里的某个 PROBE_INJECT 行 (用原始值匹配)
#     (3) 板帧时间线 = 板->对端所有 TCP 帧 (payload 任意) 的 t/seq/plen —— 以探针日志的 SYN 时刻为 0 点
#     (4) 注入前后窗统计: [t_inj-0.5, t_inj+2.0] 内板帧数/字节数; 以及 [t_inj-0.05,+0.05] 内的帧
#   用法: python3 arm_analyze.py <probe.log> <capA.pcap> [capB.pcap] [capC/capD.pcap]
import struct, sys

BOARD = "192.168.100.2"
PEER = "192.168.100.100"

def read_pcap(path):
    try:
        f = open(path, "rb")
    except OSError as e:
        print("NO_FILE %s (%s)" % (path, e)); return
    gh = f.read(24)
    if len(gh) < 24:
        print("BAD_HEADER %s" % path); return
    magic = struct.unpack("<I", gh[:4])[0]
    endian = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    while True:
        hdr = f.read(16)
        if len(hdr) < 16: break
        ts, tu, caplen, origlen = struct.unpack(endian + "IIII", hdr)
        data = f.read(caplen)
        if len(data) < caplen: break
        yield (ts + tu * 1e-6, data, caplen, origlen)

def parse(eth):
    if len(eth) < 34: return None
    ip = eth[14:]
    if (ip[0] >> 4) != 4 or ip[9] != 6: return None
    ihl = (ip[0] & 0xF) * 4
    src = ".".join(str(b) for b in ip[12:16])
    tcp = ip[ihl:]
    if len(tcp) < 20: return None
    sport, dport = struct.unpack(">HH", tcp[0:4])
    seq, ack = struct.unpack(">II", tcp[4:12])
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    win = struct.unpack(">H", tcp[14:16])[0]
    plen = struct.unpack(">H", ip[2:4])[0] - ihl - doff
    if plen < 0: plen = 0
    return src, sport, dport, seq, ack, flags, win, plen

def main():
    probe_log, caps = sys.argv[1], sys.argv[2:]
    t0 = None; injs = []; syns = []
    for line in open(probe_log, encoding="utf-8", errors="replace"):
        if line.startswith("SNIFF_SYN"):
            p = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
            syns.append((float(p["t"]), int(p["lport"]), int(p["isn"])))
        elif line.startswith("PROBE_INJECT"):
            p = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
            injs.append({"i": int(p["i"]), "ack_abs": float(p["t"]),
                         "ack": int(p["ack"]), "win": int(p["win"]),
                         "src": p.get("ack_src", "?")})
    print("### SYN events: %s" % [(round(t, 3), lp, isn) for t, lp, isn in syns])
    if syns: t0 = syns[0][0]
    print("### INJECTIONS (probe.log):")
    for j in injs:
        print("  i=%d t=%.6f (SYN+%.3fs) ack=%d win=%d ack_src=%s" % (
            j["i"], j["ack_abs"], (j["ack_abs"] - t0) if t0 else -1, j["ack"], j["win"], j["src"]))

    allb = []
    for cap in caps:
        for ts, eth, cl, ol in read_pcap(cap):
            f = parse(eth)
            if f is None: continue
            src, sport, dport, seq, ack, flags, win, plen = f
            allb.append((ts, src, sport, dport, seq, ack, flags, win, plen, ol, cap))

    # (1) probes
    probes = [x for x in allb if x[1] == BOARD and x[2] == 8080 and x[8] == 1 and (x[6] & 0x18) == 0x18]
    probes.sort()
    print("### (1) PROBES (板->对端 payload==1 & flags 0x18): n=%d" % len(probes))
    for ts, src, sp, dp, seq, ack, flags, win, plen, ol, cap in probes:
        print("  t=%.6f (SYN+%s) seq=0x%08x ack=0x%08x win=%d origlen=%d [%s]" % (
            ts, ("%.3f" % (ts - t0)) if t0 else "?", seq, ack, win, ol, cap.split("/")[-1]))

    # (2) injected frames on the wire (peer->board with the exact (ack,win))
    print("### (2) INJECTED FRAMES on wire (对端->板 与日志 (ack,win) 匹配):")
    for j in injs:
        hits = [x for x in allb if x[1] == PEER and x[4] == (syns[0][2] + 1 if syns else -1)
                and x[5] == j["ack"] and x[7] == j["win"] and abs(x[0] - j["ack_abs"]) < 2.0]
        print("  i=%d expect ack=%d win=%d -> hits=%d %s" % (
            j["i"], j["ack"], j["win"], len(hits),
            ["t=%.6f" % h[0] for h in hits[:4]]))

    # (3)+(4) board frame timeline & injection windows
    bframes = sorted([x for x in allb if x[1] == BOARD and x[2] == 8080])
    print("### (3) BOARD FRAMES total=%d" % len(bframes))
    if bframes:
        print("  first t=%.6f last t=%.6f span=%.3fs" % (bframes[0][0], bframes[-1][0], bframes[-1][0] - bframes[0][0]))
        # per-0.5s histogram of data frames (plen>0)
        data = [x for x in bframes if x[8] > 0]
        print("  data frames (plen>0)=%d" % len(data))
        if data and t0:
            import collections
            h = collections.Counter(int((x[0] - t0) // 0.5) for x in data)
            print("  0.5s-bucket counts (SYN-relative): %s" % dict(sorted(h.items())))
    for j in injs:
        for w, tag in ((0.1, "-0.1..+0.1"), (0.5, "-0.5..+0.5"), (2.0, "-0.5..+2.0")):
            lo = j["ack_abs"] - (0.5 if w != 0.1 else 0.1)
            hi = j["ack_abs"] + w
            sel = [x for x in bframes if lo <= x[0] <= hi]
            nb = sum(x[8] + 40 for x in sel if x[8] > 0)
            print("### (4) inj i=%d window %s: frames=%d data_bytes~=%d %s" % (
                j["i"], tag, len(sel), nb, ["t=%.4f plen=%d" % (x[0] - j["ack_abs"], x[8]) for x in sel[:6]]))

if __name__ == "__main__":
    main()

# ---- 追加: 数据帧间隙分析 (给 R2/R3 用) ----
def gap_analysis(path, inj_times, label):
    ev = []
    for ts, eth, cl, ol in read_pcap(path):
        f = parse(eth)
        if f is None: continue
        src, sport, dport, seq, ack, flags, win, plen = f
        if src == BOARD and sport == 8080 and plen > 0:
            ev.append((ts, seq, plen))
    ev.sort()
    print("### GAP %s: data_frames=%d span=%.3fs" % (label, len(ev), (ev[-1][0]-ev[0][0]) if ev else 0))
    if not ev: return
    gaps = [(ev[i+1][0]-ev[i][0], ev[i][0], ev[i+1][0]) for i in range(len(ev)-1)]
    gs = sorted(g[0] for g in gaps)
    n = len(gs)
    def pct(p): return gs[min(n-1, int(n*p))]
    print("  gap p50=%.6f p90=%.6f p99=%.6f p999=%.6f max=%.6f (n=%d)" % (
        pct(0.5), pct(0.9), pct(0.99), pct(0.999), gs[-1], n))
    top = sorted(gaps, reverse=True)[:12]
    print("  top-12 gaps:")
    for g, a, b in top:
        print("    %.6f s  t=[%.6f .. %.6f] (SYN+%.3f..%.3f)" % (g, a, b, a-min(inj_times) if inj_times else -1, b-min(inj_times) if inj_times else -1))
    for t in inj_times:
        w = [g for g, a, b in gaps if t-0.3 <= a <= t+2.0]
        mx = max(w) if w else 0.0
        print("  inj t=%.6f -> max gap in [t-0.3,t+2.0]: %.6f s (%s)" % (t, mx, "HIT" if mx > pct(0.999) else "within p999"))
