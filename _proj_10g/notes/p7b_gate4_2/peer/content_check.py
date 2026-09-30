"""content_check.py — 独立内容判据 (不依赖被验收的工具/板子自报)

输入: tcpdump 抓的 pcap (udp port 8081, 板子 -> 本机)
判据 (期望来源 = rtl/app_udp_pattern.v:6-7 的明文图案定义, 本脚本按同一算式独立复算):
  1. 每个 UDP 载荷必须**逐字节**等于 xorshift64 流上某个偏移处的 1472 字节
  2. 该偏移必须是 **1472 的整数倍**  (帧 = 流上的 1472B 对齐块)
  3. 相邻捕获帧的偏移必须**严格递增**且差值为 1472 的整数倍 (掉帧也保持对齐)
另外打印 **帧间隔**(pcap 时间戳) ⇒ 对"板侧自报 105,985 fps vs 网卡计数 111,124 fps"
给出第三个独立口径 (抓包点 = 驱动队列, 但时间戳是内核收包时刻, 做速率判别够用)。
"""
import struct, sys, collections

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def xs(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def pattern(n, off=0, chunk=1 << 20):
    """返回流上 [off, off+n) 的字节"""
    t = SEED
    for _ in range(off):
        t = xs(t)
    out = bytearray()
    while len(out) < n:
        m = min(chunk, n - len(out))
        for _ in range(m):
            out.append((t >> 24) & 0xFF)
            t = xs(t)
    return bytes(out)


def read_pcap(path):
    d = open(path, 'rb').read()
    magic = struct.unpack('<I', d[:4])[0]
    if magic == 0xA1B2C3D4:
        end, ns = '<', False
    elif magic == 0xA1B23C4D:
        end, ns = '<', True
    elif magic == 0xD4C3B2A1:
        end, ns = '>', False
    else:
        raise SystemExit('not a pcap: magic=%08x' % magic)
    p = 24
    out = []
    while p + 16 <= len(d):
        ts, tus, caplen, wl = struct.unpack(end + 'IIII', d[p:p + 16])
        p += 16
        pkt = d[p:p + caplen]
        p += caplen
        out.append((ts + tus / (1e9 if ns else 1e6), pkt, wl))
    return out


def main():
    path = sys.argv[1]
    pkts = read_pcap(path)
    print('pcap=%s  帧数=%d' % (path, len(pkts)))
    offs = []
    bad = 0
    for t, pkt, wl in pkts:
        if len(pkt) < 42 + 8 + 4:
            continue
        eth_type = struct.unpack('!H', pkt[12:14])[0]
        if eth_type != 0x0800:
            continue
        ihl = (pkt[14] & 0xF) * 4
        ip_total = struct.unpack('!H', pkt[16:18])[0]
        udp = 14 + ihl
        dport = struct.unpack('!H', pkt[udp + 2:udp + 4])[0]
        ulen = struct.unpack('!H', pkt[udp + 4:udp + 6])[0]
        pay = pkt[udp + 8:udp + ulen]
        if dport != 8081:
            continue
        # 在流上找该载荷的偏移 (只对前 24 字节做 probe, 再逐字节全比)
        probe = pay[:24]
        off = None
        # 帧数少, 直接线性扫 0..1.2M 步以内 (用 1472 对齐先验加速: 只在 1472 倍数上试)
        k = 0
        t0 = SEED
        cache = {}
        # 直接滑窗: 先生成 0..(2048*1472) 的流太大 ⇒ 改用"按 1472 步进试"
        for cand in range(0, 2048 * 1472, 1472):
            if pattern(len(probe), cand) == probe:
                off = cand
                break
        if off is None:
            bad += 1
            if bad <= 3:
                print('  [BAD] 载荷前 24B 不在任何 1472 对齐偏移上: %s' % probe.hex())
            continue
        if pattern(len(pay), off) != pay:
            bad += 1
            if bad <= 3:
                print('  [BAD] 偏移 %d 处载荷不全等' % off)
            continue
        offs.append(off)
    print('对齐到图案流的帧 = %d ; 不匹配 = %d' % (len(offs), bad))
    mono = all(offs[i] < offs[i + 1] for i in range(len(offs) - 1))
    steps = collections.Counter((offs[i + 1] - offs[i]) // 1472 for i in range(len(offs) - 1))
    print('偏移严格递增 = %s ; 步长(帧)分布 = %s' % (mono, dict(list(steps.items())[:8])))
    if len(pkts) >= 2:
        dt = pkts[-1][0] - pkts[0][0]
        print('抓包时间戳: 首帧 %.6f 末帧 %.6f  Δ=%.6f s  ⇒ %d 帧期间 %.0f fps'
              % (pkts[0][0], pkts[-1][0], dt, len(pkts), (len(pkts) - 1) / dt if dt else 0))
        print('  (注意: 中间若被 pcap 丢帧, fps 会偏低 —— 与板侧 105985 / 网卡 111124 比)')


main()
