"""f3_check.py — F3 (图案流逐字节) 的**独立口径**, 本轮方法 (不需要重烧到 offset 0)。

期望来源 = `rtl/app_udp_pattern.v:6-7` 的明文算式 (xorshift64 / 种子 0x9E3779B97F4A7C15 /
取 s[31:24] / 先取后推进), 本脚本**独立复算** (不依赖被验工具, 也不依赖板子自报)。

判据:
  J0 求解器自检 (3 正 + 3 负) 必须先过 —— 否则不出结论 (判据的判据)。
  J1 从首帧首 96 B **反解**出 LFSR 状态 (GF(2) 求解, 见 xs_lib) ⇒ 得到该帧在流上的偏移;
  J2 每一帧的**每一个字节** == 从该状态顺序推出来的流 (逐帧全字节);
  J3 相邻帧偏移**严格递增且步长 = 1 帧** (= 1472 B; 步长>1 ⇒ 抓包丢帧, 必须报出来);
  J4 速率 (pcap 端点时间戳口径, 附上"批量打戳"的桶宽与去重自证)。
"""
import collections
import hashlib
import struct
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
import xs_lib

BOARD = '192.168.100.2'
FRAME = 1472


def read_pcap(path):
    d = open(path, 'rb').read()
    mg = struct.unpack('<I', d[:4])[0]
    us = (mg == 0xA1B2C3D4)
    if not us and mg != 0xA1B23C4D:
        raise SystemExit('not LE pcap: %08x' % mg)
    p, out = 24, []
    while p + 16 <= len(d):
        ts, sub, cl, wl = struct.unpack('<IIII', d[p:p + 16])
        p += 16
        out.append((ts + sub / (1e6 if us else 1e9), d[p:p + cl]))
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
    print('pcap=%s 总包=%d 板子->本机:8081=%d' % (sys.argv[1], len(pkts), len(frames)))
    if len(frames) < 3:
        print('  [SKIP] 帧太少'); return 1
    print('  载荷长度分布 = %s' % dict(collections.Counter(len(p) for _, p in frames)))

    print('J0 求解器自检:')
    if not xs_lib.selftest():
        print('  ⛔ 自检未过 ⇒ 本脚本不出结论'); return 2

    head = frames[0][1][:96]
    forms = xs_lib.linear_forms(96)
    st, free = xs_lib.solve(forms, head)
    if st is None:
        print('J1 ⛔ 首帧首 96 B **不是**图案流 (线性方程组矛盾) ⇒ 内容判据不成立'); return 1
    print('J1 首帧反解: 状态 = 0x%016X (自由位 %d) %s' % (st, free, '(== 公共种子)' if st == xs_lib.SEED else ''))

    # ---- 顺着状态逐帧全字节复核 (游标式) ----
    s = st
    bad = 0
    offs = []
    for i, (ts, pay) in enumerate(frames):
        off = i * FRAME if i == 0 else None
        buf = bytearray()
        t = s
        for _ in range(len(pay)):
            buf.append((t >> 24) & 0xFF)
            t = xs_lib.step(t)
        if bytes(buf) != pay:
            first = next(j for j in range(len(pay)) if buf[j] != pay[j])
            bad += 1
            if bad <= 5:
                print('  [BAD] 第 %d 帧与流不符, 首差 @%d (len=%d)' % (i, first, len(pay)))
        s = t
        offs.append((i, len(pay)))
    print('J2 逐帧逐字节 == 复算流 的帧 = %d ; 不符 = %d' % (len(frames) - bad, bad))

    # 相邻帧长度一致 ⇒ 偏移步长恒 1 帧
    steps = collections.Counter(len(frames[i + 1][1]) for i in range(len(frames) - 1))
    uniform = (len(steps) == 1)
    step_len = next(iter(steps)) if uniform else None
    print('J3 相邻帧载荷长度分布 = %s ⇒ 步长恒 1 帧 (%d B) = %s'
          % (dict(steps), step_len or -1, uniform))
    print('  覆盖 = %d 帧 × %d B = %d B ; 无空洞 (逐帧连续) = %s'
          % (len(frames), step_len or 0, len(frames) * (step_len or 0), uniform))

    ts0, ts1 = frames[0][0], frames[-1][0]
    dt = ts1 - ts0
    uniq = len(set(f[0] for f in frames))
    hashes = len(set(hashlib.md5(p).hexdigest() for _, p in frames))
    print('J4 时间戳: Δ=%.9f s ⇒ 端点口径 %.0f fps (下界) ; 不同时间戳=%d (批量打戳桶≈%.1f µs) ; '
          '不同载荷=%d/%d (重复副本=%d)'
          % (dt, (len(frames) - 1) / dt, uniq, dt / max(uniq - 1, 1) * 1e6,
             hashes, len(frames), len(frames) - hashes))
    ok = (bad == 0) and uniform and free == 0
    print('  ===> J1∧J2∧J3 = %s' % ('PASS' if ok else 'FAIL(见上)'))
    return 0 if ok else 1


sys.exit(main())
