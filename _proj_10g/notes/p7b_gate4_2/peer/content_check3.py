"""content_check3.py — F3 独立内容判据 (高效版: 流缓冲 + 游标搜索)

期望来源 = rtl/app_udp_pattern.v:6-7 的明文图案定义, 本脚本按同一算式**独立复算**:
    s ^= s<<13; s ^= s>>7; s ^= s<<17 ; 每步输出 s[31:24] ; 种子 0x9E3779B97F4A7C15, 先取后推进
判据:
  J1 每帧(UDP 载荷) 逐字节 == 流上某 1472 字节块
  J2 偏移为 1472 的整数倍
  J3 偏移随抓包顺序严格递增, 步长为 1472 的整数倍 (抓包丢帧 ⇒ 倍数 >1)
  J4 第 1 帧偏移 == 0 (重烧后发生器从 0 起; 这条把"抓包漏首帧"与"内容错"分开)
"""
import struct, sys, collections

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1
BOARD = '192.168.100.2'
CHUNK = 1 << 16


class Stream:
    def __init__(self):
        self.buf = bytearray()
        self.t = SEED

    def need(self, n):
        need = n - len(self.buf)
        while need > 0:
            m = min(CHUNK, need)
            t = self.t
            out = self.buf
            for _ in range(m):
                out.append((t >> 24) & 0xFF)   # ⚠️ **先取后推进** (rtl/app_udp_pattern.v:6-7 的明文约定)
                t ^= (t << 13) & M64
                t ^= t >> 7
                t ^= (t << 17) & M64
            self.t = t
            need -= m


def read_pcap(path):
    d = open(path, 'rb').read()
    mg = struct.unpack('<I', d[:4])[0]
    if mg == 0xA1B2C3D4:
        ns = False
    elif mg == 0xA1B23C4D:
        ns = True
    else:
        raise SystemExit('not LE pcap: %08x' % mg)
    p, out = 24, []
    while p + 16 <= len(d):
        ts, tus, cl, wl = struct.unpack('<IIII', d[p:p + 16])
        p += 16
        out.append((ts + tus / (1e9 if ns else 1e6), d[p:p + cl]))
        p += cl
    return out


def main():
    pkts = read_pcap(sys.argv[1])
    frames = []
    for ts, pkt in pkts:
        if len(pkt) < 42 or struct.unpack('!H', pkt[12:14])[0] != 0x0800:
            continue
        ihl = (pkt[14] & 0xF) * 4
        if '.'.join(str(b) for b in pkt[26:30]) != BOARD:
            continue
        u = 14 + ihl
        if struct.unpack('!H', pkt[u + 2:u + 4])[0] != 8081:
            continue
        ulen = struct.unpack('!H', pkt[u + 4:u + 6])[0]
        frames.append((ts, pkt[u + 8:u + ulen]))
    print('pcap=%s  总包=%d  其中 板子->本机:8081 = %d' % (sys.argv[1], len(pkts), len(frames)))
    if not frames:
        print('  ⛔ 没有板子的帧 ⇒ 无法判')
        return 1
    print('  载荷长度分布 = %s' % dict(collections.Counter(len(p) for _, p in frames)))
    st = Stream()
    cur = 0
    offs = []
    bad = 0
    WIN = 6000          # 最多向前找 6000 帧 (8.8 MB)
    for i, (ts, pay) in enumerate(frames):
        n = len(pay)
        found = None
        for k in range(WIN):
            cand = cur + k * 1472
            st.need(cand + n)
            if st.buf[cand:cand + n] == pay:
                found = cand
                break
        if found is None:
            bad += 1
            if bad <= 5:
                print('  [BAD] 第 %d 帧: 游标 %d 起 %d 帧内无匹配 (len=%d head=%s)'
                      % (i, cur, WIN, n, pay[:16].hex()))
            continue
        offs.append((i, found, n))
        cur = found + 1472
    print('  J1 逐字节 == 图案流 的帧 = %d ; 不匹配 = %d' % (len(offs), bad))
    if not offs:
        return 1
    j2 = all(o % 1472 == 0 for _, o, _ in offs)
    print('  J4 第 1 帧偏移 = %d %s' % (offs[0][1], '(==0 ✅)' if offs[0][1] == 0 else '(≠0 ⚠️ 首帧可能被抓包漏掉)'))
    print('  J2 全部偏移 ≡ 0 (mod 1472) = %s' % j2)
    steps = [offs[j + 1][1] - offs[j][1] for j in range(len(offs) - 1)]
    j3 = all(s > 0 for s in steps)
    print('  J3 偏移严格递增 = %s ; 步长/1472 分布(前 8) = %s'
          % (j3, dict(list(collections.Counter(s // 1472 for s in steps).items())[:8])))
    tot_frames = offs[-1][1] // 1472 + 1
    print('  覆盖流区间 = [%d, %d) ⇒ 逐字节验证 %d 帧 / 该区间共 %d 帧 = %.1f%%'
          % (offs[0][1], offs[-1][1] + offs[-1][2], len(offs), tot_frames, 100.0 * len(offs) / tot_frames))
    dt = frames[-1][0] - frames[0][0]
    print('  抓包时间戳: Δ=%.6f s ⇒ %d 帧期间 %.0f fps (下界, 丢帧会低估)' % (dt, len(frames), (len(frames) - 1) / dt if dt else 0))
    ok = j2 and j3 and bad == 0 and offs[0][1] == 0
    print('  ===> J1∧J2∧J3∧J4 = %s' % ('PASS' if ok else 'FAIL(见上)'))
    return 0


sys.exit(main())
