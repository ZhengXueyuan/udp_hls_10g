#!/usr/bin/env python3
# replay_audit.py -- 重放内容审计 (自洽口径, 不依赖图案对齐):
#   TEST-1 【同一 seq 的内容是否恒定】: 把每次传输的 (seq,len) 载荷与**首次**传输的同一 seq 区间逐字节比
#          => 任何"同 seq 不同字节" = 该次重放读到的环内容与首传不同 (= 环被覆写/读到陈旧字节的直接签名)
#   TEST-2 【上一圈自比】: 流 S[i] 与 S[i-65536] 的逐字节相同率 (随机期望 1/256; 显著高于 = 读到上一圈字节)
#   TEST-3 【重放冗余率】: 总线上数据字节 / 唯一 seq 覆盖字节
#   用法: python3 replay_audit.py <pcap...> <dport>
import struct, sys, collections

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


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
    dport = int(sys.argv[-1])  # 这里传的是 **sport** (板侧 8080)
    segs = []
    for p in files:
        for ts, data in read_pcap(p):
            r = parse_tcp(data)
            if r is None:
                continue
            sport, d, seq, pl = r
            if sport != dport:
                continue
            segs.append((ts, seq, pl))
    segs.sort(key=lambda x: x[0])
    print("AUDIT dport=%d total_segments=%d" % (dport, len(segs)))
    # 首传内容: 用 bytearray 按 seq 落位; 每次写入前与已有内容比 (不同 = 同 seq 内容变了)
    base = None
    for ts, seq, pl in segs:
        if pl:
            base = seq
            break
    nmax = 0
    for ts, seq, pl in segs:
        if pl:
            nmax = max(nmax, (seq - base) & 0xFFFFFFFF + len(pl))
    buf = bytearray(nmax)
    fill = bytearray(nmax)
    tot_bytes = 0
    changes = []
    replayed_bytes = 0
    for ts, seq, pl in segs:
        if not pl:
            continue
        tot_bytes += len(pl)
        o = (seq - base) & 0xFFFFFFFF
        old = buf[o:o + len(pl)]
        oldfill = fill[o:o + len(pl)]
        if b"\x01" * len(pl) == oldfill:
            if old != pl:
                # 逐字节定位
                firstdiff = next(k for k in range(len(pl)) if old[k] != pl[k])
                ndiff = sum(1 for k in range(len(pl)) if old[k] != pl[k])
                changes.append((ts, seq, len(pl), ndiff, firstdiff))
                print("CONTENT_CHANGE t=%.6f seq=0x%08x len=%d diff_bytes=%d first_off=%d got=0x%02x old=0x%02x"
                      % (ts, seq, len(pl), ndiff, firstdiff, pl[firstdiff], old[firstdiff]))
        else:
            replayed_bytes += len(pl)
        buf[o:o + len(pl)] = pl
        fill[o:o + len(pl)] = b"\x01" * len(pl)
    print("TOT_BYTES %d UNIQ_BYTES %d REDUNDANCY %.6f REPLAY_BYTES %d"
          % (tot_bytes, fill.count(1), tot_bytes / max(1, fill.count(1)), replayed_bytes))
    print("CONTENT_CHANGES %d" % len(changes))
    # TEST-2: 上一圈自比 (按 seq 偏移拼流, 以 ISN+1 为 0)
    if segs:
        base = None
        for ts, seq, pl in segs:
            if pl:
                base = seq
                break
        n = max((s - base) & 0xFFFFFFFF for s, p in [(x[1], x[2]) for x in segs if x[2]]) + 1
        buf = bytearray(n)
        fill = bytearray(n)
        for ts, seq, pl in segs:
            if not pl:
                continue
            o = (seq - base) & 0xFFFFFFFF
            buf[o:o + len(pl)] = pl
            fill[o:o + len(pl)] = b"\x01" * len(pl)
        holes = fill.count(0)
        print("STREAM n=%d holes=%d" % (n, holes))
        if n > 65536:
            hit = 0
            tot = 0
            runs = []
            run = 0
            for i in range(65536, n):
                if fill[i] and fill[i - 65536]:
                    tot += 1
                    if buf[i] == buf[i - 65536]:
                        hit += 1
                        run += 1
                    else:
                        if run >= 4:
                            runs.append((i - run, run))
                        run = 0
            if run >= 4:
                runs.append((n - run, run))
            print("LAP_COMPARE hits=%d/%d rate=%.6f (随机期望 %.6f) runs>=4: %d"
                  % (hit, tot, hit / max(1, tot), 1 / 256.0, len(runs)))
            for o, l in runs[:15]:
                print("   LAPRUN @%d len=%d (seq=0x%08x)" % (o, l, (base + o) & 0xFFFFFFFF))


if __name__ == "__main__":
    main()
