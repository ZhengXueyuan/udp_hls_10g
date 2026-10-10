#!/usr/bin/env python3
# ghost_pcap.py -- P7B-RETXHI-GHOST 板级轮 A (S-0) 的 pcap 口径分析器 (板->对端方向)
#   口径 (逐条写在输出里, 便于复核):
#     (1) 板->对端 TCP 段全解 (seq/flags/payload), 按 (sport,dport) 归并成连接;
#     (2) 控制帧普查: SYN/FIN/RST 的次数 + seq + 时刻;
#     (3) 内容口径: 逐连接按 seq 拼字节流, 与参考图案 (xorshift64 / 种 0x9E3779B97F4A7C15 /
#         每字节 = (s>>24)&0xFF / 先取后推进 —— 与 rtl/app_pattern.v:5-6,30 同一数学) 比对:
#           a) CHK_BASE0  : 基偏移 0 (连接首字节 = 图案偏移 0; TX LFSR 在 ev_up 重置 ⇒ 应成立)
#           b) 对齐扫描   : 用流中任意 64 字节窗口找匹配偏移 (允许流首部有洞)
#           c) SHIFT 事件 : 流内**对齐偏移发生变化的位置** = "线上图案流里少/多了多少字节"
#                           (幽灵/丢字的直接签名: 位置 + 偏移变化量)
#     (4) seq 覆盖率: 洞 (对端没收到) / 重叠 (重传/重放);
#     (5) DATA_AFTER_CTRL: 任一 FIN/RST 之后该连接上仍出现的数据段 (形态① 幽灵的落点面).
#   用法: python3 ghost_pcap.py <pcap> [<pcap> ...]
import struct, sys, collections

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1

_buf = bytearray()
_s = SEED


def pat_at(start, n):
    """图案字节 [start, start+n)"""
    global _s
    need = start + n
    while len(_buf) < need:
        _buf.append((_s >> 24) & 0xFF)
        s = _s
        s ^= (s << 13) & M64
        s ^= s >> 7
        s ^= (s << 17) & M64
        _s = s & M64
    return bytes(_buf[start:start + n])


def read_pcap(path):
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
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
            yield (ts + tu * 1e-6, data, origlen)


def parse_tcp(eth):
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
    seq = struct.unpack(">I", tcp[4:8])[0]
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    payload = bytes(tcp[doff:tot - ihl]) if tot >= ihl + doff else b""
    return (src, dst, sport, dport, seq, flags, payload)


def build_stream(segs):
    """按 seq 拼流 (升序; 重叠保留先到)"""
    arr = sorted(segs, key=lambda x: x[0])
    n = max(s + len(p) for s, p in arr)
    buf = bytearray(n)
    filled = bytearray(n)
    for s, p in arr:
        buf[s:s + len(p)] = p
        filled[s:s + len(p)] = b"\x01" * len(p)
    return buf


def analyze_stream(tag, stream, first_seq):
    n = len(stream)
    print("  STREAM n=%d first_seq=0x%08x" % (n, first_seq))
    if n == 0:
        return
    CH = 4096
    # a) 基偏移 0
    mism = 0
    first = -1
    for st in range(0, n, CH):
        ln = min(CH, n - st)
        a = bytes(stream[st:st + ln])
        b = pat_at(st, ln)
        if a != b:
            for i in range(ln):
                if a[i] != b[i]:
                    mism += 1
                    if first < 0:
                        first = st + i
    print("  CHK_BASE0 mism=%d first=%d" % (mism, first))
    # b) 找对齐偏移 (用流中第一个 64 字节窗口, 在 0..300000 内扫)
    off0 = None
    probe = bytes(stream[0:64])
    if len(probe) == 64:
        for off in range(0, 300000):
            if pat_at(off, 64) == probe:
                off0 = off
                break
    print("  ALIGN_AT_START off=%s" % (off0,))
    if off0 is None:
        # 用流中间一个窗口找对齐
        mid = min(n // 2, n - 64)
        probe = bytes(stream[mid:mid + 64])
        for off in range(0, 300000):
            if pat_at(off - mid, 64) == probe if (off - mid) >= 0 else False:
                off0 = off
                break
        print("  ALIGN_AT_MID(mid=%d) off=%s" % (mid, off0))
    # c) 对齐跟踪: 假设 流[i] == pat[cur + i], 找第一个不符处; 再在流内找新的对齐偏移
    #    (窗口 32 字节, 搜索范围 ±262144) => 记录"偏移变化事件" (线上图案流的错位量)
    if off0 is not None:
        cur = off0
        i = 0
        events = []
        W = 32
        while i < n - W:
            if pat_at(cur + i, W) == bytes(stream[i:i + W]):
                i += W
                continue
            # 细扫流内位置 (逐字节), 同时搜新偏移
            new_i = None
            new_cur = None
            for k in range(0, 4096):
                j = i + k
                if j + W > n:
                    break
                w = bytes(stream[j:j + W])
                # 候选偏移: 以"旧曲线"为基准 ±262144
                base_cand = cur + j
                for d in (0, 1, 2, 3, 4, 6, 8, 16, 65536, -65536):
                    c = base_cand + d
                    if c >= 0 and pat_at(c, W) == w:
                        new_i, new_cur = j, c
                        break
                if new_i is None:
                    for d in list(range(5, 4097)) + [-x for x in range(5, 4097)]:
                        c = base_cand + d
                        if c >= 0 and pat_at(c, W) == w:
                            new_i, new_cur = j, c
                            break
                if new_i is not None:
                    break
            if new_i is None:
                events.append((i, "UNALIGNED_REST", None))
                break
            events.append((i, "SHIFT", new_cur - (cur + new_i)))
            cur = new_cur
            i = new_i
            if len(events) > 30:
                events.append((i, "MORE", None))
                break
        print("  SHIFT_EVENTS %d" % len(events))
        for i, kind, d in events[:30]:
            print("    @%d %s delta=%s" % (i, kind, d))


def main():
    files = sys.argv[1:]
    conns = collections.defaultdict(lambda: {"segs": [], "fin": [], "rst": [], "syn": [], "n": 0})
    total = 0
    for p in files:
        for ts, data, origlen in read_pcap(p):
            r = parse_tcp(data)
            if r is None:
                continue
            src, dst, sport, dport, seq, flags, payload = r
            c = conns[(sport, dport)]
            c["n"] += 1
            total += 1
            if flags & 0x02:
                c["syn"].append((ts, seq))
            if flags & 0x01:
                c["fin"].append((ts, seq))
            if flags & 0x04:
                c["rst"].append((ts, seq))
            if payload:
                c["segs"].append((ts, seq, payload))
    print("PCAP_FILES %d TOTAL_SEGS %d CONNS %d" % (len(files), total, len(conns)))
    for key in sorted(conns):
        c = conns[key]
        sport, dport = key
        nb = sum(len(p) for _, _, p in c["segs"])
        print("=" * 78)
        print("CONN sport=%hu dport=%hu segs=%d data_bytes=%d syn=%d fin=%d rst=%d"
              % (sport, dport, c["n"], nb, len(c["syn"]), len(c["fin"]), len(c["rst"])))
        for ts, seq in c["syn"]:
            print("  SYN t=%.6f seq=0x%08x" % (ts, seq))
        for ts, seq in c["fin"]:
            print("  FIN t=%.6f seq=0x%08x" % (ts, seq))
        for ts, seq in c["rst"]:
            print("  RST t=%.6f seq=0x%08x" % (ts, seq))
        if not c["segs"]:
            continue
        segs = sorted(c["segs"])
        base = segs[0][1]
        ivs = sorted((seq - base) & 0xFFFFFFFF for _, seq, _ in segs)
        # 洞/重叠
        cur = 0
        holes = []
        dups = 0
        for (ts, seq, pl) in sorted(segs, key=lambda x: (x[1] - base) & 0xFFFFFFFF):
            s = (seq - base) & 0xFFFFFFFF
            e = s + len(pl)
            if s > cur:
                holes.append((cur, s))
                cur = e
            elif s < cur:
                dups += 1
                cur = max(cur, e)
            else:
                cur = e
        span = max(s for s in ivs) if ivs else 0
        print("  SEQ first=0x%08x max_start_off=%d holes=%d dup_segs=%d"
              % (base, span, len(holes), dups))
        for h in holes[:10]:
            print("    HOLE [%d,%d) len=%d" % (h[0], h[1], h[1] - h[0]))
        # 时间线: 控制帧 vs 数据
        ev = [(ts, "D", seq, len(pl)) for ts, seq, pl in c["segs"]]
        ev += [(ts, "F", seq, 0) for ts, seq in c["fin"]]
        ev += [(ts, "R", seq, 0) for ts, seq in c["rst"]]
        ev.sort()
        last_ctrl = None
        after = []
        t_first_data = next((e[0] for e in ev if e[1] == "D"), None)
        t_last_data = max((e[0] for e in ev if e[1] == "D"), default=None)
        for e in ev:
            if e[1] in ("F", "R"):
                last_ctrl = e
            elif last_ctrl is not None:
                after.append((e[0] - last_ctrl[0], last_ctrl[1], e[2], e[3]))
        print("  TIMELINE t_data=[%.6f,%.6f] dur=%.3fs" % (t_first_data, t_last_data,
                                                           (t_last_data - t_first_data) if t_first_data else 0))
        for ts, seq in c["fin"]:
            print("    FIN at t=%.6f (t_first_data+%.3fs)" % (ts, ts - t_first_data if t_first_data else -1))
        for ts, seq in c["rst"]:
            print("    RST at t=%.6f (t_first_data+%.3fs)" % (ts, ts - t_first_data if t_first_data else -1))
        print("  DATA_AFTER_CTRL %d" % len(after))
        for dt, kind, seq, ln in sorted(after)[:12]:
            print("    +%.6fs after %s: seq=0x%08x len=%d" % (dt, kind, seq, ln))
        stream = build_stream([( (s - base) & 0xFFFFFFFF, p) for _, s, p in c["segs"]])
        analyze_stream(key, stream, base)


if __name__ == "__main__":
    main()
