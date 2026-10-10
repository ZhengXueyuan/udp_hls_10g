#!/usr/bin/env python3
# align_check2.py -- 相位校正后的内容核查 (有界版; 断点搜索有界 => 不会挂)
#   1) 拼流 (按 seq)  2) 用首 32 字节找对齐偏移 K0 (扫 0..2^22)  3) 逐 64KB 块核 stream[i] == pat[K0+i]
#   4) 首个不符处: 打印位置 + 有界重对齐搜索 (j in [bp,bp+256], d in ±65536), 最多 3 个断点
#   用法: python3 align_check2.py <pcap...> <sport>
import struct, sys

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1
CH = 65536


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
            yield data


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


def gen_pattern(start, n):
    """生成图案 [start, start+n) 的 bytes (逐字节, 与 app_pattern.v / p7b_pattern.h 同序)"""
    s = SEED
    for _ in range(start):
        s ^= (s << 13) & M64
        s ^= s >> 7
        s ^= (s << 17) & M64
        s &= M64
    out = bytearray(n)
    for i in range(n):
        out[i] = (s >> 24) & 0xFF
        s ^= (s << 13) & M64
        s ^= s >> 7
        s ^= (s << 17) & M64
        s &= M64
    return bytes(out)


def main():
    files = sys.argv[1:-1]
    sport = int(sys.argv[-1])
    segs = []
    for p in files:
        for data in read_pcap(p):
            r = parse_tcp(data)
            if r is None:
                continue
            s, d, seq, pl = r
            if s != sport or not pl:
                continue
            segs.append((seq, pl))
    if not segs:
        print("NO_SEGS", flush=True)
        return
    segs.sort(key=lambda x: x[0])
    base = segs[0][0]
    n = max((s - base) & 0xFFFFFFFF for s, _ in segs) + len(segs[-1][1])
    buf = bytearray(n)
    for s, pl in segs:
        o = (s - base) & 0xFFFFFFFF
        buf[o:o + len(pl)] = pl
    print("ALIGN2 segs=%d n=%d" % (len(segs), n), flush=True)
    w0 = bytes(buf[0:32])
    # K0 候选 = 用首 32 字节扫 (先生成 4 MB 图案即可覆盖常见偏移)
    head = gen_pattern(0, 1 << 22)
    K0 = head.find(w0)
    print("K0=%s" % K0, flush=True)
    if K0 < 0:
        return
    # 一次性生成 [0, K0+n) 图案 (单遍), 之后全是切片比较
    PAT = gen_pattern(0, K0 + n)
    print("PAT_GEN done len=%d" % len(PAT), flush=True)

    def align_ok(i, ln, K):
        return PAT[K + i:K + i + ln] == bytes(buf[i:i + ln])

    i = 0
    breaks = []
    while i < n:
        ln = min(CH, n - i)
        if align_ok(i, ln, K0):
            i += ln
            if (i // CH) % 500 == 0:
                print("  ... verified %d/%d" % (i, n), flush=True)
            continue
        bp = i
        while bp < n - 8 and align_ok(bp, 8, K0):
            bp += 1
        print("BREAK @%d (verified %d bytes before)" % (bp, bp), flush=True)
        breaks.append(bp)
        newK = None
        j2 = None
        for j in range(bp, min(n - 32, bp + 257)):
            w = bytes(buf[j:j + 32])
            for d in range(0, 65537):
                for c in (K0 + j + d, K0 + j - d):
                    if 0 <= c <= len(PAT) - 32 and PAT[c:c + 32] == w:
                        newK = c
                        break
                if newK is not None:
                    break
            if newK is not None:
                j2 = j
                break
        print("  newK=%s new_pos=%s" % (newK, j2), flush=True)
        if newK is None or len(breaks) >= 3:
            break
        K0 = newK
        i = j2
    print("ALIGN2_DONE verified_prefix=%d n=%d breaks=%d" % (i, n, len(breaks)), flush=True)


if __name__ == "__main__":
    main()
