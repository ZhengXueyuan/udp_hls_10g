#!/usr/bin/env python
"""udp_rx xsim 刺激生成 + 周期精确参考模型。

帧列表: 配置 A (dst_ip=192.168.100.2, port 8080):
  16 个载荷长度帧 (0,1,2,5,6,7,8,9,13,14,15,16,17,42,100,1500) /
  端口错 / IP 错 / TCP / VLAN / ihl=6 / IP 校验和错 / udp_len 写小 1 / 坏 CRC /
  背靠背混合 6 帧; 配置 B (multi_en=1): 组播+匹配 / 组播+端口错 / 单播+匹配(应丢)。
FCS = zlib.crc32 小端 (铁律); IP 头校验和按反码和生成 (坏校验和帧显式翻转)。
模型 = mac_rx_64 + fifo_sync(8) + udp_rx 逐周期 co-sim, 与 RTL 非阻塞语义 1:1,
三模式: nostall / stall (3高1低) / hard (字节窗 [hw0,hw1) 硬停)。
"""
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PRE = bytes([0x55] * 7) + b'\xD5'
IFG = bytes([0x07] * 12)
SRC_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
DST_MAC = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
SRC_IP = 0x0A000001          # 10.0.0.1
DST_IP_A = 0xC0A86402        # 192.168.100.2
SPORT = 12345
DPORT = 8080
CFG_PORTS = (8080, 0, 0, 0)
CRC_RESIDUE = 0xDEBB20E3


def eth_fcs(p):
    return struct.pack('<I', zlib.crc32(p) & 0xFFFFFFFF)


def csum16(hw):
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def ip_hdr(src_ip, dst_ip, proto, ihl, total_len, bad_csum=False):
    h = bytearray(struct.pack('!BBHHHBBH', (0x40 | ihl) & 0xFF, 0,
                              total_len & 0xFFFF, 0x1234, 0, 64, proto, 0))
    h += struct.pack('!4s4s', struct.pack('!I', src_ip), struct.pack('!I', dst_ip))
    c = csum16(struct.unpack('!10H', bytes(h[:20])))
    h[10:12] = struct.pack('!H', c ^ (1 if bad_csum else 0))
    return bytes(h)


def payload(n):
    return bytes(((i * 7 + 3) & 0xFF) for i in range(n))


def mk_frame(src_ip, dst_ip, sport, dport, n, vlan=False, tcp=False, ihl=5,
             bad_ipcsum=False, udp_len=None, bad_fcs=False):
    eth = DST_MAC + SRC_MAC
    if vlan:
        eth += b'\x81\x00\x00\x64\x08\x00'
    else:
        eth += b'\x08\x00'
    pl = payload(n)
    if tcp:
        l = 20 + n
        ip = ip_hdr(src_ip, dst_ip, 6, 5, l, bad_ipcsum)
        iph = struct.pack('!HHLLBBHHH', sport, dport, 0, 0, 0x50, 0, 0, 0, 0)
        fb = eth + ip + iph + pl
    else:
        ul = (8 + n) if udp_len is None else udp_len
        ip = ip_hdr(src_ip, dst_ip, 17, ihl, 20 + (8 + n), bad_ipcsum)
        fb = eth + ip + struct.pack('!HHHH', sport, dport, ul, 0) + pl
    fcs = eth_fcs(fb)
    if bad_fcs:
        fcs = fcs[:-1] + bytes([fcs[-1] ^ 0x01])
    return fb, fcs


def build_frames():
    F = []
    for n in (0, 1, 2, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 42, 100, 1500):
        fb, fcs = mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, n)
        F.append(('len%d' % n, fb, fcs))
    F.append(('portmismatch', *mk_frame(SRC_IP, DST_IP_A, SPORT, 9999, 42)))
    F.append(('ipmismatch', *mk_frame(SRC_IP, 0xC0A86463, SPORT, DPORT, 42)))
    F.append(('tcp', *mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, 42, tcp=True)))
    F.append(('vlan', *mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, 42, vlan=True)))
    F.append(('ihl6', *mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, 42, ihl=6)))
    F.append(('badipcsum', *mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, 42, bad_ipcsum=True)))
    F.append(('udplensmall', *mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, 42, udp_len=49)))
    F.append(('badcrc', *mk_frame(SRC_IP, DST_IP_A, SPORT, DPORT, 42, bad_fcs=True)))
    for nm, dip, dport, n, tcp in (('b2b_match42', DST_IP_A, 8080, 42, False),
                                   ('b2b_port', DST_IP_A, 9999, 42, False),
                                   ('b2b_match17', DST_IP_A, 8080, 17, False),
                                   ('b2b_ip', 0xC0A86463, 8080, 100, False),
                                   ('b2b_match6', DST_IP_A, 8080, 6, False),
                                   ('b2b_tcp', DST_IP_A, 8080, 7, True)):
        if tcp:
            fb, fcs = mk_frame(SRC_IP, dip, SPORT, dport, n, tcp=True)
        else:
            fb, fcs = mk_frame(SRC_IP, dip, SPORT, dport, n)
        F.append((nm, fb, fcs))
    F.append(('mcast_match', *mk_frame(SRC_IP, 0xEF010203, SPORT, 8080, 42)))
    F.append(('mcast_port', *mk_frame(SRC_IP, 0xEF010203, SPORT, 9999, 42)))
    F.append(('mcast_unicast', *mk_frame(SRC_IP, DST_IP_A, SPORT, 8080, 42)))
    return F


def generate(simdir):
    frames = build_frames()
    segs = []        # (is_b, bytes, dv)
    cfg_switch_idx = None
    for idx, (nm, fb, fcs) in enumerate(frames):
        if nm.startswith('mcast'):
            if cfg_switch_idx is None:
                cfg_switch_idx = len(segs) - 2     # 前一个 IFG 尾部
        segs += [(0, b, 1) for b in (PRE + fb + fcs)]
        segs += [(0, b, 0) for b in IFG]
    nstim = len(segs)
    data = [s[1] for s in segs]
    dv = [s[2] for s in segs]
    er = [0] * nstim
    # 硬停窗口: 落在 1500 帧体中部
    acc = 0
    hw0 = None
    for nm, fb, fcs in frames:
        if nm == 'len1500':
            hw0 = acc + 8 + 60
        acc += 8 + len(fb) + 4 + 12
    hw1 = hw0 + 2000
    assert hw1 + 40 < nstim, (hw1, nstim)

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('stim_data.memh', data, '%02X')
    w('stim_dv.memh', dv, '%d')
    w('stim_er.memh', er, '%d')
    with open(os.path.join(simdir, 'cfg_switch.memh'), 'w') as fh:
        fh.write('%X\n%X\n%X\n' % (cfg_switch_idx, 0xEF010203, 1))
    with open(os.path.join(simdir, 'hardwin.memh'), 'w') as fh:
        fh.write('%X\n%X\n' % (hw0, hw1))
    return frames, hw0, hw1, cfg_switch_idx


# ---------------- 周期精确参考模型 ----------------

def pop8(k):
    return bin(k).count('1')


def ljust6(w48, p):
    if p <= 0:
        return 0
    return ((w48 >> (8 * (6 - p))) << (64 - 8 * p)) & 0xFFFFFFFFFFFFFFFF


def fold16(v):
    f1 = (v & 0xFFFF) + (v >> 16)
    return ((f1 & 0xFFFF) + (f1 >> 16)) & 0xFFFF


def ipc_sum9(w1_lo, w2r, w3):
    return (w1_lo + (w2r & 0xFFFF) + ((w2r >> 16) & 0xFFFF) +
            ((w2r >> 32) & 0xFFFF) + ((w2r >> 48) & 0xFFFF) +
            (w3 & 0xFFFF) + ((w3 >> 16) & 0xFFFF) +
            ((w3 >> 32) & 0xFFFF) + ((w3 >> 48) & 0xFFFF))


def ipc_ok(w1_lo, w2r, w3r, ipc_s9, w4):
    return fold16(ipc_s9 + ((w4 >> 48) & 0xFFFF)) == 0xFFFF


def model(simdir, mode):
    frames, hw0, hw1, cfg_switch_idx = generate(simdir)
    data = [int(x, 16) for x in open(os.path.join(simdir, 'stim_data.memh'))]
    dv = [int(x) for x in open(os.path.join(simdir, 'stim_dv.memh'))]
    nstim = len(data)
    kstat = 25 + nstim + 800

    # 每帧 crs (zlib 反码关系: raw 残留 == DEBB20E3 表示 FCS 好)
    crs_list = []
    for nm, fb, fcs in frames:
        crs_list.append(((zlib.crc32(fb + fcs) ^ 0xFFFFFFFF) & 0xFFFFFFFF) == CRC_RESIDUE)
    crs_list.append(False)

    # ---- mac_rx_64 状态 ----
    mst, pre_cnt, bcnt, fbytes = 'IDLE', 0, 0, 0
    dline, wreg, ferr, first_done, hwv, hwreg = [0] * 4, [0] * 8, False, False, False, None
    fidx = 0
    mstat = [0, 0, 0, 0]          # frames, crc_err, drop, bytes

    # ---- fifo_sync(8) ----
    wptr = rptr = 0
    mem = [None] * 8
    dout = None

    # ---- udp_rx 状态 ----
    st, wcnt, matched = 'HDR', 0, False
    w1_lo = w2r = w3r = ipc_s9 = 0
    mac_lo = mac_hi = src_ip_r = src_port_r = meta_len_r = 0
    hold = pcount = 0
    ev = ed = ek = el = eu = 0
    tail_stage = False
    td = tk = tu = 0
    stats = dict(pss=0, nonmatch=0, ipcsum=0, crc=0, bytes=0)

    lines = []
    pushes = []                   # (cycle, word) 队列 (模型简化: 直接当拍推入)

    def push_word(kb, last, sop, crs, err):
        n = len(kb)
        d = int.from_bytes(bytes(kb).ljust(8, b'\x00'), 'big')
        keep = (0xFF << (8 - n)) & 0xFF
        return (d, keep, sop, last, crs, err)

    def cfg_at(k):
        if k >= 26 + cfg_switch_idx:
            return (0xEF010203, 1, CFG_PORTS, 0)
        return (DST_IP_A, 0, CFG_PORTS, 0)

    def tready_at(k, sc_eff):
        if mode == 'stall':
            return 0 if (k - 26) % 4 == 0 else 1
        if mode == 'hard':
            i = k - 26
            return 0 if (hw0 <= i < hw1) else 1
        return 1

    def udp_cycle(w, m_tready, cfg):
        nonlocal st, wcnt, matched, w1_lo, w2r, w3r, ipc_s9
        nonlocal mac_lo, mac_hi, src_ip_r, src_port_r, meta_len_r
        nonlocal hold, pcount, ev, ed, ek, el, eu, tail_stage, td, tk, tu
        s_valid = w is not None
        if st == 'PAY':
            s_ready = m_tready or not ev
        elif st == 'TAIL':
            s_ready = False
        else:
            s_ready = True
        accept = s_valid and s_ready
        meta = (st == 'HDR') and accept and (wcnt == 5) and matched
        ev_n = ev and not m_tready
        st_n, wcnt_n, matched_n = st, wcnt, matched
        if accept:
            if st == 'HDR':
                if w[3] and wcnt != 5:                     # tlast: 头没走完帧就结束 (w5 短帧走特例)
                    st_n, wcnt_n, matched_n = 'HDR', 0, False
                    stats['nonmatch'] += 1
                else:
                    wc = 0 if w[2] else wcnt
                    if w[2]:
                        ev_n = False
                    if wc == 0:
                        if w[1] != 0xFF:
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            mac_lo = w[0] & 0xFFFF
                            wcnt_n = 1
                    elif wc == 1:
                        if (w[1] != 0xFF or ((w[0] >> 16) & 0xFFFF) != 0x0800 or
                                ((w[0] >> 8) & 0xFF) != 0x45):
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            mac_hi = (w[0] >> 32) & 0xFFFFFFFF
                            w1_lo = w[0] & 0xFFFF
                            wcnt_n = 2
                    elif wc == 2:
                        if w[1] != 0xFF or (w[0] & 0xFF) != 0x11:
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            w2r = w[0]
                            wcnt_n = 3
                    elif wc == 3:
                        if w[1] != 0xFF:
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            w3r = w[0]
                            src_ip_r = (w[0] >> 16) & 0xFFFFFFFF
                            ipc_s9 = ipc_sum9(w1_lo, w2r, w[0])
                            wcnt_n = 4
                    elif wc == 4:
                        if w[1] != 0xFF:
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        elif not ipc_ok(w1_lo, w2r, w3r, ipc_s9, w[0]):
                            st_n, matched_n = 'DROP', False
                            stats['ipcsum'] += 1
                        elif not (ip_match_cfg(w, w3r, cfg) and
                                  port_match_cfg(w, cfg) and
                                  (w[0] & 0xFFFF) >= 8):
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            matched_n = True
                            src_port_r = (w[0] >> 32) & 0xFFFF
                            meta_len_r = (w[0] & 0xFFFF) - 8
                            wcnt_n = 5
                    else:                                  # wc == 5
                        if (not matched or ((w[1] >> 6) & 0b11) != 0b11):
                            st_n, matched_n = 'DROP', False
                            stats['nonmatch'] += 1
                        elif w[3]:                         # 短载荷帧 (0..6 字节)
                            st_n, wcnt_n, matched_n = 'HDR', 0, False
                            if pop8(w[1]) - 2 != meta_len_r:
                                stats['nonmatch'] += 1
                            else:
                                if w[4]:
                                    stats['pss'] += 1
                                    stats['bytes'] += meta_len_r
                                else:
                                    stats['crc'] += 1
                                if w[1] != 0xC0:
                                    ev_n = True
                                    ed = ljust6(w[0] & 0xFFFFFFFFFFFF, pop8(w[1]) - 2)
                                    ek = (0xFF << (8 - (pop8(w[1]) - 2))) & 0xFF
                                    el = 1
                                    eu = (w[5] << 1) | w[4]
                        else:
                            st_n = 'PAY'
                            hold = w[0] & 0xFFFFFFFFFFFF
                            pcount = pop8(w[1]) - 2
                            wcnt_n = 6
            elif st == 'PAY':
                if w[2]:                                   # SOP: 上一帧被截断, 本字即新帧 w0
                    ev_n = False
                    if w[3]:
                        st_n, wcnt_n, matched_n = 'HDR', 0, False
                        stats['nonmatch'] += 1
                    elif w[1] != 0xFF:
                        st_n, matched_n = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        mac_lo = w[0] & 0xFFFF
                        st_n, wcnt_n, matched_n = 'HDR', 1, False
                elif w[3]:
                    if pop8(w[1]) == 0:
                        st_n, wcnt_n, matched_n = 'HDR', 0, False
                        stats['nonmatch'] += 1
                    elif pcount + pop8(w[1]) != meta_len_r:
                        st_n, wcnt_n, matched_n = 'HDR', 0, False
                        stats['nonmatch'] += 1
                    else:
                        st_n, wcnt_n, matched_n = 'HDR', 0, False
                        if w[4]:
                            stats['pss'] += 1
                            stats['bytes'] += meta_len_r
                        else:
                            stats['crc'] += 1
                        ev_n = True
                        ed = (hold << 16) | ((w[0] >> 48) & 0xFFFF)
                        eu = (w[5] << 1) | w[4]
                        if pop8(w[1]) <= 2:
                            ek = (0xFF << (8 - (6 + pop8(w[1])))) & 0xFF
                            el = 1
                        else:
                            ek = 0xFF
                            el = 0
                            st_n = 'TAIL'
                            tail_stage = False
                            td = ljust6(w[0] & 0xFFFFFFFFFFFF, pop8(w[1]) - 2)
                            tk = (0xFF << (8 - (pop8(w[1]) - 2))) & 0xFF
                            tu = eu
                else:
                    if w[1] != 0xFF:
                        st_n, matched_n = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        ev_n = True
                        ed = (hold << 16) | ((w[0] >> 48) & 0xFFFF)
                        ek = 0xFF
                        el = 0
                        hold = w[0] & 0xFFFFFFFFFFFF
                        pcount += 8
            else:                                          # DROP: 吞到帧尾
                if w[3]:
                    st_n, wcnt_n = 'HDR', 0
        if st == 'TAIL':                                   # RTL: S_TAIL 不依赖 accept
            if tail_stage:
                if m_tready:
                    st_n = 'HDR'
                    ev_n = False
            elif m_tready:
                ev_n = True
                ed, ek, el, eu = td, tk, 1, tu
                tail_stage = True
        st, wcnt, matched = st_n, wcnt_n, matched_n
        ev = ev_n
        return accept, meta

    def ip_match_cfg(w, w3r, cfg):
        dip, multi, ports, anyp = cfg
        if multi:
            return ((w3r >> 12) & 0xF) == 0xE
        return ((w3r & 0xFFFF) << 16 | ((w[0] >> 48) & 0xFFFF)) == dip

    def port_match_cfg(w, cfg):
        dip, multi, ports, anyp = cfg
        if anyp:
            return True
        dp = (w[0] >> 16) & 0xFFFF
        return dp in ports

    for k in range(0, kstat + 1):
        # ---- 采样 (posedge, pre-update) ----
        full = ((wptr & 7) == (rptr & 7)) and (wptr >> 3) != (rptr >> 3)
        empty = wptr == rptr
        s_valid = not empty
        m_tready = tready_at(k, 0)
        if ev and m_tready:
            lines.append('%016X %02X %d %d %d' % (ed, ek, el, eu & 1, (eu >> 1) & 1))
        if st == 'HDR' and s_valid and (wcnt == 5) and matched:
            sready = 1
            # meta 组合: accept 取决于 s_ready (HDR 时恒 1)
            lines.append('META %012X %08X %04X %04X' %
                         ((mac_lo << 32) | mac_hi, src_ip_r, src_port_r, meta_len_r))
        w = dout if s_valid else None
        cfg = cfg_at(k)
        accept, meta = udp_cycle(w, m_tready, cfg)
        # ---- fifo 更新 (rd = accept, wr = mac push) ----
        rd_ok = accept and s_valid
        rptr_n = rptr + (1 if rd_ok else 0)
        wr = False
        din = None
        # ---- mac_rx_64 每周期 ----
        j = k - 26
        if 0 <= j < nstim:
            by, dvv = data[j], dv[j]
        else:
            by, dvv = 0, 0
        if mst == 'IDLE':
            if dvv and by == 0x55:
                mst, pre_cnt = 'PRE', 1
        elif mst == 'PRE':
            if not dvv:
                mst = 'IDLE'
            elif by == 0x55:
                pre_cnt = min(pre_cnt + 1, 63)
            elif by == 0xD5 and pre_cnt >= 6:
                mst, bcnt, fbytes = 'DATA', 0, 0
                dline, wreg = [0] * 4, [0] * 8
                ferr, first_done, hwv, hwreg = False, False, False, None
                fidx += 1
            else:
                mst = 'IDLE'
        elif mst == 'DATA':
            if not dvv:
                if hwv and not full:
                    n = 8
                    d = int.from_bytes(bytes(hwreg).ljust(8, b'\x00'), 'big')
                    din = (d, 0xFF, not first_done, bcnt == 0,
                           crs_list[fidx - 1] if bcnt == 0 else False, ferr)
                    wr = not full
                    first_done = True
                    if bcnt == 0:
                        mst = 'IDLE'
                        mstat[0] += 1
                        mstat[3] += fbytes
                        if not crs_list[fidx - 1]:
                            mstat[1] += 1
                    else:
                        mst = 'FLUSH'
                elif hwv and full:
                    mst, hwv = 'DROP', False
                    mstat[2] += 1
                elif bcnt == 0:
                    mst = 'IDLE'
                    mstat[2] += 1
                else:
                    n = bcnt
                    d = int.from_bytes(bytes(wreg[:bcnt]).ljust(8, b'\x00'), 'big')
                    keep = (0xFF << (8 - n)) & 0xFF
                    din = (d, keep, True, True, crs_list[fidx - 1], ferr)
                    wr = not full
                    mst = 'IDLE'
                    mstat[0] += 1
                    mstat[3] += fbytes
                    if not crs_list[fidx - 1]:
                        mstat[1] += 1
            else:
                if fbytes >= 4:                      # 旧 fbytes: 本拍消费 4 拍前的字节
                    b = dline[0]
                    if bcnt == 7:
                        if hwv and full:
                            mst, hwv = 'DROP', False
                            mstat[2] += 1
                        else:
                            if hwv:
                                d = int.from_bytes(bytes(hwreg).ljust(8, b'\x00'), 'big')
                                din = (d, 0xFF, not first_done, False, False, ferr)
                                wr = True
                                first_done = True
                            hwreg = wreg[:7] + [b]
                            hwv = True
                            wreg, bcnt = [0] * 8, 0
                    else:
                        wreg[bcnt] = b
                        bcnt += 1
                fbytes += 1
                dline = dline[1:] + [by]
        elif mst == 'FLUSH':
            if full:
                mst = 'IDLE'
                mstat[2] += 1
            else:
                n = bcnt
                d = int.from_bytes(bytes(wreg[:bcnt]).ljust(8, b'\x00'), 'big')
                keep = (0xFF << (8 - n)) & 0xFF
                din = (d, keep, not first_done, True, crs_list[fidx - 1], ferr)
                wr = True
                mst = 'IDLE'
                mstat[0] += 1
                mstat[3] += fbytes
                if not crs_list[fidx - 1]:
                    mstat[1] += 1
        elif mst == 'DROP':
            if not dvv:
                mst = 'IDLE'
        # ---- fifo_sync 更新 ----
        bypass = wr and not full and ((rptr_n & 7) == (wptr & 7))
        if wr and not full:
            mem[wptr & 7] = din
            wptr += 1
        if rd_ok:
            rptr += 1
        dout = din if bypass else (mem[rptr_n & 7] if not empty else None)
        if k == kstat:
            break
    if not empty or st != 'HDR':
        print('WARN: drain incomplete at kstat (empty=%s st=%s)' % (empty, st))
    return lines, stats, mstat


def check(simdir, mode):
    exp_lines, exp_stats, exp_mstat = model(simdir, mode)
    fn = 'resp_udp_rx.memh' if mode == 'nostall' else 'resp_udp_rx_%s.memh' % mode
    with open(os.path.join(simdir, fn)) as fh:
        resp = [l.strip() for l in fh if l.strip()]
    ok = True
    nl = len(resp) - 2
    for i in range(max(len(exp_lines), nl)):
        e = exp_lines[i] if i < len(exp_lines) else None
        r = resp[i] if i < nl else None
        if (e or '').lower() != (r or '').lower():
            print('%s LINE %d: exp %r resp %r' % (mode, i, e, r))
            ok = False
            break
    sresp = resp[-2].split()[1:] if len(resp) >= 2 else []
    mresp = resp[-1].split()[1:] if len(resp) >= 2 else []
    if sresp != [str(exp_stats[k]) for k in ('pss', 'nonmatch', 'ipcsum', 'crc', 'bytes')]:
        print('%s STATS: exp %s resp %s' % (mode, exp_stats, sresp))
        ok = False
    if mresp != [str(x) for x in exp_mstat]:
        print('%s STATM: exp %s resp %s' % (mode, exp_mstat, mresp))
        ok = False
    print('%s: %d lines, stats %s, mac %s %s' %
          (mode, len(exp_lines), exp_stats, exp_mstat, 'OK' if ok else 'MISMATCH'))
    return ok


if __name__ == '__main__':
    import sys
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'rxsim')
    frames, hw0, hw1, csi = generate(simdir)
    print('%d frames, cfg_switch=%d hardwin=[%d,%d)' % (len(frames), csi, hw0, hw1))
    for mode in ('nostall', 'stall', 'hard'):
        lines, stats, mstat = model(simdir, mode)
        print('%s: %d lines, stats %s, mac %s' % (mode, len(lines), stats, mstat))
