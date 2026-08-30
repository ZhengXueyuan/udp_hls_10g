#!/usr/bin/env python
"""P4a 全链 (mac_rx_64->rx_classify->{fast TCP 链, slow HLS 链}->tx_arb->mac_tx_64)
刺激 + 语义校验。慢路径带**真 HLS udp_echo** (158 个综合 verilog 进 xsim)。

拓扑: classify 按 ethertype/proto 分流; ARP/ICMP/UDP -> slow_rx_adp -> HLS
-> slow_tx_adp; TCP -> P3 链 (tcp_synp 握手 conn0; conn1 TB 预配)。
TX 汇合 tx_arb (fast 优先) — 快慢两流在 GMII 捕获里自由交错。

校验全语义级 (HLS 应答拍级不可预期; classify 周期精确由单元 TB 覆盖):
- 慢流顺序 = RX 顺序 (HLS 串行处理): arp_reply / icmp_reply / udp_echo / arp_reply
  逐帧谓词 (关键字段 + IP/ICMP 校验和 + 载荷逐字节 + FCS)
- 快流 = tb_tcp_echo 的逐字节匹配 (kind/cid/seq/ack/plen + expected_frame_bytes,
  ip id = 快流内序号 — 慢帧不过 tcp_tx_frame 不占 id)
- 事件计数 (FEND/SYNP/ACK) + STATS7/TX/ECO/CAMF/TCBF 精确 + 慢路径统计
帧间距: 慢帧后 20000B (HLS 应答余量), TCP 段 1500B (tx 排空)。
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_tcp_chain as C

# P4 统一 MAC = C0 (HLS 编译期值); fast path cfg_src_mac 同步 C0。
C.DUT_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
DUT_MAC = C.DUT_MAC
DUT_IP = C.DUT_IP
PC_MAC = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])   # = CONN[0].dmac
PC_IP = 0xC0A86401                                    # 192.168.100.1
payload = C.payload
csum16 = C.csum16
PRE = C.PRE

# P4b: 握手归慢路径 HLS — conn0 的 TCP 帧源必须 = ARP 学到的 PC 身份
# (192.168.100.1), 否则 HLS ARP 查不到 → SYN+ACK 走广播。CONN[0] 原为
# 10.0.0.1 (chain 时代), 在此覆盖为 PC_IP。
C.CONN[0]['sip'] = PC_IP
HLS_ISS = 0x12345678          # HLS layer_tcp 的我方 ISS (cid=0)
HS_ACKVAL = HLS_ISS + 1       # 握手 ACK 应确认的值 = SYN+ACK 发出后的 snd_nxt

GAP_SLOW = 20000       # 慢帧后的 HLS 应答余量
GAP_TCP = 1500         # TCP 段间 (tx 排空)


def ip_hdr_p(src_ip, dst_ip, proto, total_len):
    h = bytearray(struct.pack('!BBHHHBBH', 0x45, 0, total_len & 0xFFFF,
                              0x4321, 0, 64, proto, 0))
    h += struct.pack('!4s4s', struct.pack('!I', src_ip), struct.pack('!I', dst_ip))
    h[10:12] = struct.pack('!H', csum16(struct.unpack('!10H', bytes(h[:20]))))
    return bytes(h)


def finish(fb):
    if len(fb) < 60:
        fb += b'\x00' * (60 - len(fb))
    return fb, struct.pack('<I', zlib.crc32(fb) & 0xFFFFFFFF)


def mk_arp_req():
    body = struct.pack('!HHBBH', 1, 0x0800, 6, 4, 1)
    body += PC_MAC + struct.pack('!I', PC_IP)
    body += b'\x00' * 6 + struct.pack('!I', DUT_IP)
    return finish(b'\xFF' * 6 + PC_MAC + b'\x08\x06' + body)


def mk_icmp_req(ident=0x1234, seq=1, n=32):
    pl = payload(n)
    ic = struct.pack('!BBHHH', 8, 0, 0, ident, seq) + pl
    pad = b'\x00' if len(ic) % 2 else b''
    cs = csum16(struct.unpack('!%dH' % (len(ic + pad) // 2), ic + pad))
    ic = ic[:2] + struct.pack('!H', cs) + ic[4:]
    fb = DUT_MAC + PC_MAC + b'\x08\x00' + ip_hdr_p(PC_IP, DUT_IP, 1, 20 + len(ic)) + ic
    fb, fcs = finish(fb)
    return fb, fcs, pl


def mk_udp(sport=0x9C42, dport=0x1F90, n=24):
    pl = payload(n)
    uh = struct.pack('!HHHH', sport, dport, 8 + n, 0)
    fb = DUT_MAC + PC_MAC + b'\x08\x00' + ip_hdr_p(PC_IP, DUT_IP, 17, 20 + 8 + n) + uh + pl
    fb, fcs = finish(fb)
    return fb, fcs, pl


def build_rx_frames(burst=0):
    F = []

    def add(name, fb, fcs, gap):
        F.append(dict(name=name, fb=fb, fcs=fcs, gap=gap))

    fb, fcs = mk_arp_req()
    add('arp1', fb, fcs, GAP_SLOW)
    fb, fcs, _pl = mk_icmp_req()
    add('icmp1', fb, fcs, GAP_SLOW)
    fb, fcs, _pl = mk_udp()
    add('udp1', fb, fcs, GAP_SLOW)
    fb, fcs = C.mk_tcp_frame(0, 999, 0, 0x02, 0, 0x2000, True)
    add('syn', fb, fcs, 300)
    # P4b: hs_ack 前留 GAP_SLOW (gap 是帧前间距! 改 syn 的 gap 只会推迟 syn
    # 自己) — 真实 TCP 里 PC 要等收到 SYN+ACK 才发数据; HLS 处理 SYN + cfg
    # 落地 ~4k 拍 (wire 时间), 300B 的旧间距会让 hs_ack/data 在 fast 路径
    # CAM/TCB 配好前到达被丢 (SYN 重传才能救)。
    fb, fcs = C.mk_tcp_frame(0, 1000, HS_ACKVAL, 0x10, 0, 0x4000, True)
    add('hs_ack', fb, fcs, GAP_SLOW)
    fb, fcs = C.mk_tcp_frame(0, 1000, HS_ACKVAL, 0x18, 7, 0x4000, True)
    add('data7a', fb, fcs, GAP_TCP)
    fb, fcs = C.mk_tcp_frame(0, 1007, HS_ACKVAL, 0x18, 9, 0x4000, True)
    add('data7b', fb, fcs, GAP_TCP)
    # P4b-5 排障: burst 模式 — 连续大段 (1460B, 线速帧距 12B), 复现板级
    # 吞吐测试的 echo 停滞。seq 从 1016 起每段 +1460。
    seq = 1016
    for b in range(burst):
        fb, fcs = C.mk_tcp_frame(0, seq, HS_ACKVAL, 0x18, 1460, 0x4000, True)
        add('burst%d' % b, fb, fcs, 12)
        seq += 1460
    fb, fcs = mk_arp_req()
    add('arp2', fb, fcs, GAP_SLOW)
    fb, fcs = C.mk_tcp_frame(1, 77, 900, 0x18, 20, 0x1A00, True)
    add('c1data', fb, fcs, GAP_TCP)
    off = 0
    for f in F:
        off += f['gap']
        f['first'] = off + 8
        f['B'] = len(f['fb'])
        off += 8 + f['B'] + 4 + 12
    return F


def gen_memh(simdir, frames):
    os.makedirs(simdir, exist_ok=True)
    nstim = max(f['first'] + f['B'] + 4 + 12 for f in frames)
    data = [0] * nstim
    dv = [0] * nstim
    for f in frames:
        stream = PRE + f['fb'] + f['fcs']
        base = f['first'] - 8
        for j, b in enumerate(stream):
            data[base + j] = b
            dv[base + j] = 1

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('stim_data.memh', data, '%02X')
    w('stim_dv.memh', dv, '%d')
    w('stim_er.memh', [0] * nstim, '%d')
    with open(os.path.join(simdir, 'cfg_tcb.memh'), 'w') as fh:
        for fld in C.FIELDS:
            fh.write('%X\n' % C.TCB1_INIT[fld])


# ================= 校验 =================

def parse_gmii(fn):
    byte_lines = []
    ev = dict(fend=[], ack=[], synp=[], stats7=None, stx=None, seco=None,
              camf=None, tcbf=None, srx=None, stx2=None)
    with open(fn) as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            if p[0] == 'FEND':
                ev['fend'].append((int(p[1]), int(p[2])))
            elif p[0] == 'ACK':
                ev['ack'].append((int(p[1]), int(p[2]), int(p[3], 16)))
            elif p[0] == 'SYNP':
                ev['synp'].append(tuple(int(x, 16) for x in p[1:7]))
            elif p[0] == 'STATS7':
                ev['stats7'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'STATS_TX':
                ev['stx'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'STATS_ECO':
                ev['seco'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'CAMF':
                ev['camf'] = tuple(int(x, 16) for x in p[1:])
            elif p[0] == 'TCBF':
                ev['tcbf'] = tuple(int(x, 16) for x in p[1:])
            elif p[0] == 'SLOWRX':
                ev['srx'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'SLOWTX':
                ev['stx2'] = tuple(int(x) for x in p[1:])
            else:
                byte_lines.append((int(p[0], 16), int(p[1])))
    frames = []
    cur = []
    active = False
    for b, en in byte_lines:
        if en:
            cur.append(b) if active else None
            if not active:
                cur = [b]
                active = True
        else:
            if active:
                frames.append(bytes(cur))
                active = False
    return frames, ev


def ip_ok(body):
    """IP 头校验和有效 + 返回 proto。"""
    if len(body) < 34 or body[14] >> 4 != 4:
        return 0
    hw = struct.unpack('!10H', body[14:34])
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        return -1
    return body[23]


def check_arp_reply(body, errs, tag):
    if len(body) < 42:
        errs.append('%s: arp reply too short' % tag)
        return
    if body[12:14] != b'\x08\x06':
        errs.append('%s: not arp' % tag)
        return
    op, = struct.unpack('!H', body[20:22])
    sha = body[22:28]
    spa, = struct.unpack('!I', body[28:32])
    tha = body[32:38]
    tpa, = struct.unpack('!I', body[38:42])
    if body[:6] != PC_MAC or body[6:12] != DUT_MAC:
        errs.append('%s: eth addr dst=%s src=%s' % (tag, body[:6].hex(), body[6:12].hex()))
    if op != 2 or sha != DUT_MAC or spa != DUT_IP or tha != PC_MAC or tpa != PC_IP:
        errs.append('%s: arp fields op=%d sha=%s spa=%08x tha=%s tpa=%08x'
                    % (tag, op, sha.hex(), spa, tha.hex(), tpa))


def check_icmp_reply(body, errs, tag, n=32):
    proto = ip_ok(body)
    if proto != 1:
        errs.append('%s: icmp ip proto/csum %s' % (tag, proto))
        return
    ihl = (body[14] & 0xF) * 4
    ic = body[14 + ihl:]
    if ic[0] != 0:
        errs.append('%s: icmp type %d != 0' % (tag, ic[0]))
    if struct.unpack('!HH', ic[4:8]) != (0x1234, 1):
        errs.append('%s: icmp id/seq %s' % (tag, ic[4:8].hex()))
    pad = b'\x00' if (len(ic) - 8) % 2 else b''
    # ICMP csum 覆盖 type..payload 末 (无 pad; HLS 按 ip total_len 界)
    total = struct.unpack('!H', body[16:18])[0]
    icl = body[14 + ihl:14 + total]
    pad = b'\x00' if len(icl) % 2 else b''
    s = sum(struct.unpack('!%dH' % (len(icl + pad) // 2), icl + pad))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('%s: icmp csum bad' % tag)
    if icl[8:8 + n] != payload(n):
        errs.append('%s: icmp payload mismatch' % tag)


def check_udp_echo(body, errs, tag, n=24):
    proto = ip_ok(body)
    if proto != 17:
        errs.append('%s: udp ip proto/csum %s' % (tag, proto))
        return
    ihl = (body[14] & 0xF) * 4
    uh = body[14 + ihl:]
    sport, dport, ulen = struct.unpack('!HHH', uh[:6])
    if (sport, dport) != (0x1F90, 0x9C42):
        errs.append('%s: udp ports %04x/%04x' % (tag, sport, dport))
    if uh[8:8 + n] != payload(n):
        errs.append('%s: udp payload mismatch' % tag)


def check_synack(body, errs, tag):
    """HLS SYN+ACK 语义: proto/flags/seq=HLS_ISS/ack=对端 ISS+1/doff=7 带 MSS=1460。"""
    proto = ip_ok(body)
    if proto != 6:
        errs.append('%s: synack ip proto/csum %s' % (tag, proto))
        return
    if body[:6] != PC_MAC or body[6:12] != DUT_MAC:
        errs.append('%s: synack eth addr' % tag)
    sport, dport = struct.unpack('!HH', body[34:38])
    if (sport, dport) != (0x1F90, 0x3039):
        errs.append('%s: synack ports %04x/%04x' % (tag, sport, dport))
    seq, = struct.unpack('!I', body[38:42])
    ack, = struct.unpack('!I', body[42:46])
    if seq != HLS_ISS:
        errs.append('%s: synack seq %08x != HLS_ISS %08x' % (tag, seq, HLS_ISS))
    if ack != 1000:
        errs.append('%s: synack ack %d != 1000' % (tag, ack))
    if body[46] >> 4 != 7:
        errs.append('%s: synack doff %d != 7 (无选项!)' % (tag, body[46] >> 4))
    if body[47] != 0x12:
        errs.append('%s: synack flags %02x != 0x12' % (tag, body[47]))
    # MSS 选项 (doff=7: 选项 8B 在 byte 54..61 = body[54:62]... body 含以太头:
    # TCP 选项在 body[34+20:34+28] = body[54:62]): MSS kind=2 len=4 val=1460
    if len(body) >= 62 and body[54:56] == b'\x02\x04':
        mss, = struct.unpack('!H', body[56:58])
        if mss != 1460:
            errs.append('%s: synack MSS %d != 1460' % (tag, mss))
    # TCP 校验和 fold
    ihl = (body[14] & 0xF) * 4
    total = struct.unpack('!H', body[16:18])[0]
    tcb = body[14 + ihl:14 + total]
    sip = struct.unpack('!I', body[26:30])[0]
    dip = struct.unpack('!I', body[30:34])[0]
    ph = struct.pack('!4s4sBBH', body[26:30], body[30:34], 0, 6, len(tcb))
    buf = ph + tcb
    if len(buf) % 2:
        buf += b'\x00'
    s = sum(struct.unpack('!%dH' % (len(buf) // 2), buf))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('%s: synack tcp csum bad (sip=%08x dip=%08x)' % (tag, sip, dip))


def tcp_fields(body):
    sport, = struct.unpack('!H', body[34:36])
    flags = body[47]
    kind = 'data' if flags == 0x18 else ('synack' if flags == 0x12 else 'ack')
    cid = 0 if sport == 0x1F90 else 1
    seq, = struct.unpack('!I', body[38:42])
    ack, = struct.unpack('!I', body[42:46])
    plen = struct.unpack('!H', body[16:18])[0] - 40
    return kind, cid, seq, ack, plen


def check(simdir):
    frames = build_rx_frames()
    got, ev = parse_gmii(os.path.join(simdir, 'resp_p4_chain.memh'))
    errs = []

    # ---- 期望快流 (TCP): 每数据段 echo (P4b: SYN+ACK 由 HLS 慢路径发,
    # 不在快流; suppress_data_ack=1 无纯 ACK) ----
    exp_fast = []
    rcv = {0: 1000, 1: 77}
    snd = {0: HS_ACKVAL, 1: 900}         # HLS 握手后 snd_nxt = ISS+1
    for i, f in enumerate(frames):
        if f['name'].startswith('data') or f['name'] == 'c1data':
            cid = 0 if f['name'].startswith('data') else 1
            plen = 7 if f['name'] == 'data7a' else (9 if f['name'] == 'data7b' else 20)
            na = rcv[cid] + plen
            exp_fast.append(dict(kind='data', cid=cid, seq=snd[cid], ack=na,
                                 plen=plen, rx_i=i))
            rcv[cid] = na
            snd[cid] += plen
    # ---- 期望慢流 (HLS, 顺序 = RX 顺序): P4b SYN 进慢路径 -> SYN+ACK ----
    exp_slow = ['arp', 'icmp', 'udp', 'synack', 'arp']

    # ---- 帧分类 ----
    slow_got = []
    fast_got = []
    for fb in got:
        body = fb[8:-4]
        if len(body) < 14:
            errs.append('runt frame len=%d' % len(body))
            continue
        if body[6:12] != DUT_MAC:
            errs.append('frame src mac %s != DUT C0' % body[6:12].hex())
        et = struct.unpack('!H', body[12:14])[0]
        if et == 0x0806:
            slow_got.append(('arp', fb))
        elif et == 0x0800:
            proto = body[23]
            if proto == 6:
                # P4b: flags=0x12 (SYN+ACK) 来自慢路径 HLS; 数据 0x18 = fast echo
                flags = body[47]
                if flags == 0x12:
                    slow_got.append(('synack', fb))
                else:
                    fast_got.append(fb)
            elif proto == 1:
                slow_got.append(('icmp', fb))
            elif proto == 17:
                slow_got.append(('udp', fb))
            else:
                errs.append('unknown ip proto %d' % proto)
        else:
            errs.append('unknown ethertype %04x' % et)
        # FCS 全帧校验
        if struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF) != fb[-4:]:
            errs.append('frame fcs bad')

    # ---- 慢流匹配 (严格顺序) ----
    if [k for k, _ in slow_got] != exp_slow:
        errs.append('slow stream %s != %s' % ([k for k, _ in slow_got], exp_slow))
    for i, (k, fb) in enumerate(slow_got):
        body = fb[8:-4]
        if k == 'arp':
            check_arp_reply(body, errs, 'slow%d' % i)
        elif k == 'icmp':
            check_icmp_reply(body, errs, 'slow%d' % i)
        elif k == 'udp':
            check_udp_echo(body, errs, 'slow%d' % i)
        elif k == 'synack':
            check_synack(body, errs, 'slow%d' % i)

    # ---- 快流匹配 (逐字节, ip id = 快流序号) ----
    if len(fast_got) != len(exp_fast):
        errs.append('fast count %d != %d' % (len(fast_got), len(exp_fast)))
    else:
        used = [False] * len(exp_fast)
        last_ack_i = -1
        last_echo_i = -1
        used_by = []
        for i, fb in enumerate(fast_got):
            kind, cid, seq, ack, plen = tcp_fields(fb[8:-4])
            cand = [j for j, e in enumerate(exp_fast) if not used[j] and
                    e['kind'] == kind and e['cid'] == cid and e['plen'] == plen and
                    e['ack'] == ack and e['seq'] == seq and
                    (kind == 'data' and e['rx_i'] > last_echo_i or
                     kind == 'ack' and e['rx_i'] >= last_ack_i or
                     kind == 'synack')]
            if not cand:
                errs.append('fast %d no match: %s c%d seq=%d ack=%d plen=%d'
                            % (i, kind, cid, seq, ack, plen))
                used_by.append(None)
                continue
            j = cand[0]
            used[j] = True
            used_by.append(j)
            e = exp_fast[j]
            if kind == 'ack':
                last_ack_i = e['rx_i']
            if kind == 'data':
                last_echo_i = e['rx_i']
                aj = next((k for k in range(j + 1) if exp_fast[k]['kind'] == 'ack'
                           and exp_fast[k]['rx_i'] == e['rx_i']), None)
                if aj is not None and not used[aj]:
                    errs.append('fast %d: echo before its ACK' % i)
        for i, (j, fb) in enumerate(zip(used_by, fast_got)):
            if j is None:
                continue
            e2 = dict(exp_fast[j], idx=i)
            eb = C.expected_frame_bytes(e2)
            body = fb[8:-4]
            if len(body) < len(eb) or body[:len(eb)] != eb:
                errs.append('fast %d (%s c%d) bytes mismatch' %
                            (i, exp_fast[j]['kind'], exp_fast[j]['cid']))

    # ---- 事件 / 统计 / 终态 ----
    if len(ev['fend']) != 4:
        errs.append('FEND count %d != 4' % len(ev['fend']))
    if len(ev['ack']) != 0:          # P4b: suppress + 无 synp -> 无 fast ACK 事件
        errs.append('ACK events %d != 0' % len(ev['ack']))
    if ev['synp']:                   # P4b: SYN 进慢路径, tcp_rx 不再见 SYN
        errs.append('SYNP should be empty, got %s' % (ev['synp'],))
    exp_bytes = 7 + 9 + 20     # stat_bytes 计载荷字节 (plen_l = ip_len-40)
    # nonmatch=0: SYN 已不进 fast 路径; ack=0: suppress 模式且无 dup/ooo
    if ev['stats7'] != (4, 0, 0, 0, 0, 0, exp_bytes):
        errs.append('STATS7 got %s exp (4,0,0,0,0,0,%d)' % (ev['stats7'], exp_bytes))
    if ev['stx'] != (3, 36, 0, 0):   # fast TX 只剩 3 个 echo (SYN+ACK 走 HLS)
        errs.append('STATS_TX got %s' % (ev['stx'],))
    if ev['seco'] != (3, 0):
        errs.append('STATS_ECO got %s' % (ev['seco'],))
    # CAMF: conn0 由 HLS cfg 记录写入 (peer=PC 192.168.100.1@PC_MAC, dport=8080)
    if ev['camf'] != (PC_IP, DUT_IP, C.CONN[0]['sport'],
                      C.CONN[0]['dport'], int.from_bytes(PC_MAC, 'big')):
        errs.append('CAMF got %s' % (ev['camf'],))
    # TCBF: conn0 = HLS 握手配置 + 数据推进; ISS 链 = 0x12345678
    texp = (1016, 0x12345679 + 16, HS_ACKVAL, 0x3000, 0x4000, 1,
            97, 920, 900, 0x1800, 0x1A00, 1)
    if ev['tcbf'] != texp:
        errs.append('TCBF exp %s got %s' % (texp, ev['tcbf']))
    if ev['srx'] != (5, 0):
        errs.append('SLOWRX got %s exp (5,0)' % (ev['srx'],))
    if ev['stx2'] != (5, 0):
        errs.append('SLOWTX got %s exp (5,0)' % (ev['stx2'],))

    print('frames RX=%d TX=%d (fast=%d slow=%d)'
          % (len(frames), len(got), len(fast_got), len(slow_got)))
    if errs:
        for e in errs[:12]:
            print('MISMATCH:', e)
        print('P4 CHAIN FAIL (%d errs)' % len(errs))
        return False
    print('P4 CHAIN OK')
    return True


def check_burst(simdir, nburst):
    """P4b-5 排障: burst 模式轻量诊断 — 数 echo 帧 + 末态统计 (不做全语义)。"""
    got, ev = parse_gmii(os.path.join(simdir, 'resp_p4_chain.memh'))
    data_echoes = 0
    for fb in got:
        body = fb[8:-4]
        if len(body) >= 48 and body[12:14] == b'\x08\x00' and body[23] == 6:
            flags = body[47]
            if flags == 0x18:
                data_echoes += 1
    print('burst sent=%d  data echoes=%d  (含 2 个预置 + 1 个 conn1)'
          % (nburst, data_echoes))
    print('STATS7  %s' % (ev['stats7'],))
    print('STATS_TX %s' % (ev['stx'],))
    print('STATS_ECO %s' % (ev['seco'],))
    print('TCBF %s' % (ev['tcbf'],))
    return True


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p4sim')
    nburst = 0
    mode = 'gen'
    if len(sys.argv) > 2:
        if sys.argv[2] == 'check':
            mode = 'check'
        elif sys.argv[2] == 'burst':
            nburst = int(sys.argv[3]) if len(sys.argv) > 3 else 100
            mode = 'gen'
        elif sys.argv[2] == 'burstcheck':
            nburst = int(sys.argv[3]) if len(sys.argv) > 3 else 100
            mode = 'burstcheck'
    frames = build_rx_frames(burst=nburst)
    print('%d RX frames' % len(frames))
    if mode == 'check':
        sys.exit(0 if check(simdir) else 1)
    if mode == 'burstcheck':
        sys.exit(0 if check_burst(simdir, nburst) else 1)
    gen_memh(simdir, frames)
    print('memh written')
