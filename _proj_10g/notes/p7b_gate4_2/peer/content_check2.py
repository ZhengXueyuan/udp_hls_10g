"""content_check2.py — F3 独立内容判据 (偏移 0 锚定, 游标式)

期望来源 = rtl/app_udp_pattern.v:6-7 的明文图案定义, 本脚本按同一算式**独立复算**:
    s ^= s<<13; s ^= s>>7; s ^= s<<17 ; 每步输出 s[31:24] ; 种子 0x9E3779B97F4A7C15, 先取后推进
判据:
  J1 每一帧(UDP 载荷) 逐字节 == 流上某偏移处的 1472 字节
  J2 该偏移必须是 1472 的整数倍 (帧 = 流上的 1472B 对齐块)
  J3 偏移随抓包顺序严格递增, 且步长为 1472 的整数倍
  J4 第 1 帧的偏移 == 0 (重烧后发生器从 0 起 —— 这条把"抓包漏了首帧"与"内容错"分开)
"""
import struct, sys, collections

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1
BOARD_IP = '192.168.100.2'


def xs(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def stream(n, off=0):
    t = SEED
    for _ in range(off):
        t = xs(t)
    out = bytearray()
    for _ in range(n):
        out.append((t >> 24) & 0xFF)
        t = xs(t)
    return bytes(out)


def read_pcap(path):
    d = open(path, 'rb').read()
    mg = struct.unpack('<I', d[:4])[0]
    if mg == 0xA1B2C3D4:
        ns = False
    elif mg == 0xA1B23C4D:
        ns = True
    else:
        raise SystemExit('not little-endian pcap: %08x' % mg)
    p, out = 24, []
    while p + 16 <= len(d):
        ts, tus, cl, wl = struct.unpack('<IIII', d[p:p + 16])
        p += 16
        out.append((ts + tus / (1e9 if ns else 1e6), d[p:p + cl], wl))
        p += cl
    return out


def main():
    path = sys.argv[1]
    pkts = read_pcap(path)
    frames = []
    for ts, pkt, wl in pkts:
        if len(pkt) < 42:
            continue
        if struct.unpack('!H', pkt[12:14])[0] != 0x0800:
            continue
        ihl = (pkt[14] & 0xF) * 4
        src = '.'.join(str(b) for b in pkt[26:30])
        udp = 14 + ihl
        dport = struct.unpack('!H', pkt[udp + 2:udp + 4])[0]
        ulen = struct.unpack('!H', pkt[udp + 4:udp + 6])[0]
        if src != BOARD_IP or dport != 8081:
            continue
        pay = pkt[udp + 8:udp + ulen]
        frames.append((ts, pay))
    print('pcap=%s  总包=%d  其中"板子->本机 :8081"=%d' % (path, len(pkts), len(frames)))
    if not frames:
        print('  没有板子的帧 ⇒ 结论不可下')
        return 1
    lens = collections.Counter(len(p) for _, p in frames)
    print('  载荷长度分布 = %s' % dict(lens))
    # 游标式定位: 从 0 起, 允许向前跳过若干帧 (被抓包丢掉的那些)
    cur = 0
    offs, bad = [], 0
    WIN = 3000          # 最多向前找 3000 帧 (3000*1472 = 4.4 MB)
    for i, (ts, pay) in enumerate(frames):
        n = len(pay)
        found = None
        for k in range(WIN):
            cand = cur + k * 1472
            if stream(n, cand) == pay:
                found = cand
                break
        if found is None:
            bad += 1
            if bad <= 3:
                print('  [BAD] 第 %d 帧 (偏移游标 %d 起 %d 帧内) 找不到匹配: len=%d head=%s'
                      % (i, cur, WIN, n, pay[:16].hex()))
            continue
        offs.append((i, found, n))
        cur = found + 1472
    print('  逐字节等于图案流 (1472 对齐) 的帧 = %d ; 不匹配 = %d' % (len(offs), bad))
    if offs:
        print('  J4 第 1 帧偏移 = %d  %s' % (offs[0][1], '(==0 ✅ 首帧锚定)' if offs[0][1] == 0 else '(≠0 —— 首帧可能被抓包漏掉)'))
        print('  J2 全部偏移为 1472 整数倍 = %s' % all(o % 1472 == 0 for _, o, _ in offs))
        steps = [offs[j + 1][1] - offs[j][1] for j in range(len(offs) - 1)]
        print('  J3 偏移严格递增 = %s ; 步长/1472 分布(前 8) = %s'
              % (all(s > 0 for s in steps), dict(list(collections.Counter(s // 1472 for s in steps).items())[:8])))
        print('  覆盖的流区间 = [%d, %d) 共 %d 帧 (%.2f%% 的 1472B 块被逐字节验证)'
              % (offs[0][1], offs[-1][1] + offs[-1][2], len(offs), 100.0 * len(offs) / (offs[-1][1] // 1472 + 1)))
        dt = frames[-1][0] - frames[0][0]
        if dt > 0:
            print('  抓包时间戳: 首 %.6f 末 %.6f Δ=%.6f s ⇒ %d 帧期间 %.0f fps (下界)'
                  % (frames[0][0], frames[-1][0], dt, len(frames), (len(frames) - 1) / dt))
    return 0


sys.exit(main())
