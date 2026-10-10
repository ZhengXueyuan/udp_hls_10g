#!/usr/bin/env python3
# stream_zoom.py -- 单个连接的字节流"断点解剖": 找对齐曲线 A(i) (stream[i] == pat[A(i)+i])
#   用法: python3 stream_zoom.py <pcap...> <dport> [maxbytes]
#   输出: 对齐段表 (段起点, 长度, 对齐偏移) + 断点附近的原始字节 + 断点处的重对齐搜索结果
import struct, sys, collections

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
    dport = int(sys.argv[-1])
    segs = []
    for p in files:
        for ts, data in read_pcap(p):
            r = parse_tcp(data)
            if r is None:
                continue
            sport, d, seq, pl = r
            if d != dport or not pl:
                continue
            segs.append((seq, pl, ts))
    segs.sort(key=lambda x: x[0])
    base = segs[0][0]
    n = max((s - base) & 0xFFFFFFFF for s, _, _ in segs) + len(segs[-1][1])
    buf = bytearray(n)
    fill = bytearray(n)
    for s, pl, ts in segs:
        o = (s - base) & 0xFFFFFFFF
        buf[o:o + len(pl)] = pl
        fill[o:o + len(pl)] = b"\x01" * len(pl)
    print("ZOOM dport=%d segs=%d n=%d holes=%d" % (dport, len(segs), n, fill.count(0)))
    # 找首个非零
    st = fill.find(1)
    print("first_filled=%d last_filled=%d" % (st, fill.rfind(1)))
    # 对齐曲线: 从 st 起, 找 A 使 stream[st:st+32] == pat[A:...]
    W = 32
    w0 = bytes(buf[st:st + W])
    found = []
    for A in range(0, 1 << 22):
        if pat_at(A, W) == w0:
            found.append(A)
            if len(found) >= 4:
                break
    print("ALIGN_CANDIDATES at st=%d : %s" % (st, found))
    if not found:
        return
    A = found[0]
    # 沿流前进; 断点处搜索新对齐 (允许 ±2^22)
    i = st
    cur = A
    segs_out = []
    seg_start = i
    while i < n - W:
        if pat_at(cur + (i - st), W) == bytes(buf[i:i + W]):
            i += W
            continue
        segs_out.append((seg_start - st, i - seg_start, cur))
        # 细扫: 逐字节找断点
        bp = None
        for k in range(0, W + 1):
            if pat_at(cur + (i + k - st), W) != bytes(buf[i + k:i + k + W]):
                bp = i + k
                break
        if bp is None:
            bp = i
        newi = None
        newcur = None
        for k in range(0, 65536):
            j = bp + k
            if j + W > n:
                break
            w = bytes(buf[j:j + W])
            for d in list(range(0, 4097)) + [65536, -65536, 131072, -131072, 65536 + 8, 65536 - 8]:
                c = cur + (j - st) + d
                if c >= 0 and pat_at(c, W) == w:
                    newi, newcur = j, c
                    break
            if newi is not None:
                break
        print("BREAK at stream pos %d (rel %d): next align at %s (cur_off %s)"
              % (bp, bp - st, newi, newcur))
        # 打印断点附近 24 字节 + 两个候选偏移下的图案
        lo = max(0, bp - 16)
        print("  bytes[%d:%d] = %s" % (lo, bp + 16, bytes(buf[lo:bp + 16]).hex()))
        if newi is not None:
            print("  pat(old off) = %s" % pat_at(cur + (lo - st), bp + 16 - lo).hex())
            print("  pat(new off) = %s" % pat_at(newcur + (lo - newi), bp + 16 - lo).hex())
        if newi is None:
            print("  找不到重对齐 (k 扫描 65536 / d 扫描 ±4096+2^17) -> 该断点后无对齐")
            break
        i = newi
        cur = newcur
        seg_start = i
    if i < n - W:
        segs_out.append((seg_start - st, i - seg_start, cur))
    print("ALIGN_SEGMENTS %d:" % len(segs_out))
    for o, ln, c in segs_out[:20]:
        print("   rel_start=%d len=%d align_off=%d" % (o, ln, c))


if __name__ == "__main__":
    main()
