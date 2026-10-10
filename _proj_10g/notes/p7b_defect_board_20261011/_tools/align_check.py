#!/usr/bin/env python3
# align_check.py -- 流-图案对齐核查 (块级快路径 + 断点细扫)
#   目的: 判定"某个连接的线上字节流 = 图案序列的哪一段" (持续对齐? 有断点?)
#   口径: 对齐定义 = 存在 K 使 stream[i] == pat[K+i]; 逐块 (4096B) 用切片比较 (C 速度);
#         断点处逐字节定位, 并在 ±2^20 内搜新的 K (32 字节窗口).
#   用法: python3 align_check.py <pcap...> <sport>
import struct, sys

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1
_buf = bytearray()
_s = SEED


def pat_at(start, n):
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
        endian = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
        while True:
            hdr = f.read(16)
            if len(hdr) < 16:
                break
            ts, tu, caplen, origlen = struct.unpack(endian + "IIII", hdr)
            data = f.read(caplen)
            if len(data) < caplen:
                break
            yield (ts + tu * 1e-6, data)


def parse_tcp(eth):
    if len(eth) < 34:
        return None
    ip = eth[14:]
    if (ip[0] >> 4) != 4 or ip[9] != 6:
        return None
    ihl = (ip[0] & 0xF) * 4
    tot = struct.unpack(">H", ip[2:4])[0]
    tcp = ip[ihl:]
    sport, dport = struct.unpack(">HH", tcp[0:4])
    seq = struct.unpack(">I", tcp[4:8])[0]
    doff = (tcp[12] >> 4) * 4
    payload = bytes(tcp[doff:tot - ihl]) if tot >= ihl + doff else b""
    return (sport, dport, seq, payload)


def main():
    files = sys.argv[1:-1]
    sport = int(sys.argv[-1])
    segs = []
    for p in files:
        for ts, data in read_pcap(p):
            r = parse_tcp(data)
            if r is None:
                continue
            s, d, seq, pl = r
            if s != sport or not pl:
                continue
            segs.append((seq, pl))
    if not segs:
        print("NO_SEGS")
        return
    segs.sort(key=lambda x: x[0])
    base = segs[0][0]
    n = max((s - base) & 0xFFFFFFFF for s, _ in segs) + len(segs[-1][1])
    buf = bytearray(n)
    for s, pl in segs:
        buf[(s - base) & 0xFFFFFFFF:(s - base) & 0xFFFFFFFF + len(pl)] = pl
    print("ALIGN_CHECK segs=%d n=%d" % (len(segs), n))
    W = 32
    w0 = bytes(buf[0:W])
    K0 = None
    for K in range(0, 1 << 23):
        if pat_at(K, W) == w0:
            K0 = K
            break
    print("K0=%s" % K0)
    if K0 is None:
        return
    # 块级快路径
    CH = 4096
    K = K0
    i = 0
    breaks = []
    while i < n - W:
        ln = min(CH, n - i)
        if pat_at(K + i, ln) == bytes(buf[i:i + ln]):
            i += ln
            continue
        # 细扫: 找断点
        bp = i
        while bp < n - W and pat_at(K + bp, 8) == bytes(buf[bp:bp + 8]):
            bp += 4
        # 定位到字节
        while bp > i and pat_at(K + bp - 1, 8) != bytes(buf[bp - 1:bp + 7]):
            bp -= 1
        # 搜新 K
        newK = None
        newi = None
        for j in range(bp, min(n - W, bp + 65536)):
            w = bytes(buf[j:j + W])
            base_cand = K + j
            for d in list(range(0, 65537)) + [-x for x in range(1, 65537)]:
                c = base_cand + d
                if c >= 0 and pat_at(c, W) == w:
                    newK, newi = c, j
                    break
            if newK is not None:
                break
        breaks.append((bp, K, newK, newi))
        print("BREAK @%d (K was %d) -> newK=%s new_pos=%s" % (bp, K, newK, newi))
        if newK is None:
            break
        K = newK
        i = newi
        if len(breaks) > 10:
            print("... more breaks")
            break
    print("BREAKS %d  最终对齐 K=%d  已核字节=%d/%d" % (len(breaks), K, i, n))


if __name__ == "__main__":
    main()
