#!/usr/bin/env python
"""tcp_rx xsim 刺激生成 + 周期精确参考模型。

帧列表 (conn0: sport=0x3039 dport=0x1F90; conn1: sport=0xD431 dport=0x1F91):
  纯 ACK (裸/带填充) / 短载荷 1..3 / 8..10 (尾字边界) / 42/100/1500 /
  重复段 / 乱序段 (窗口内) / 窗口外 / SYN / FIN / RST / 带选项 (doff=6) /
  CAM 未命中 / conn1 / IP 校验和错 / 坏 CRC / 背靠背 4 帧 / conn1 重复 / 无效 ACK 号。
FCS = zlib.crc32 小端 (铁律); TCP 校验和按伪头+段反码和正确生成 (RTL 不校验)。
TCB 初值: e0 (rcv_nxt=1000 snd_nxt=6000 snd_una=5000 wnd=0x2000/0x2000 st=1),
          e1 (全 0, wnd=0x2000/0x2000 st=1); 见 cfg_tcb.memh (TB 与模型同源)。
模型 = mac_rx_64 + tcp_rx + tcb 逐周期 co-sim, 与 RTL 非阻塞语义 1:1;
TB 配置阶段 40 拍: 字节 j 在周期 j+67 进入 mac; CAM 条目 0/1/2 于周期 29/30/31 起
可见; TCB 条目 e 字段 f 于周期 33+6e+f 起可见。
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
DST_IP = 0xC0A86402          # 192.168.100.2
SPORT0 = 0x3039              # conn0
DPORT0 = 0x1F90
SPORT1 = 0xD431              # conn1
DPORT1 = 0x1F91
CRC_RESIDUE = 0xDEBB20E3

# TCB 初值 (cfg_tcb.memh 同源)
TCB0 = dict(rcv_nxt=1000, snd_nxt=6000, snd_una=5000,
            rcv_wnd=0x2000, snd_wnd=0x2000, state=1)
TCB1 = dict(rcv_nxt=0, snd_nxt=0, snd_una=0,
            rcv_wnd=0x2000, snd_wnd=0x2000, state=1)

# CAM 配置 (与 TB 配置阶段一致): 条目 0/1/2
CAM_CFG = [
    (0x0A000001, 0xC0A86402, 0x3039, 0x1F90),
    (0x0A000001, 0xC0A86402, 0xD431, 0x1F91),
    (0x0A00000F, 0xC0A86402, 0x5000, 0x1F92),
]


def eth_fcs(p):
    return struct.pack('<I', zlib.crc32(p) & 0xFFFFFFFF)


def csum16(hw):
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def ip_hdr(src_ip, dst_ip, proto, total_len, bad_csum=False, frag=0):
    h = bytearray(struct.pack('!BBHHHBBH', 0x45, 0,
                              total_len & 0xFFFF, 0x1234, frag & 0xFFFF, 64, proto, 0))
    h += struct.pack('!4s4s', struct.pack('!I', src_ip), struct.pack('!I', dst_ip))
    c = csum16(struct.unpack('!10H', bytes(h[:20])))
    h[10:12] = struct.pack('!H', c ^ (1 if bad_csum else 0))
    return bytes(h)


def payload(n):
    return bytes(((i * 7 + 3) & 0xFF) for i in range(n))


def mk_tcp_frame(sport, dport, seq, ack, flags, n, wnd=0x4000, doff=5,
                 bad_ipcsum=False, bad_fcs=False, pad=False, frag=0):
    eth = DST_MAC + SRC_MAC + b'\x08\x00'
    tcp = struct.pack('!HHLLBBHHH', sport, dport, seq & 0xFFFFFFFF,
                      ack & 0xFFFFFFFF, (doff << 4) & 0xF0, flags,
                      wnd & 0xFFFF, 0, 0)
    if doff > 5:
        tcp += b'\x01\x02\x03\x04' * (doff - 5)
    seg = tcp + payload(n)
    # TCP 校验和 (伪头 + 段)
    ph = struct.pack('!4s4sBBH', struct.pack('!I', SRC_IP), struct.pack('!I', DST_IP),
                     0, 6, len(seg))
    buf = ph + seg
    if len(buf) % 2:
        buf += b'\x00'
    cs = csum16(struct.unpack('!%dH' % (len(buf) // 2), buf))
    seg = seg[:16] + struct.pack('!H', cs) + seg[18:]
    ip = ip_hdr(SRC_IP, DST_IP, 6, 20 + len(seg), bad_ipcsum, frag)
    fb = eth + ip + seg
    if pad and len(fb) < 60:
        fb += b'\x00' * (60 - len(fb))
    fcs = eth_fcs(fb)
    if bad_fcs:
        fcs = fcs[:-1] + bytes([fcs[-1] ^ 0x01])
    return fb, fcs


def build_frames():
    """帧列表: 期望行为由模型独立重算, 此表仅生成字节流 (seq 由跟踪器链式推进)。"""
    F = []
    seq0 = TCB0['rcv_nxt']
    seq1 = TCB1['rcv_nxt']

    def track(kind, e, plen, seq_override):
        nonlocal seq0, seq1
        if e == 0:
            seq = seq0 if seq_override is None else seq_override
            if kind == 'data':
                seq0 += plen
        else:
            seq = seq1 if seq_override is None else seq_override
            if kind == 'data':
                seq1 += plen
        return seq

    def add(name, e, kind, plen=0, **kw):
        seq = track(kind, e, plen, kw.pop('seq', None))
        sport = SPORT0 if e == 0 else SPORT1
        dport = DPORT0 if e == 0 else DPORT1
        flags = kw.pop('flags', 0x10)
        fb, fcs = mk_tcp_frame(sport, dport, seq, kw.pop('ack', 5000),
                               flags, plen, **kw)
        F.append((name, fb, fcs))

    add('ack_pure', 0, 'ack', ack=5100, wnd=0x4000)
    add('ack_pure_pad', 0, 'ack', ack=5200, wnd=0x3000, pad=True)
    add('data1', 0, 'data', 1, ack=5300, wnd=0x2500)
    add('data2_pad', 0, 'data', 2, ack=5400, pad=True)
    add('data3', 0, 'data', 3)
    add('data8', 0, 'data', 8)
    add('data9', 0, 'data', 9)
    add('data10', 0, 'data', 10)
    add('data42', 0, 'data', 42)
    add('data100', 0, 'data', 100)
    add('data1500', 0, 'data', 1500)
    add('dup', 0, 'drop_ack', 20, seq=seq0 - 500, ack=5500)
    add('ooo', 0, 'drop_ack', 30, seq=seq0 + 1000)
    add('outwin', 0, 'drop_silent', 30, seq=seq0 + 0x3000)
    add('syn', 0, 'drop_silent', 0, flags=0x02)
    add('fin', 0, 'drop_silent', 0, flags=0x11)
    add('rst', 0, 'drop_silent', 0, flags=0x14)
    add('doff6', 0, 'drop_silent', 20, doff=6)
    add('frag', 0, 'drop_silent', 20, frag=0x2000)   # MF=1 分片段: 丢给 P4
    # cammiss: 源端口未配置 (手工构造, seq 不推进)
    fb, fcs = mk_tcp_frame(0x3038, DPORT0, seq0, 5000, 0x10, 20)
    F.append(('cammiss', fb, fcs))
    add('conn1', 1, 'data', 20, ack=2000, wnd=0x1234)
    add('badipcsum', 0, 'drop_silent', 20, bad_ipcsum=True)
    add('badcrc', 0, 'data_badcrc', 20, bad_fcs=True)
    add('b2b1', 0, 'data', 42, ack=5600)
    add('b2b_ack_pad', 0, 'ack', ack=5700, pad=True)
    add('b2b2', 0, 'data', 6)
    add('b2b_dup', 0, 'drop_ack', 10, seq=seq0 - 10)
    add('conn1_dup', 1, 'drop_ack', 10, seq=seq1 - 10)
    add('ack_badwin', 0, 'ack', ack=9000, wnd=0x1100)
    return F


def generate(simdir):
    frames = build_frames()
    segs = []
    for nm, fb, fcs in frames:
        segs += [(0, b, 1) for b in (PRE + fb + fcs)]
        segs += [(0, b, 0) for b in IFG]
    nstim = len(segs)
    data = [s[1] for s in segs]
    dv = [s[2] for s in segs]
    er = [0] * nstim
    # 硬停窗口: 落在 data1500 帧体中部
    acc = 0
    hw0 = None
    for nm, fb, fcs in frames:
        if nm == 'data1500':
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
    with open(os.path.join(simdir, 'cfg_tcb.memh'), 'w') as fh:
        for e in range(16):
            t = TCB0 if e == 0 else (TCB1 if e == 1 else dict(
                rcv_nxt=0, snd_nxt=0, snd_una=0, rcv_wnd=0, snd_wnd=0, state=0))
            for fld in ('rcv_nxt', 'snd_nxt', 'snd_una', 'rcv_wnd', 'snd_wnd', 'state'):
                fh.write('%X\n' % t[fld])
    with open(os.path.join(simdir, 'hardwin.memh'), 'w') as fh:
        fh.write('%X\n%X\n' % (hw0, hw1))
    return frames, hw0, hw1


# ---------------- 周期精确参考模型 ----------------

def pop8(k):
    return bin(k).count('1')


def ljust2(w16, p):
    if p == 1:
        return (w16 & 0xFF00) << 48
    return (w16 & 0xFFFF) << 48


def fold16(v):
    f1 = (v & 0xFFFF) + (v >> 16)
    return ((f1 & 0xFFFF) + (f1 >> 16)) & 0xFFFF


def ipc_sum9(w1_lo, w2r, w3):
    return (w1_lo + (w2r & 0xFFFF) + ((w2r >> 16) & 0xFFFF) +
            ((w2r >> 32) & 0xFFFF) + ((w2r >> 48) & 0xFFFF) +
            (w3 & 0xFFFF) + ((w3 >> 16) & 0xFFFF) +
            ((w3 >> 32) & 0xFFFF) + ((w3 >> 48) & 0xFFFF))


def ipc_ok(w1_lo, w2r, ipc_s9, w4):
    return fold16(ipc_s9 + ((w4 >> 48) & 0xFFFF)) == 0xFFFF


FIELDS = ('rcv_nxt', 'snd_nxt', 'snd_una', 'rcv_wnd', 'snd_wnd', 'state')


def model(simdir, mode):
    frames, hw0, hw1 = generate(simdir)
    data = [int(x, 16) for x in open(os.path.join(simdir, 'stim_data.memh'))]
    dv = [int(x) for x in open(os.path.join(simdir, 'stim_dv.memh'))]
    nstim = len(data)
    kstat = nstim + 900

    crs_list = []
    for nm, fb, fcs in frames:
        crs_list.append(((zlib.crc32(fb + fcs) ^ 0xFFFFFFFF) & 0xFFFFFFFF) == CRC_RESIDUE)
    crs_list.append(False)

    # ---- mac_rx_64 状态 ----
    mst, pre_cnt, bcnt, fbytes = 'IDLE', 0, 0, 0
    dline, wreg, ferr, first_done, hwv, hwreg = [0] * 4, [0] * 8, False, False, False, None
    fidx = 0
    mstat = [0, 0, 0, 0]
    # fifo_sync(8)
    wptr = rptr = 0
    mem = [None] * 8
    dout = None

    # ---- cam / tcb ----
    cam = [None] * 16
    tcb = [dict(rcv_nxt=0, snd_nxt=0, snd_una=0, rcv_wnd=0, snd_wnd=0, state=0)
           for _ in range(16)]

    # ---- tcp_rx 状态 ----
    st, wcnt = 'HDR', 0
    w1_lo = w2r = w3r = ipc_s9 = 0
    src_ip_r = src_port_r = seq_hi_r = 0
    cam_hit_l = False
    conn_id_l = 0
    acc_l = ackresp_l = ack_adv_l = False
    ack32_l = seq32_l = rcv_nxt_l = 0
    plen_l = wnd_l = 0
    drop_ack = False
    hold16 = pcount = 0
    ev = el = False
    ed = ek = eu = 0
    tail_stage = False
    td = tk = tu = 0
    pend_rcv = pend_una = pend_wnd = False
    pend_id = pend_rcv_val = pend_una_val = pend_wnd_val = 0
    drn = 0
    stats = dict(pss=0, nonmatch=0, ipcsum=0, crc=0, seq=0, ack=0, bytes=0)

    lines = []

    def tready_at(k):
        if mode == 'stall':
            return 0 if (k - 26) % 4 == 0 else 1
        if mode == 'hard':
            i = k - 26
            return 0 if (hw0 <= i < hw1) else 1
        return 1

    def cam_lookup(sip, dip, sport, dport):
        for i in range(16):
            if cam[i] is not None and cam[i] == (sip, dip, sport, dport):
                return True, i
        return False, 0

    def tcp_cycle(w, m_tready):
        nonlocal st, wcnt, w1_lo, w2r, w3r, ipc_s9
        nonlocal src_ip_r, src_port_r, seq_hi_r, cam_hit_l, conn_id_l
        nonlocal acc_l, ackresp_l, ack_adv_l, ack32_l, seq32_l, rcv_nxt_l, plen_l, wnd_l
        nonlocal drop_ack, hold16, pcount, ev, ed, ek, el, eu, tail_stage, td, tk, tu
        nonlocal pend_rcv, pend_una, pend_wnd, pend_id
        nonlocal pend_rcv_val, pend_una_val, pend_wnd_val, drn
        s_valid = w is not None
        if st == 'PAY':
            s_ready = m_tready or not ev
        elif st == 'TAIL':
            s_ready = False
        else:
            s_ready = True
        accept = s_valid and s_ready
        ev_n = ev and not m_tready
        st_n, wcnt_n = st, wcnt
        drop_ack_n = drop_ack
        hold16_n = hold16
        pcount_n = pcount
        wnd_l_n = wnd_l
        ed_n, ek_n, el_n, eu_n = ed, ek, el, eu
        tail_stage_n = tail_stage
        td_n, tk_n, tu_n = td, tk, tu
        cam_hit_l_n, conn_id_l_n = cam_hit_l, conn_id_l
        acc_l_n, ackresp_l_n, ack_adv_l_n = acc_l, ackresp_l, ack_adv_l
        ack32_l_n, seq32_l_n, rcv_nxt_l_n, plen_l_n = ack32_l, seq32_l, rcv_nxt_l, plen_l
        w1_lo_n, w2r_n, w3r_n, ipc_s9_n = w1_lo, w2r, w3r, ipc_s9
        src_ip_r_n, src_port_r_n, seq_hi_r_n = src_ip_r, src_port_r, seq_hi_r

        if accept:
            if st == 'HDR':
                if w[2]:
                    ev_n = False
                if w[3] and wcnt != 6:
                    st_n, wcnt_n = 'HDR', 0
                    stats['nonmatch'] += 1
                else:
                    wc = 0 if w[2] else wcnt
                    if wc == 0:
                        if w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            wcnt_n = 1
                    elif wc == 1:
                        if (w[1] != 0xFF or ((w[0] >> 16) & 0xFFFF) != 0x0800 or
                                ((w[0] >> 8) & 0xFF) != 0x45):
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            w1_lo_n = w[0] & 0xFFFF
                            wcnt_n = 2
                    elif wc == 2:
                        if w[1] != 0xFF or (w[0] & 0xFF) != 0x06:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            w2r_n = w[0]
                            wcnt_n = 3
                    elif wc == 3:
                        if w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            w3r_n = w[0] & 0xFFFF
                            src_ip_r_n = (w[0] >> 16) & 0xFFFFFFFF
                            ipc_s9_n = ipc_sum9(w1_lo, w2r, w[0])
                            wcnt_n = 4
                    elif wc == 4:
                        if w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        elif not ipc_ok(w1_lo, w2r, ipc_s9, w[0]):
                            st_n, drop_ack_n = 'DROP', False
                            stats['ipcsum'] += 1
                        else:
                            dip = (w3r << 16) | ((w[0] >> 48) & 0xFFFF)
                            hit, cid = cam_lookup(src_ip_r, dip,
                                                  (w[0] >> 32) & 0xFFFF,
                                                  (w[0] >> 16) & 0xFFFF)
                            cam_hit_l_n, conn_id_l_n = hit, cid
                            src_port_r_n = (w[0] >> 32) & 0xFFFF
                            seq_hi_r_n = w[0] & 0xFFFF
                            wcnt_n = 5
                    elif wc == 5:
                        if w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            seq32 = (seq_hi_r << 16) | ((w[0] >> 48) & 0xFFFF)
                            ack32 = (w[0] >> 16) & 0xFFFFFFFF
                            flags = w[0] & 0xFF
                            flags_ok = ((flags >> 4) & 1) and not (flags & 0x07)
                            doff_ok = ((w[0] >> 12) & 0xF) == 5
                            t = tcb[conn_id_l]
                            state_ok = t['state'] == 1
                            len_ok = ((w2r >> 48) & 0xFFFF) >= 40
                            seq_diff = (seq32 - t['rcv_nxt']) & 0xFFFFFFFF
                            win_ok = seq_diff < t['rcv_wnd']
                            seq_eq = seq32 == t['rcv_nxt']
                            seq_lt = seq32 < t['rcv_nxt']
                            ack_ok = (((ack32 - t['snd_una']) & 0xFFFFFFFF) <=
                                      ((t['snd_nxt'] - t['snd_una']) & 0xFFFFFFFF))
                            ack_adv = ack_ok and ack32 != t['snd_una']
                            plen_w = (((w2r >> 48) & 0xFFFF) - 40) & 0xFFFF
                            base_ok = (cam_hit_l and state_ok and flags_ok and
                                       doff_ok and len_ok and
                                       ((w2r >> 16) & 0x3FFF) == 0)
                            acc = base_ok and win_ok and seq_eq
                            ackresp = (base_ok and not seq_eq and
                                       (win_ok or seq_lt) and plen_w != 0)
                            acc_l_n, ackresp_l_n, ack_adv_l_n = acc, ackresp, ack_adv
                            ack32_l_n, seq32_l_n = ack32, seq32
                            plen_l_n = plen_w
                            rcv_nxt_l_n = t['rcv_nxt']
                            wcnt_n = 6
                    else:      # wc == 6
                        pop8w = pop8(w[1])
                        w6_ok = (acc_l and plen_l <= 2 and
                                 pop8w == 6 + (plen_l & 0xF))
                        if w[3]:
                            st_n, wcnt_n = 'HDR', 0
                            if w6_ok:
                                if w[4]:
                                    stats['pss'] += 1
                                else:
                                    stats['crc'] += 1
                                if plen_l != 0:
                                    stats['bytes'] += plen_l
                                    ev_n = True
                                    ed_n = ljust2(w[0] & 0xFFFF, plen_l)
                                    ek_n = (0xFF << (8 - plen_l)) & 0xFF
                                    el_n = 1
                                    eu_n = (w[5] << 1) | w[4]
                            elif ackresp_l:
                                stats['seq'] += 1
                            else:
                                stats['nonmatch'] += 1
                        elif acc_l:
                            if plen_l == 0:
                                st_n = 'PAD'
                            else:
                                st_n = 'PAY'
                                hold16_n = w[0] & 0xFFFF
                                pcount_n = 2 if plen_l >= 2 else 1
                            wnd_l_n = (w[0] >> 48) & 0xFFFF
                            wcnt_n = 7
                        elif ackresp_l:
                            st_n, drop_ack_n = 'DROP', True
                            stats['seq'] += 1
                        else:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
            elif st == 'PAY':
                if (not ev or m_tready) and accept:
                    if w[2]:
                        ev_n = False
                        if w[3]:
                            st_n, wcnt_n = 'HDR', 0
                            stats['nonmatch'] += 1
                        elif w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            st_n, wcnt_n = 'HDR', 1
                    elif w[3]:
                        pop8w = pop8(w[1])
                        pay_r = plen_l - pcount
                        st_n, wcnt_n = 'HDR', 0
                        if pop8w < pay_r:
                            stats['nonmatch'] += 1
                        else:
                            if w[4]:
                                stats['pss'] += 1
                                stats['bytes'] += plen_l
                            else:
                                stats['crc'] += 1
                            ev_n = True
                            eu_n = (w[5] << 1) | w[4]
                            if pay_r == 0:
                                ed_n = ljust2(hold16, plen_l)
                                ek_n = (0xFF << (8 - plen_l)) & 0xFF
                                el_n = 1
                            elif pay_r <= 6:
                                ed_n = (hold16 << 48) | ((w[0] >> 16) & 0xFFFFFFFFFFFF)
                                ek_n = (0xFF << (8 - (pay_r + 2))) & 0xFF
                                el_n = 1
                            else:
                                ed_n = (hold16 << 48) | ((w[0] >> 16) & 0xFFFFFFFFFFFF)
                                ek_n = 0xFF
                                el_n = 0
                                st_n = 'TAIL'
                                tail_stage_n = False
                                td_n = ljust2(w[0] & 0xFFFF, pay_r - 6)
                                tk_n = (0xFF << (8 - (pay_r - 6))) & 0xFF
                                tu_n = eu_n
                    else:
                        if w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            ev_n = True
                            ed_n = (hold16 << 48) | ((w[0] >> 16) & 0xFFFFFFFFFFFF)
                            ek_n = 0xFF
                            el_n = 0
                            hold16_n = w[0] & 0xFFFF
                            pcount_n = pcount + 8
            elif st == 'PAD':
                if accept:
                    if w[2]:
                        if w[3]:
                            st_n, wcnt_n = 'HDR', 0
                            stats['nonmatch'] += 1
                        elif w[1] != 0xFF:
                            st_n, drop_ack_n = 'DROP', False
                            stats['nonmatch'] += 1
                        else:
                            st_n, wcnt_n = 'HDR', 1
                    elif w[3]:
                        st_n, wcnt_n = 'HDR', 0
                        if w[4]:
                            stats['pss'] += 1
                        else:
                            stats['crc'] += 1
            else:      # DROP
                if w[3]:
                    st_n, wcnt_n = 'HDR', 0
                    drop_ack_n = False
        if st == 'TAIL':        # RTL: S_TAIL 不依赖 accept
            if tail_stage:
                if m_tready:
                    st_n = 'HDR'
                    ev_n = False
            elif m_tready:
                ev_n = True
                ed_n, ek_n, el_n, eu_n = td, tk, 1, tu
                tail_stage_n = True

        # ---- fend / ack 组合信号 (RTL 在 NBA 前采样) ----
        pop8w = pop8(w[1]) if w else 0
        pay_r = plen_l - pcount
        w6_ok = (acc_l and plen_l <= 2 and pop8w == 6 + (plen_l & 0xF))
        fend_w6 = (st == 'HDR' and accept and wcnt == 6 and w[3] and w6_ok)
        fend_pay = (st == 'PAY' and (not ev or m_tready) and accept and
                    w[3] and pop8w >= pay_r)
        fend_pad = (st == 'PAD' and accept and w[3])
        fend = fend_w6 or fend_pay or fend_pad
        ack_req = (((fend_w6 and plen_l != 0) or fend_pay) and w[4]) or \
            (st == 'HDR' and accept and wcnt == 6 and w[3] and ackresp_l and w[4]) or \
            (st == 'DROP' and accept and w[3] and drop_ack and w[4])

        # ---- fend pend / drain (RTL 改组合 upd + gnt: drn 拍当拍写 TCB;
        #      本 TB gnt = !cfg_upd_wr, 激励期间恒 1) ----
        drn_n = drn
        pend_rcv_n, pend_una_n, pend_wnd_n = pend_rcv, pend_una, pend_wnd
        pend_id_n = pend_id
        pend_rcv_val_n, pend_una_val_n, pend_wnd_val_n = \
            pend_rcv_val, pend_una_val, pend_wnd_val
        if fend:
            pend_rcv_n = acc_l and plen_l != 0 and w[4]
            pend_una_n = ack_adv_l and w[4]
            pend_wnd_n = w[4]
            pend_id_n = conn_id_l
            pend_rcv_val_n = rcv_nxt_l + plen_l
            pend_una_val_n = ack32_l
            pend_wnd_val_n = ((w[0] >> 48) & 0xFFFF) if fend_w6 else wnd_l
            drn_n = 1
        else:
            if drn == 1:
                if pend_rcv:
                    tcb[pend_id]['rcv_nxt'] = pend_rcv_val & 0xFFFFFFFF
                drn_n = 2
            elif drn == 2:
                if pend_una:
                    tcb[pend_id]['snd_una'] = pend_una_val & 0xFFFFFFFF
                drn_n = 3
            elif drn == 3:
                if pend_wnd:
                    tcb[pend_id]['snd_wnd'] = pend_wnd_val & 0xFFFF
                drn_n = 0
        if ack_req:
            stats['ack'] += 1

        # ---- 提交 (NBA) ----
        st, wcnt = st_n, wcnt_n
        w1_lo, w2r, w3r, ipc_s9 = w1_lo_n, w2r_n, w3r_n, ipc_s9_n
        src_ip_r, src_port_r, seq_hi_r = src_ip_r_n, src_port_r_n, seq_hi_r_n
        cam_hit_l, conn_id_l = cam_hit_l_n, conn_id_l_n
        acc_l, ackresp_l, ack_adv_l = acc_l_n, ackresp_l_n, ack_adv_l_n
        ack32_l, seq32_l, rcv_nxt_l, plen_l = ack32_l_n, seq32_l_n, rcv_nxt_l_n, plen_l_n
        wnd_l = wnd_l_n
        drop_ack = drop_ack_n
        hold16, pcount = hold16_n, pcount_n
        ev, ed, ek, el, eu = ev_n, ed_n, ek_n, el_n, eu_n
        tail_stage, td, tk, tu = tail_stage_n, td_n, tk_n, tu_n
        pend_rcv, pend_una, pend_wnd = pend_rcv_n, pend_una_n, pend_wnd_n
        pend_id = pend_id_n
        pend_rcv_val, pend_una_val, pend_wnd_val = pend_rcv_val_n, pend_una_val_n, pend_wnd_val_n
        drn = drn_n
        return accept

    for k in range(0, kstat + 1):
        # ---- 采样 (posedge, pre-update) ----
        full = ((wptr & 7) == (rptr & 7)) and (wptr >> 3) != (rptr >> 3)
        empty = wptr == rptr
        s_valid = not empty
        m_tready = tready_at(k)
        w = dout if s_valid else None
        if ev and m_tready:
            lines.append('%016X %02X %d %d %d' % (ed, ek, el, eu & 1, (eu >> 1) & 1))
        if st == 'HDR' and s_valid and wcnt == 6 and acc_l and plen_l != 0:
            pop8w = pop8(w[1])
            w6_ok = (acc_l and plen_l <= 2 and pop8w == 6 + (plen_l & 0xF))
            if not w[3] or w6_ok:
                lines.append('META %08X %04X %04X %d %08X' %
                             (src_ip_r, src_port_r, plen_l, conn_id_l, seq32_l))
        if st == 'HDR' and s_valid and wcnt == 6 and w is not None and w[3]:
            pop8w = pop8(w[1])
            w6_ok = (acc_l and plen_l <= 2 and pop8w == 6 + (plen_l & 0xF))
            if w6_ok:
                lines.append('FEND %d' % (1 if (not w[4]) or w[5] else 0))
        if st == 'PAY' and (not ev or m_tready) and s_valid and w is not None and w[3]:
            pop8w = pop8(w[1])
            if pop8w >= plen_l - pcount:
                lines.append('FEND %d' % (1 if (not w[4]) or w[5] else 0))
        if st == 'PAD' and s_valid and w is not None and w[3]:
            lines.append('FEND %d' % (1 if (not w[4]) or w[5] else 0))
        if s_valid and w is not None:
            pop8w = pop8(w[1])
            pay_r = plen_l - pcount
            w6_ok = (acc_l and plen_l <= 2 and pop8w == 6 + (plen_l & 0xF))
            fend_w6 = (st == 'HDR' and wcnt == 6 and w[3] and w6_ok)
            fend_pay = (st == 'PAY' and (not ev or m_tready) and w[3] and pop8w >= pay_r)
            ack_req = (((fend_w6 and plen_l != 0) or fend_pay) and w[4]) or \
                (st == 'HDR' and wcnt == 6 and w[3] and ackresp_l and w[4]) or \
                (st == 'DROP' and w[3] and drop_ack and w[4])
            if ack_req:
                av = (rcv_nxt_l + plen_l) if (fend_w6 or fend_pay) else rcv_nxt_l
                lines.append('ACK %d %08X' % (conn_id_l, av))
        # ---- tcp_rx 每周期 ----
        accept = tcp_cycle(w, m_tready)
        rd_ok = accept and s_valid
        rptr_n = rptr + (1 if rd_ok else 0)
        # ---- 配置注入 (TB 配置阶段) ----
        if 28 <= k <= 30:
            cam[k - 28] = CAM_CFG[k - 28]
        if 32 <= k <= 43:
            e, f = (k - 32) // 6, (k - 32) % 6
            t = TCB0 if e == 0 else (TCB1 if e == 1 else None)
            if t is not None:
                tcb[e][FIELDS[f]] = t[FIELDS[f]]
        # ---- mac_rx_64 每周期 (字节 j 于周期 j+67 进入) ----
        wr = False
        din = None
        j = k - 67
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
                if fbytes >= 4:
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
    return lines, stats, mstat, tcb


def check(simdir, mode):
    exp_lines, exp_stats, exp_mstat, exp_tcb = model(simdir, mode)
    fn = 'resp_tcp_rx.memh' if mode == 'nostall' else 'resp_tcp_rx_%s.memh' % mode
    with open(os.path.join(simdir, fn)) as fh:
        resp = [l.strip() for l in fh if l.strip()]
    ok = True
    nl = len(resp) - 3
    for i in range(max(len(exp_lines), nl)):
        e = exp_lines[i] if i < len(exp_lines) else None
        r = resp[i] if i < nl else None
        if (e or '').lower() != (r or '').lower():
            print('%s LINE %d: exp %r resp %r' % (mode, i, e, r))
            ok = False
            break
    tail = resp[-3:] if len(resp) >= 3 else []
    sresp = tail[0].split()[1:] if tail else []
    if sresp != [str(exp_stats[k]) for k in ('pss', 'nonmatch', 'ipcsum', 'crc', 'seq', 'ack', 'bytes')]:
        print('%s STATS: exp %s resp %s' % (mode, exp_stats, sresp))
        ok = False
    mresp = tail[1].split()[1:] if len(tail) > 1 else []
    if mresp != [str(x) for x in exp_mstat]:
        print('%s STATM: exp %s resp %s' % (mode, exp_mstat, mresp))
        ok = False
    tresp = tail[2].split()[1:] if len(tail) > 2 else []
    texp = []
    for e in (0, 1):
        for fld in FIELDS:
            fmt = '%08X' if fld in ('rcv_nxt', 'snd_nxt', 'snd_una') else \
                  ('%04X' if fld in ('rcv_wnd', 'snd_wnd') else '%X')
            texp.append(fmt % exp_tcb[e][fld])
    if [t.lower() for t in tresp] != [t.lower() for t in texp]:
        print('%s TCBF: exp %s resp %s' % (mode, texp, tresp))
        ok = False
    print('%s: %d lines, stats %s, mac %s %s' %
          (mode, len(exp_lines), exp_stats, exp_mstat, 'OK' if ok else 'MISMATCH'))
    return ok


if __name__ == '__main__':
    import sys
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p3sim')
    frames, hw0, hw1 = generate(simdir)
    print('%d frames, hardwin=[%d,%d)' % (len(frames), hw0, hw1))
    for mode in ('nostall', 'stall', 'hard'):
        lines, stats, mstat, tcb = model(simdir, mode)
        print('%s: %d lines, stats %s, mac %s' % (mode, len(lines), stats, mstat))
