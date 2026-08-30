#!/usr/bin/env python
"""TCP echo 全链 (mac->tcp_rx->tcp_echo->tcp_tx_frame->mac + tcp_synp 握手) 刺激 + 校验。

复用 gen_stim_tcp_chain 的 rx_model (mac_rx_64+fifo8+tcp_rx 时序壳, 周期精确) 生成
FEND/ACK/SYNP 期望事件; TX 侧不建周期模型 (chain 已逐拍验证过 tx/仲裁/组帧),
改用语义校验: 解 GMII 帧 -> 与期望帧序列做容错匹配 (b2b 组的 ACK/echo 交错
取决于拍级时序, 只断言结构性顺序: 每数据帧 ACK 先于其 echo; ACK/echo 各自
子序列保持 RX 顺序) -> 逐字节比对内容 (头/双校验和/载荷/FCS/seq/ack 链)。
帧间大间距 (gap=1500B) 保证 tcp_rx 载荷口无背压 (rx_model tready=1 假设成立);
b2b 三连 gap=12 制造 fq 积压>1 路径。坏 CRC 帧测 frame_fifo 回卷。
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_tcp_chain as C

PRE = C.PRE
IFG = C.IFG
CONN = C.CONN
DUT_MAC = C.DUT_MAC
DUT_IP = C.DUT_IP
FIELDS = C.FIELDS
TCB1_INIT = C.TCB1_INIT
SYNP_ISS = C.SYNP_ISS
payload = C.payload
csum16 = C.csum16

GAP = 1500            # 默认帧间额外空闲字节 (TX 排空)
SYN_SEQ = 999


def build_rx_frames():
    F = []

    def add(name, cid, kind, plen, seq, ack, wnd, pad=True, flags=0x10, gap=GAP):
        F.append(dict(name=name, cid=cid, kind=kind, plen=plen, seq=seq,
                      ack=ack, wnd=wnd, pad=pad, flags=flags, gap=gap))

    add('syn', 0, 'syn', 0, SYN_SEQ, 0, 0x2000, flags=0x02)
    add('hs_ack', 0, 'ack', 0, 1000, 6000, 0x4000)
    add('data5', 0, 'data', 5, 1000, 6000, 0x4000)
    add('data42', 0, 'data', 42, 1005, 6000, 0x4000)
    add('data100', 0, 'data', 100, 1047, 6000, 0x4000)
    add('dup', 0, 'drop_ack', 20, 1147 - 300, 6000, 0x4000)
    add('ooo', 0, 'drop_ack', 30, 1147 + 100, 6000, 0x4000)
    add('c1data20', 1, 'data', 20, 77, 900, 0x2200)
    add('b2b8', 0, 'data', 8, 1147, 6000, 0x4000, gap=12)
    add('b2b9', 0, 'data', 9, 1155, 6000, 0x4000, gap=12)
    add('b2b10', 0, 'data', 10, 1164, 6000, 0x4000, gap=12)
    add('badcrc', 0, 'data', 30, 1174, 6000, 0x4000)
    off = 0
    for f in F:
        off += f['gap']
        fb, fcs = C.mk_tcp_frame(f['cid'], f['seq'], f['ack'], f['flags'],
                                 f['plen'], f['wnd'], f['pad'])
        if f['name'] == 'badcrc':
            fcs = fcs[:-1] + bytes([fcs[-1] ^ 0x01])
        f['fb'] = fb
        f['fcs'] = fcs
        f['first'] = off + 8
        f['B'] = len(fb)
        off += 8 + len(fb) + 4 + 12
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
        for fld in FIELDS:
            fh.write('%X\n' % TCB1_INIT[fld])


def expected_tx_frames(frames, good, suppress=False):
    """RX 帧序 -> 期望 TX 帧序 (语义级, 不含拍级交错)。
    suppress=True (板上 echo 配置): 接受的数据段不发纯 ACK (echo 帧自带 ack)。"""
    exp = []
    rcv = {0: 1000, 1: 77}
    snd = {0: 6000, 1: 900}
    exp.append(dict(kind='synack', cid=0, seq=SYNP_ISS, ack=1000, plen=0, rx_i=-1))
    for i, f in enumerate(frames):
        if f['kind'] == 'data' and good[i]:
            na = rcv[f['cid']] + f['plen']
            # ACK 段也携带 seq = snd_nxt (DUT 对全部段统一锁存 snd_nxt)
            if not suppress:
                exp.append(dict(kind='ack', cid=f['cid'], seq=snd[f['cid']],
                                ack=na, plen=0, rx_i=i))
            exp.append(dict(kind='data', cid=f['cid'], seq=snd[f['cid']],
                            ack=na, plen=f['plen'], rx_i=i))
            rcv[f['cid']] = na
            snd[f['cid']] += f['plen']
        elif f['kind'] == 'drop_ack':
            exp.append(dict(kind='ack', cid=f['cid'], seq=snd[f['cid']],
                            ack=rcv[f['cid']], plen=0, rx_i=i))
    return exp, rcv, snd


def parse_gmii(fn):
    """返回 (frames, events): frames = 每帧完整字节 (前导+内容+FCS);
    events = dict(fend/ack/synp 列表 + stats/camf/tcbf)。"""
    byte_lines = []
    ev = dict(fend=[], ack=[], synp=[], stats7=None, stx=None, seco=None,
              camf=None, tcbf=None)
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
            else:
                byte_lines.append((int(p[0], 16), int(p[1])))
    frames = []
    cur = []
    active = False
    for b, en in byte_lines:
        if en:
            if not active:
                cur = [b]
                active = True
            else:
                cur.append(b)
        else:
            if active:
                frames.append(bytes(cur))
                active = False
    return frames, ev


def frame_fields(fb):
    """解 TX 帧: (kind, cid, seq, ack, plen)。kind: synack/ack/data。"""
    body = fb[8:-4]
    sport = struct.unpack('!H', body[34:36])[0]
    flags = body[47]
    kind = 'data' if flags == 0x18 else ('synack' if flags == 0x12 else 'ack')
    cid = 0 if sport == 0x1F90 else 1
    seq = struct.unpack('!I', body[38:42])[0]
    ack = struct.unpack('!I', body[42:46])[0]
    plen = struct.unpack('!H', body[16:18])[0] - 40
    return kind, cid, seq, ack, plen


def check(simdir):
    frames = build_rx_frames()
    gen_memh(simdir, frames)
    good = [f['name'] != 'badcrc' for f in frames]
    # 板上 wrapper_p4: cfg_suppress_data_ack=1 — 模型同配置 (覆盖板级行为)
    rx = C.rx_model(frames, snd_nxt_init={0: 6000, 1: 900}, good=good,
                    suppress_data_ack=True)
    got, ev = parse_gmii(os.path.join(simdir, 'resp_tcp_echo.memh'))
    errs = []

    # ---- FEND/ACK/SYNP 事件 (周期精确, 来自 rx_model) ----
    if ev['fend'] != list(rx['fends']):
        errs.append('FEND seq\n  exp %s\n  got %s' % (rx['fends'], ev['fend']))
    all_acks = sorted(rx['acks'] + rx['sacks'], key=lambda a: a[0])
    exp_acks = [(k, i, v) for k, i, v, s in all_acks]
    if ev['ack'] != exp_acks:
        errs.append('ACK seq\n  exp %s\n  got %s' % (exp_acks, ev['ack']))
    if ev['synp']:
        f0 = frames[0]
        esyn = (int.from_bytes(CONN[0]['dmac'], 'big'), CONN[0]['sip'],
                CONN[0]['sport'], CONN[0]['dport'], SYN_SEQ, 0x2000)
        if ev['synp'] != [esyn]:
            errs.append('SYNP exp %s got %s' % (esyn, ev['synp']))

    # ---- TX 帧语义匹配 ----
    exp, rcv_final, snd_final = expected_tx_frames(frames, good, suppress=True)
    if len(got) != len(exp):
        errs.append('frame count %d != %d' % (len(got), len(exp)))
    else:
        used = [False] * len(exp)
        used_by = []
        last_ack_i = -1
        last_echo_i = -1
        for i, fb in enumerate(got):
            kind, cid, seq, ack, plen = frame_fields(fb)
            cand = [j for j, e in enumerate(exp) if not used[j] and
                    e['kind'] == kind and e['cid'] == cid and e['plen'] == plen and
                    e['ack'] == ack and e['seq'] == seq and
                    (kind == 'data' and e['rx_i'] > last_echo_i or
                     kind == 'ack' and e['rx_i'] >= last_ack_i or
                     kind == 'synack')]
            if not cand:
                errs.append('frame %d no match: %s c%d seq=%d ack=%d plen=%d'
                            % (i, kind, cid, seq, ack, plen))
                used_by.append(None)
                continue
            j = cand[0]
            used[j] = True
            used_by.append(j)
            e = exp[j]
            if kind == 'ack' and e['rx_i'] >= 0:
                last_ack_i = e['rx_i']
            if kind == 'data':
                last_echo_i = e['rx_i']
            # 每数据帧: ACK 先于其 echo (suppress 模式下无随行纯 ACK, 跳过)
            if kind == 'data':
                aj = next((k for k in range(j + 1) if exp[k]['kind'] == 'ack'
                           and exp[k]['rx_i'] == e['rx_i']), None)
                if aj is not None and not used[aj]:
                    errs.append('frame %d: echo of rx_i=%d before its ACK'
                                % (i, e['rx_i']))
        for i, (j, fb) in enumerate(zip(used_by, got)):
            if j is None:
                continue
            e = exp[j]
            e2 = dict(e, idx=i)
            eb = C.expected_frame_bytes(e2)
            body = fb[8:-4]
            if len(body) < len(eb) or body[:len(eb)] != eb:
                errs.append('frame %d (%s c%d plen=%s) bytes mismatch'
                            % (i, e['kind'], e['cid'], e['plen']))
            fcs = fb[-4:]
            if struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF) != fcs:
                errs.append('frame %d fcs' % i)
        if any(not u for u in used):
            errs.append('unmatched expected entries: %s' %
                        [i for i, u in enumerate(used) if not u])

    # ---- 统计/终态 ----
    if ev['stats7'] != tuple(rx['stats'][k] for k in
                             ('pss', 'nonmatch', 'ipcsum', 'crc', 'seq', 'ack', 'bytes')):
        errs.append('STATS7 exp %s got %s' % (rx['stats'], ev['stats7']))
    # stat_ack 计所有非数据帧 (含 SYN+ACK): suppress 后 = synack + dup/ooo = 3
    if ev['stx'] != (10, 194, 3, 0):
        errs.append('STATS_TX got %s' % (ev['stx'],))
    if ev['seco'] != (7, 1):
        errs.append('STATS_ECO got %s' % (ev['seco'],))
    if ev['camf'] != (CONN[0]['sip'], CONN[0]['dip'], CONN[0]['sport'],
                      CONN[0]['dport'], int.from_bytes(CONN[0]['dmac'], 'big')):
        errs.append('CAMF got %s' % (ev['camf'],))
    tcbf = rx['tcb']
    texp = [tcbf[0]['rcv_nxt'], snd_final[0], 6000, 0x3000, 0x4000, 1,
            tcbf[1]['rcv_nxt'], snd_final[1], 900, 0x1800, 0x2200, 1]
    if ev['tcbf'] != tuple(texp):
        errs.append('TCBF exp %s got %s' % (texp, ev['tcbf']))

    print('frames RX=%d TX=%d, rx stats %s, final rcv_nxt0=%d snd_nxt0=%d'
          % (len(frames), len(got), rx['stats'], rcv_final[0], snd_final[0]))
    if errs:
        for e in errs[:12]:
            print('MISMATCH:', e)
        print('ECHO FAIL (%d errs)' % len(errs))
        return False
    print('ECHO OK')
    return True


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p3sim')
    frames = build_rx_frames()
    print('%d RX frames' % len(frames))
    if len(sys.argv) > 2 and sys.argv[2] == 'check':
        sys.exit(0 if check(simdir) else 1)
    gen_memh(simdir, frames)
    print('memh written')
