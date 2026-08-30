#!/usr/bin/env python
"""#48 TCP fast path 全链 (mac_rx_64->tcp_rx->tcb->tcp_tx_frame->mac_tx_64) 刺激 + 校验。

拓扑: RX 字节流进 tcp_rx; ack_req 与 tcp_synp 的 sack_req 二选一进 tcp_tx_frame
(synp 优先, ack_syn=1); CAM 外置共享 (配置口: TB cphase 优先, 其次 synp); TCB 更新仲裁
(tx>rx>cfg级=TB配置|synp) 在 TB; app 数据由 TB 脚本 (presenting, 锚点绝对拍) 驱动。
周期约定 (模型拍 t = TB 日志 k): 复位后第 1 个 posedge 进入拍 0; RX 字节 j 于拍 41+j
上线 (cphase 40 拍配置后逐拍驱动); 事件于拍 t 组合有效, posedge 末写入, 拍 t+1 可见。

握手 (tcp_synp): 纯 SYN 帧尾 (S_DROP tlast 拍 t) -> syn_v 拍 t+1 (TB 日志 SYNP k=t+1);
synp 在 k+3..k+8 写 TCB0 六字段 (TUPD 日志), CAM0 写于 k+2 拍末 (k+3 可见),
sack_req 于 k+9 入 ACK 队 -> SYN+ACK (flags 0x12, seq=iss, ack=对端 iss+1,
发完 snd_nxt+1)。对端 ACK (ack=iss+1) 后 snd_una=iss+1, conn0 进入数据流。

场景: SYN -> [gap] 对端 ACK -> 原 conn0/conn1 流量 (snd_una 链从 6000 起) ->
末尾 SYN 重传 (幂等, conn0 状态重置: rcv_nxt=1000, snd_nxt=6000, snd_una=5999)。
注意: 移位后的 una 链 (6100/6150/6200/6300) 在前段超过 TX 实发进度 (snd_nxt 时值),
DUT 按 ack_ok 合法拒绝推进 (ACK 未发数据); 模型用 snd_nxt 事件表真值复现 —
una 实际只在 hs_ack->6000 / data64->6300 / pcack300->6410 三级推进。
锚点自解: d80/d300 的 S_DONE 对齐 data42/data1000 drain 第 1 拍 (rcv_nxt 写,
仲裁争用 — snd_una 写已不存在, 不可作锚) — COLL 行实证。
校验: parse_gmii 逐帧语义 (头/双 csum/载荷/FCS/flags/window/seq/ack/id) + 帧序 +
FEND/ACK/SYNP/TUPD/COLL 事件序列逐拍比对 + STATS7/STATS_TX/CAMF/TCBF。总结 'CHAIN OK'。
"""
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PRE = bytes([0x55] * 7) + b'\xD5'
IFG = bytes([0x07] * 12)
CONN = {
    0: dict(sip=0x0A000001, dip=0xC0A86402, sport=0x3039, dport=0x1F90,
            dmac=bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]),
            pcmac=bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0]), rcv_wnd=0x3000),
    1: dict(sip=0x0A000009, dip=0xC0A86409, sport=0xD431, dport=0x1F91,
            dmac=bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01]),
            pcmac=bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC9]), rcv_wnd=0x1800),
}
DUT_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC1])
DUT_IP = 0xC0A86402
# conn0 不预写 (握手建立); conn1 照旧预写
TCB_ZERO = dict(rcv_nxt=0, snd_nxt=0, snd_una=0, rcv_wnd=0, snd_wnd=0, state=0)
TCB1_INIT = dict(rcv_nxt=77, snd_nxt=900, snd_una=900,
                 rcv_wnd=0x1800, snd_wnd=0x2000, state=1)
SYNP_ISS = 5999          # synp cfg_iss
SYN_SEQ = 999            # 对端 iss
SYN_WND = 0x2000
HS_GAP = 300             # SYN 与对端 ACK 间额外空字节 (等 SYN+ACK 发完)
RESYN_GAP = 200          # 末尾 SYN 重传前额外空字节 (流量沉淀)
FIELDS = ('rcv_nxt', 'snd_nxt', 'snd_una', 'rcv_wnd', 'snd_wnd', 'state')
SEL2FIELD = {0: 'rcv_nxt', 1: 'snd_nxt', 2: 'snd_una',
             3: 'rcv_wnd', 4: 'snd_wnd', 5: 'state'}


def fresh_tcb():
    return [dict(TCB_ZERO), dict(TCB1_INIT)] + [dict(TCB_ZERO) for _ in range(14)]


def payload(n):
    return bytes(((i * 7 + 3) & 0xFF) for i in range(n))


def csum16(hw):
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def ip_hdr(src_ip, dst_ip, total_len):
    h = bytearray(struct.pack('!BBHHHBBH', 0x45, 0, total_len & 0xFFFF,
                              0x1234, 0, 64, 6, 0))
    h += struct.pack('!4s4s', struct.pack('!I', src_ip), struct.pack('!I', dst_ip))
    h[10:12] = struct.pack('!H', csum16(struct.unpack('!10H', bytes(h[:20]))))
    return bytes(h)


def mk_tcp_frame(cid, seq, ack, flags, n, wnd, pad):
    c = CONN[cid]
    if flags & 0x02:
        # SYN: 对端真实源 MAC (synp 据此配 CAM0 dmac), 目的 = DUT MAC
        eth = DUT_MAC + c['dmac'] + b'\x08\x00'
    else:
        eth = c['dmac'] + c['pcmac'] + b'\x08\x00'
    tcp = struct.pack('!HHLLBBHHH', c['sport'], c['dport'], seq & 0xFFFFFFFF,
                      ack & 0xFFFFFFFF, 0x50, flags, wnd & 0xFFFF, 0, 0)
    seg = tcp + payload(n)
    ph = struct.pack('!4s4sBBH', struct.pack('!I', c['sip']),
                     struct.pack('!I', c['dip']), 0, 6, len(seg))
    buf = ph + seg
    if len(buf) % 2:
        buf += b'\x00'
    cs = csum16(struct.unpack('!%dH' % (len(buf) // 2), buf))
    seg = seg[:16] + struct.pack('!H', cs) + seg[18:]
    ip = ip_hdr(c['sip'], c['dip'], 20 + len(seg))
    fb = eth + ip + seg
    if pad and len(fb) < 60:
        fb += b'\x00' * (60 - len(fb))
    fcs = struct.pack('<I', zlib.crc32(fb) & 0xFFFFFFFF)
    return fb, fcs


def build_rx_frames():
    """kind: syn / data / ack / drop_ack。conn0 snd_una 链从握手后 6000 起;
    snd_nxt 链: SYN+ACK 发完 6000, app 数据帧接续。seq/ack 由连接状态链式推出。"""
    F = []

    def add(name, cid, kind, plen, seq, ack, wnd, pad=False, flags=0x10, gap=0):
        F.append(dict(name=name, cid=cid, kind=kind, plen=plen, seq=seq,
                      ack=ack, wnd=wnd, pad=pad, flags=flags, gap=gap))

    # ---- 三次握手: SYN (纯 SYN, 60B 补 pad) -> DUT SYN+ACK -> 对端 ACK ----
    add('syn', 0, 'syn', 0, SYN_SEQ, 0, SYN_WND, pad=True, flags=0x02)
    add('hs_ack', 0, 'ack', 0, 1000, 6000, SYN_WND, gap=HS_GAP)  # una 5999->6000
    # ---- 原 conn0/conn1 流量 (snd_una 链 5000 起 -> 6000 起, 顺移 +1000) ----
    add('ack_pure', 0, 'ack', 0, 1000, 6100, 0x4000)          # snd_una 6000->6100
    add('data42', 0, 'data', 42, 1000, 6150, 0x4000)          # rcv 1042; una->6150
    add('data100', 0, 'data', 100, 1042, 6150, 0x4000)        # rcv 1142
    add('ack_pad', 0, 'ack', 0, 1142, 6200, 0x3000, pad=True)  # una->6200 wnd 3000
    add('data1000', 0, 'data', 1000, 1142, 6300, 0x4000)      # rcv 2142; una->6300
    add('dup', 0, 'drop_ack', 20, 2142 - 500, 6300, 0x4000)   # 丢数据回 ACK 2142
    add('ooo', 0, 'drop_ack', 30, 2142 + 100, 6300, 0x4000)   # 乱序回 ACK 2142
    add('data64', 0, 'data', 64, 2142, 6300, 0x4000)          # rcv 2206
    add('c1data50', 1, 'data', 50, 77, 900, 0x1A00)           # c1 rcv 127
    add('data200', 0, 'data', 200, 2206, 6300, 0x4000)        # rcv 2406
    # 反应式 PC 纯 ACK (DUT 数据段确认, 值 = 段 seq+len; 序 = TX 完成序)
    add('pcack30', 0, 'ack', 0, 2406, 6030, 0x4000)
    add('pcack80', 0, 'ack', 0, 2406, 6110, 0x4000)
    add('pcack20', 1, 'ack', 0, 127, 920, 0x2200)
    add('pcack300', 0, 'ack', 0, 2406, 6410, 0x4000)
    # ---- 末尾: SYN 重传 (幂等; 重置 conn0 回握手后初态) ----
    add('syn_re', 0, 'syn', 0, SYN_SEQ, 0, SYN_WND, pad=True, flags=0x02,
        gap=RESYN_GAP)
    off = 0
    for f in F:
        off += f['gap']
        fb, fcs = mk_tcp_frame(f['cid'], f['seq'], f['ack'], f['flags'],
                               f['plen'], f['wnd'], f['pad'])
        f['fb'] = fb
        f['fcs'] = fcs
        f['first'] = off + 8        # 内容首字节在字节流中的索引
        f['B'] = len(fb)
        off += 8 + len(fb) + 4 + 12
    return F


APP_FRAMES = [('d30', 0, 30), ('d80', 0, 80), ('d20', 1, 20), ('d300', 0, 300)]
ANCHOR0 = dict(d30=500, d80=649, d20=762, d300=1715)   # 初值 (已求解收敛)


def pop8(k):
    return bin(k).count('1')


def fold16(v):
    f1 = (v & 0xFFFF) + (v >> 16)
    return ((f1 & 0xFFFF) + (f1 >> 16)) & 0xFFFF


# ---------------- RX 侧周期精确模型 (mac_rx_64 + fifo8 + tcp_rx 时序壳) ----------------

def rx_model(frames, snd_nxt_init=None, snd_nxt_events=(), good=None,
             suppress_data_ack=False):
    """snd_nxt 时变处理: w5 判读的 ack_ok 需 ra_snd_nxt 真实时值。握手后 una 链
    (+1000) 前段会超过 TX 实发进度 (DUT 合法拒推进 una: ACK 了未发数据) — 终值
    等价假设不再成立, 按事件表应用: snd_nxt_events = [(beat, cid, val)]
    (synp sel1 写 iss + tx sel1 写)。bootstrap 用 snd_nxt_init 静态终值。
    字拍/fend/ack 流与 snd_nxt 无关 (acc 不看 ack_ok), 仅 drains 受影响。
    good: 每帧 FCS 好坏列表 (None = 全好; echo 场景的坏 CRC 帧用)。
    suppress_data_ack: echo 应用场景 (wrapper_p4 置 1) — 接受的顺序数据段不发
    纯 ACK (echo 帧自带 ack); dup/ooo 的 drop_ack 不抑制。"""
    nstim = max(f['first'] + f['B'] + 4 + 12 for f in frames)
    tmax = nstim + 200
    tmax = nstim + 200
    # 帧字节 -> (byte, dv) 按索引
    sdata = [0] * nstim
    sdv = [0] * nstim
    for f in frames:
        stream = PRE + f['fb'] + f['fcs']
        base = f['first'] - 8
        for j, b in enumerate(stream):
            sdata[base + j] = b
            sdv[base + j] = 1
    if good is None:
        good = [True] * len(frames)
    crs_list = [g for g in good] + [False]

    # mac_rx_64 状态
    mst, pre_cnt, bcnt, fbytes = 'IDLE', 0, 0, 0
    dline, wreg, ferr, first_done, hwv, hwreg = [0] * 4, [0] * 8, False, False, False, None
    fidx = 0
    wptr = rptr = 0
    mem = [None] * 8
    dout = None
    # cam / tcb (conn0 不预写 — 由 synp 握手建立; conn1 cphase 预写)
    cam = [None,
           (CONN[1]['sip'], CONN[1]['dip'], CONN[1]['sport'], CONN[1]['dport'])] + \
          [None] * 14
    tcb = fresh_tcb()
    if snd_nxt_init:
        for cid, v in snd_nxt_init.items():
            tcb[cid]['snd_nxt'] = v
    snx_at = {}
    for b, cid, v in snd_nxt_events:
        snx_at.setdefault(b, []).append((cid, v))
    # synp 离线模型: syn_v 拍 kv -> CAM0 写 kv+3 可见; TCB0 六字段 TUPD kv+3..kv+8;
    # sack 入队 kv+9 (syn=1)。应用拍 = TB 日志拍 (同 drain 约定)。
    camw_at = {}
    tcbw_at = {}
    synp_tcbw = []
    sacks = []
    syns = []

    def gen_syn(kv, fi):
        """kv = syn_v 日志拍; fi = frames 索引。"""
        f = frames[fi]
        c = CONN[f['cid']]
        syns.append((kv, fi))
        camw_at[kv + 3] = (c['sip'], c['dip'], c['sport'], c['dport'])
        vals = [(f['seq'] + 1) & 0xFFFFFFFF, SYNP_ISS, SYNP_ISS,
                0x3000, f['wnd'] & 0xFFFF, 1]
        for fi2, v in enumerate(vals):
            tcbw_at.setdefault(kv + 3 + fi2, []).append((fi2, v))
            synp_tcbw.append((kv + 3 + fi2, fi2, 0, v))
        sacks.append((kv + 9, 0, (f['seq'] + 1) & 0xFFFFFFFF, 1))

    def cam_lookup(sip, dip, sport, dport):
        for i in range(16):
            if cam[i] is not None and cam[i] == (sip, dip, sport, dport):
                return True, i
        return False, 0

    # tcp_rx 时序壳状态 (无 emit 路径; m_axis_tready=1)
    st, wcnt = 'HDR', 0
    w1_lo = w2r = w3r = ipc_s9 = 0
    src_ip_r = src_port_r = seq_hi_r = 0
    syn_l = False
    drop_syn = False
    cam_hit_l = False
    conn_id_l = 0
    acc_l = ackresp_l = ack_adv_l = False
    ack32_l = seq32_l = rcv_nxt_l = plen_l = wnd_l = 0
    drop_ack = False
    pcount = 0
    tail_c = 0
    pend_rcv = pend_una = pend_wnd = False
    pend_id = pend_rcv_val = pend_una_val = pend_wnd_val = 0
    drn = 0
    last_fend = -100
    stats = dict(pss=0, nonmatch=0, ipcsum=0, crc=0, seq=0, ack=0, bytes=0)
    fends, acks, drains, w5cyc = [], [], [], []
    fcur = -1

    for t in range(tmax):
        j = t - 41
        by, dvv = (sdata[j], sdv[j]) if 0 <= j < nstim else (0, 0)
        # ---- synp 写生效 (CAM0 / TCB0; snd_nxt 由事件表单独应用) ----
        if t in camw_at:
            cam[0] = camw_at[t]
        if t in tcbw_at:
            for sel, v in tcbw_at[t]:
                if sel != 1:
                    tcb[0][SEL2FIELD[sel]] = v & 0xFFFF if sel in (3, 4) else v
        if t in snx_at:
            for cid, v in snx_at[t]:
                tcb[cid]['snd_nxt'] = v
        full = ((wptr & 7) == (rptr & 7)) and (wptr >> 3) != (rptr >> 3)
        empty = wptr == rptr
        w = dout if not empty else None
        # ---- tcp_rx 壳 (tready=1: HDR/PAY/PAD/DROP 恒接受, TAIL 停) ----
        accept = (w is not None) and (tail_c == 0)
        fend = 0
        ferr_b = 0
        fend_w6 = False
        if tail_c:
            tail_c -= 1
            if tail_c == 0:
                st, wcnt = 'HDR', 0
        elif accept:
            if st == 'HDR':
                wc = 0 if w[2] else wcnt
                if w[2]:
                    fcur += 1
                if w[3] and wc != 6:
                    st, wcnt = 'HDR', 0
                    stats['nonmatch'] += 1
                elif wc == 0:
                    if w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        wcnt = 1
                elif wc == 1:
                    if (w[1] != 0xFF or ((w[0] >> 16) & 0xFFFF) != 0x0800 or
                            ((w[0] >> 8) & 0xFF) != 0x45):
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        w1_lo = w[0] & 0xFFFF
                        wcnt = 2
                elif wc == 2:
                    if w[1] != 0xFF or (w[0] & 0xFF) != 0x06:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        w2r = w[0]
                        wcnt = 3
                elif wc == 3:
                    if w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        w3r = w[0] & 0xFFFF
                        src_ip_r = (w[0] >> 16) & 0xFFFFFFFF
                        ipc_s9 = (w1_lo + (w2r & 0xFFFF) + ((w2r >> 16) & 0xFFFF) +
                                  ((w2r >> 32) & 0xFFFF) + ((w2r >> 48) & 0xFFFF) +
                                  (w[0] & 0xFFFF) + ((w[0] >> 16) & 0xFFFF) +
                                  ((w[0] >> 32) & 0xFFFF) + ((w[0] >> 48) & 0xFFFF))
                        wcnt = 4
                elif wc == 4:
                    if w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    elif fold16(ipc_s9 + ((w[0] >> 48) & 0xFFFF)) != 0xFFFF:
                        st, drop_ack = 'DROP', False
                        stats['ipcsum'] += 1
                    else:
                        dip = (w3r << 16) | ((w[0] >> 48) & 0xFFFF)
                        hit, cid = cam_lookup(src_ip_r, dip,
                                              (w[0] >> 32) & 0xFFFF,
                                              (w[0] >> 16) & 0xFFFF)
                        cam_hit_l, conn_id_l = hit, cid
                        src_port_r = (w[0] >> 32) & 0xFFFF
                        seq_hi_r = w[0] & 0xFFFF
                        wcnt = 5
                elif wc == 5:
                    if w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        w5cyc.append(t)
                        seq32 = (seq_hi_r << 16) | ((w[0] >> 48) & 0xFFFF)
                        ack32 = (w[0] >> 16) & 0xFFFFFFFF
                        flags = w[0] & 0xFF
                        flags_ok = ((flags >> 4) & 1) and not (flags & 0x07)
                        doff_ok = ((w[0] >> 12) & 0xF) == 5
                        tb = tcb[conn_id_l]
                        state_ok = tb['state'] == 1
                        len_ok = ((w2r >> 48) & 0xFFFF) >= 40
                        seq_diff = (seq32 - tb['rcv_nxt']) & 0xFFFFFFFF
                        win_ok = seq_diff < tb['rcv_wnd']
                        seq_eq = seq32 == tb['rcv_nxt']
                        seq_lt = seq32 < tb['rcv_nxt']
                        ack_ok = (((ack32 - tb['snd_una']) & 0xFFFFFFFF) <=
                                  ((tb['snd_nxt'] - tb['snd_una']) & 0xFFFFFFFF))
                        ack_adv = ack_ok and ack32 != tb['snd_una']
                        plen_w = (((w2r >> 48) & 0xFFFF) - 40) & 0xFFFF
                        base_ok = (cam_hit_l and state_ok and flags_ok and
                                   doff_ok and len_ok and
                                   ((w2r >> 16) & 0x3FFF) == 0)
                        acc_l = base_ok and win_ok and seq_eq
                        ackresp_l = (base_ok and not seq_eq and
                                     (win_ok or seq_lt) and plen_w != 0)
                        ack_adv_l = ack_adv
                        ack32_l, seq32_l = ack32, seq32
                        plen_l = plen_w
                        rcv_nxt_l = tb['rcv_nxt']
                        syn_l = (flags == 0x02)   # 纯 SYN
                        wcnt = 6
                else:      # wc == 6
                    pop8w = pop8(w[1])
                    w6_ok = acc_l and plen_l <= 2 and pop8w == 6 + (plen_l & 0xF)
                    if w[3]:
                        st, wcnt = 'HDR', 0
                        if w6_ok:
                            if w[4]:
                                stats['pss'] += 1
                            else:
                                stats['crc'] += 1
                            if plen_l != 0:
                                stats['bytes'] += plen_l
                            fend = 1
                            fend_w6 = True
                            ferr_b = 1 if ((not w[4]) or w[5]) else 0
                        elif ackresp_l:
                            stats['seq'] += 1
                        else:
                            # 纯 SYN 短帧 (w6-tlast): 帧尾即报握手
                            if syn_l and w[4] and not w[5]:
                                gen_syn(t + 1, fcur)
                            stats['nonmatch'] += 1
                    elif acc_l:
                        if plen_l == 0:
                            st = 'PAD'
                        else:
                            st = 'PAY'
                            pcount = 2 if plen_l >= 2 else 1
                        wnd_l = (w[0] >> 48) & 0xFFFF
                        wcnt = 7
                    elif ackresp_l:
                        st, drop_ack, drop_syn = 'DROP', True, False
                        stats['seq'] += 1
                    else:
                        st, drop_ack, drop_syn = 'DROP', False, syn_l
                        stats['nonmatch'] += 1
            elif st == 'PAY':
                if w[2]:
                    if w[3]:
                        st, wcnt = 'HDR', 0
                        stats['nonmatch'] += 1
                    elif w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        st, wcnt = 'HDR', 1
                elif w[3]:
                    pop8w = pop8(w[1])
                    pay_r = plen_l - pcount
                    st, wcnt = 'HDR', 0
                    if pop8w < pay_r:
                        stats['nonmatch'] += 1
                    else:
                        if w[4]:
                            stats['pss'] += 1
                            stats['bytes'] += plen_l
                        else:
                            stats['crc'] += 1
                        if pay_r > 6:
                            st = 'TAIL'
                            tail_c = 2
                        fend = 1
                        ferr_b = 1 if ((not w[4]) or w[5]) else 0
                else:
                    if w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    elif pcount + 8 > plen_l:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        pcount += 8
            elif st == 'PAD':
                if w[2]:
                    if w[3]:
                        st, wcnt = 'HDR', 0
                        stats['nonmatch'] += 1
                    elif w[1] != 0xFF:
                        st, drop_ack = 'DROP', False
                        stats['nonmatch'] += 1
                    else:
                        st, wcnt = 'HDR', 1
                elif w[3]:
                    st, wcnt = 'HDR', 0
                    if w[4]:
                        stats['pss'] += 1
                    else:
                        stats['crc'] += 1
                    fend = 1
                    ferr_b = 1 if ((not w[4]) or w[5]) else 0
            else:      # DROP
                if w[3]:
                    st, wcnt = 'HDR', 0
                    if drop_syn and w[4] and not w[5]:
                        # SYN 帧 S_DROP 帧尾报握手 (syn_v 拍 = t+1)
                        gen_syn(t + 1, fcur)
                    if drop_ack and w[4]:
                        # S_DROP 帧尾 ACK (dup/ooo): val = rcv_nxt_l (本拍组合有效)
                        acks.append((t, conn_id_l, rcv_nxt_l, 0))
                        stats['ack'] += 1
                    drop_ack = False
                    drop_syn = False
        # ---- 组合 fend/ack/drain (事件拍 = t) ----
        if fend:
            fends.append((t, ferr_b))
            last_fend = t
            pend_rcv = bool(acc_l and plen_l != 0 and w[4])
            pend_una = bool(ack_adv_l and w[4])
            pend_wnd = bool(w[4])
            pend_id = conn_id_l
            pend_rcv_val = (rcv_nxt_l + plen_l) & 0xFFFFFFFF
            pend_una_val = ack32_l
            pend_wnd_val = ((w[0] >> 48) & 0xFFFF) if fend_w6 else wnd_l
            drn = 1
            if plen_l != 0 and w[4] and not suppress_data_ack:
                acks.append((t, conn_id_l, (rcv_nxt_l + plen_l) & 0xFFFFFFFF, 0))
                stats['ack'] += 1
        if drn and not fend:
            if drn == 1:
                if pend_rcv:
                    drains.append((last_fend, 0, 0, pend_id, pend_rcv_val))
                    tcb[pend_id]['rcv_nxt'] = pend_rcv_val
                drn = 2
            elif drn == 2:
                if pend_una:
                    drains.append((last_fend, 1, 2, pend_id, pend_una_val))
                    tcb[pend_id]['snd_una'] = pend_una_val
                drn = 3
            elif drn == 3:
                if pend_wnd:
                    drains.append((last_fend, 2, 4, pend_id, pend_wnd_val))
                    tcb[pend_id]['snd_wnd'] = pend_wnd_val & 0xFFFF
                drn = 0
        # ---- mac_rx_64 (照抄参考模型) ----
        wr = False
        din = None
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
                    d = int.from_bytes(bytes(hwreg).ljust(8, b'\x00'), 'big')
                    din = (d, 0xFF, not first_done, bcnt == 0,
                           crs_list[fidx - 1] if bcnt == 0 else False, ferr)
                    wr = True
                    first_done = True
                    if bcnt == 0:
                        mst = 'IDLE'
                    else:
                        mst = 'FLUSH'
                elif hwv and full:
                    mst, hwv = 'DROP', False
                elif bcnt == 0:
                    mst = 'IDLE'
                else:
                    n = bcnt
                    d = int.from_bytes(bytes(wreg[:bcnt]).ljust(8, b'\x00'), 'big')
                    keep = (0xFF << (8 - n)) & 0xFF
                    din = (d, keep, True, True, crs_list[fidx - 1], ferr)
                    wr = True
                    mst = 'IDLE'
            else:
                if fbytes >= 4:
                    b = dline[0]
                    if bcnt == 7:
                        if hwv and full:
                            mst, hwv = 'DROP', False
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
            else:
                n = bcnt
                d = int.from_bytes(bytes(wreg[:bcnt]).ljust(8, b'\x00'), 'big')
                keep = (0xFF << (8 - n)) & 0xFF
                din = (d, keep, not first_done, True, crs_list[fidx - 1], ferr)
                wr = True
                mst = 'IDLE'
        elif mst == 'DROP':
            if not dvv:
                mst = 'IDLE'
        # ---- fifo_sync(8) ----
        rd_ok = accept
        rptr_n = rptr + (1 if (rd_ok and not empty) else 0)
        bypass = wr and not full and ((rptr_n & 7) == (wptr & 7))
        if wr and not full:
            mem[wptr & 7] = din
            wptr += 1
        if rd_ok and not empty:
            rptr += 1
        dout = din if bypass else (mem[rptr & 7] if not (wptr == rptr) else None)
    return dict(fends=fends, acks=acks, drains=drains, stats=stats,
                tcb=tcb, w5cyc=w5cyc, nstim=nstim,
                syns=syns, sacks=sacks, synp_tcbw=synp_tcbw)


# ---------------- TX 侧周期精确模型 (app 驱动 + tcp_tx_frame + mac_tx_64 时序) ----------------

def compute_schedule(drains, txk):
    """drains: [(fend, di, sel, id, val)] (di = drn 级号 0/1/2)。RTL drn FSM 每级至少
    占一拍: 级 di 首拍 = fend+1+di + 前级滞留; pend 且未 gnt (撞 txk) 才滞留顺延;
    pend=0 的级不占写但仍耗一拍过级。返回 (rxw, rxreq): rxw = [(grant_k, sel, id, val)];
    rxreq = rx upd_wr 高电平拍集合 (含保持拍) — COLL 检测用。"""
    rxw = []
    rxreq = set()
    byf = {}
    for fend, di, sel, i, v in drains:
        byf.setdefault(fend, {})[di] = (sel, i, v)
    for fend in sorted(byf):
        cursor = fend + 1
        fields = byf[fend]
        for di in (0, 1, 2):
            base = max(cursor, fend + 1 + di)
            if di in fields:
                sel, i, v = fields[di]
                g = base
                while g in txk:
                    g += 1
                for c in range(base, g + 1):
                    rxreq.add(c)
                rxw.append((g, sel, i, v))
                cursor = g + 1
            else:
                cursor = base + 1     # pend=0: 过级仍耗一拍
    return rxw, rxreq


def tx_model(acks, rxw, rxreq, anchors, cfgw_at=None):
    """acks: [(k,id,val,syn)] ack_req/sack_req 脉冲 (拍 k 组合有效, 当拍末入队, 拍 k+1 可见);
    rxw/rxreq: compute_schedule 结果; anchors: {name: k} (TB 驱动器等到 k>=anchor);
    cfgw_at: {k: [(sel,id,val)]} synp 的 TCB0 cfg 级写 (应用拍 = 日志拍)。"""
    tmax = 9000
    items = []
    for name, cid, plen in APP_FRAMES:
        items.append(('G', anchors[name], 0, cid))
        ws = [min(8, plen - o) for o in range(0, plen, 8)] or [0]
        for j, nb in enumerate(ws):
            items.append(('W', nb, 1 if j == len(ws) - 1 else 0, cid))
    ack_at = {}
    for k, i, v, s in acks:
        ack_at.setdefault(k, []).append((i, v, s))
    rxw_at = {}
    for k, sel, i, v in rxw:
        rxw_at.setdefault(k, []).append((sel, i, v))

    tcb = fresh_tcb()
    st = 'IDLE'
    plen = 0
    plen_r = 0
    wait_cnt = 0
    hcnt = 0
    cur_id = 0
    is_data = False
    is_syn_r = False
    seq_r = ack_r = 0
    id_r = 0
    tail_nb = 0
    bus_v = False
    bus_nb = 0
    bus_last = False
    presenting = False
    tvalid = False
    si = 0
    w_nb = w_last = w_cid = 0
    aq_w = aq_r = 0
    aq = []
    pq_w = pq_r = 0
    pq = []
    mq_w = mq_r = 0
    mq = []
    frd = False
    mest = 'IDLE'
    pre_cnt = 0
    cw_len = cw_idx = 0
    cw_last = False
    mplen = 0
    pad_cnt = 0
    fcs_cnt = 0
    ifg_cnt = 0
    frames = []
    tupds = []
    colls = []
    sdone = {}
    stats = [0, 0, 0, 0]
    appidx = 0
    starts = []

    for t in range(tmax):
        ack_pend = aq_w > aq_r
        pay_empty = pq_w == pq_r
        pay_full = (pq_w - pq_r) >= 256
        mac_level = mq_w - mq_r
        mac_ready = mac_level < 16
        tready = ((st == 'RECV') or (st == 'IDLE' and not ack_pend)) and not pay_full
        accept = tvalid and tready
        start_ack = (st == 'IDLE') and ack_pend
        start_data = (st == 'IDLE') and not ack_pend and tvalid and not pay_full
        start_id = aq[aq_r][0] if ack_pend else w_cid

        ev_push_aq = ack_at.get(t, [])
        ev_push_pq = None
        ev_pop_pq = False
        ev_push_mq = None
        ev_pop_aq = False
        ev_tcbw = list(rxw_at.get(t, []))
        if cfgw_at:
            ev_tcbw += list(cfgw_at.get(t, []))
        upd_event = None

        # ---- mac_tx_64 引擎 (frd 注册语义: 决策拍加载 cw, 下拍指针前进) ----
        next_frd = False
        if frd:
            mq_r += 1
        if mest == 'IDLE':
            if mac_level > 0:
                mest, pre_cnt = 'PRE', 0
        elif mest == 'PRE':
            if pre_cnt == 7:
                if mac_level > 0:
                    nb, last = mq[mq_r]
                    cw_len, cw_idx, cw_last, mplen = nb, 0, last, 0
                    mest = 'DATA'
                    next_frd = True
                else:
                    mest, ifg_cnt = 'IFG', 0
            else:
                pre_cnt += 1
        elif mest == 'DATA':
            mplen += 1
            if cw_idx == cw_len - 1:
                if cw_last:
                    if mplen + 1 >= 60:      # pad 基准 = 60B 内容 (含以太头)
                        mest, fcs_cnt = 'FCS', 0
                    else:
                        mest, pad_cnt = 'PAD', 60 - mplen - 1
                elif mac_level > 0:
                    nb, last = mq[mq_r]
                    cw_len, cw_idx, cw_last = nb, 0, last
                    next_frd = True
                else:
                    raise RuntimeError('mac abort at t=%d' % t)
            else:
                cw_idx += 1
        elif mest == 'PAD':
            if pad_cnt == 0:
                mest, fcs_cnt = 'FCS', 0
            else:
                pad_cnt -= 1
                if pad_cnt == 1:
                    mest, fcs_cnt = 'FCS', 0
        elif mest == 'FCS':
            if fcs_cnt == 3:
                mest, ifg_cnt = 'IFG', 0
            else:
                fcs_cnt += 1
        elif mest == 'IFG':
            if ifg_cnt == 11:
                mest = 'IDLE'
            else:
                ifg_cnt += 1

        # ---- m_axis 总线词消费 (进 mac fifo, wr 于本拍末) ----
        if bus_v and mac_ready:
            ev_push_mq = (bus_nb, bus_last)

        # ---- tcp_tx_frame 状态机 ----
        if st == 'IDLE':
            if start_ack or start_data:
                tb = tcb[start_id]
                cur_id = start_id
                is_data = start_data
                is_syn_r = bool(start_ack and aq[aq_r][2])
                seq_r = tb['snd_nxt']
                ack_r = tb['rcv_nxt'] if start_data else aq[aq_r][1]
                id_cap = id_r
                id_r += 1
                if start_data:
                    ev_push_pq = (w_nb, w_last)
                    plen = w_nb
                    if w_last:
                        plen_r = w_nb
                        st, wait_cnt = 'WAIT', 0
                    else:
                        st = 'RECV'
                else:
                    ev_pop_aq = True
                    plen_r = 0
                    st, wait_cnt = 'WAIT', 0
                frames.append(dict(kind='data' if start_data else
                                   ('synack' if is_syn_r else 'ack'),
                                   cid=cur_id, seq=seq_r, ack=ack_r,
                                   plen=None, idx=id_cap,
                                   name=APP_FRAMES[appidx][0] if start_data else ''))
                if start_data:
                    appidx += 1
                    starts.append((frames[-1]['name'], t))
        elif st == 'RECV':
            if accept:
                ev_push_pq = (w_nb, w_last)
                plen += w_nb
                if w_last:
                    plen_r = plen
                    st, wait_cnt = 'WAIT', 0
        elif st == 'WAIT':
            if wait_cnt == 4:
                st, hcnt = 'HDR', 0
            else:
                wait_cnt += 1
        elif st == 'HDR':
            if (not bus_v) or mac_ready:
                if hcnt == 5:
                    st = 'PAY'
                else:
                    hcnt += 1
                bus_v, bus_nb, bus_last = True, 8, False
        elif st == 'PAY':
            if (not bus_v) or mac_ready:
                if plen_r == 0:
                    bus_v, bus_nb, bus_last = True, 6, True
                    st = 'DONE'
                elif pay_empty:
                    raise RuntimeError('pay underflow at t=%d' % t)
                else:
                    nb, last = pq[pq_r]
                    ev_pop_pq = True
                    if not last:
                        bus_v, bus_nb, bus_last = True, 8, False
                    elif nb < 2:
                        bus_v, bus_nb, bus_last = True, 6 + nb, True
                        st = 'DONE'
                    elif nb == 2:
                        bus_v, bus_nb, bus_last = True, 8, True
                        st = 'DONE'
                    else:
                        bus_v, bus_nb, bus_last = True, 8, False
                        tail_nb = nb - 2
                        st = 'TAIL'
        elif st == 'TAIL':
            if (not bus_v) or mac_ready:
                bus_v, bus_nb, bus_last = True, tail_nb, True
                st = 'DONE'
        else:      # DONE
            if (not bus_v) or mac_ready:
                stats[0] += 1
                stats[1] += plen_r
                if is_data:
                    if bus_v and mac_ready:
                        upd_event = (t, 1, cur_id, (seq_r + plen_r) & 0xFFFFFFFF)
                        sdone[frames[-1]['name']] = t
                else:
                    stats[2] += 1
                    if is_syn_r and bus_v and mac_ready:
                        # SYN+ACK 发完 snd_nxt+1 (与数据段同: 末字消费拍)
                        upd_event = (t, 1, cur_id, (seq_r + 1) & 0xFFFFFFFF)
                frames[-1]['plen'] = plen_r
                bus_v = False
                st = 'IDLE'

        # ---- app presenting 驱动 ----
        if presenting:
            if accept:
                presenting = False
                tvalid = False
        elif si < len(items):
            it = items[si]
            if it[0] == 'W':
                w_nb, w_last, w_cid = it[1], it[2], it[3]
                presenting = True
                tvalid = True
                si += 1
            else:
                if t >= it[1]:
                    si += 1

        # ---- 提交 (NBA) ----
        if ev_push_mq is not None:
            mq.append(ev_push_mq)
            mq_w += 1
        if ev_push_pq is not None:
            pq.append(ev_push_pq)
            pq_w += 1
        if ev_pop_pq:
            pq_r += 1
        for i, v, s in ev_push_aq:
            if aq_w - aq_r >= 8:
                stats[3] += 1
            else:
                aq.append((i, v, s))
                aq_w += 1
        if ev_pop_aq:
            aq_r += 1
        frd = next_frd
        if upd_event is not None:
            tupds.append(upd_event)
            ev_tcbw.append((upd_event[1], upd_event[2], upd_event[3]))
            if t in rxreq:
                colls.append(t)
        for sel, i, v in ev_tcbw:
            tcb[i][SEL2FIELD[sel]] = v if sel in (0, 1, 2) else (v & 0xFFFF)
    return dict(frames=frames, tupds=tupds, colls=colls, sdone=sdone,
                stats=stats, tcb=tcb, rxw=rxw, rxreq=rxreq, items=items,
                starts=starts)


def solve_and_build():
    frames = build_rx_frames()
    snd_final = {0: 6000 + 30 + 80 + 300, 1: 900 + 20}
    rx = rx_model(frames, snd_nxt_init=snd_final)     # bootstrap (字拍/fend/ack 无关 snd_nxt)
    cfgw_at = {}
    for k, sel, i, v in rx['synp_tcbw']:
        cfgw_at.setdefault(k, []).append((sel, i, v))
    fend_frames = [f for f in frames if f['kind'] not in ('drop_ack', 'syn')]
    fend_of = {}
    for f, (k, fe) in zip(fend_frames, rx['fends']):
        assert fe == 0, f['name']
        fend_of[f['name']] = k
        f['fend'] = k
    anchors = dict(ANCHOR0)
    txk = set()
    tx = None
    for _ in range(12):
        all_acks = sorted(rx['acks'] + rx['sacks'], key=lambda a: a[0])
        rxw, rxreq = compute_schedule(rx['drains'], txk)
        tx = tx_model(all_acks, rxw, rxreq, anchors, cfgw_at)
        # 碰撞锚点: S_DONE 对齐 fend+1 (rcv_nxt drain 拍 — 数据帧恒有; 握手场景下
        # 前段 una drain 被 DUT 合法拒绝 (ack 超前 snd_nxt), 不再可作锚)
        d80 = fend_of['data42'] + 1 - tx['sdone']['d80']
        d300 = fend_of['data1000'] + 1 - tx['sdone']['d300']
        newtxk = set(u[0] for u in tx['tupds'])
        # 真值 snd_nxt 事件重算 RX drains (synp sel1 + tx sel1)
        snd_events = sorted([(k, i, v) for k, sel, i, v in rx['synp_tcbw'] if sel == 1] +
                            [(k, i, v) for k, sel, i, v in tx['tupds'] if sel == 1])
        rx2 = rx_model(frames, snd_nxt_events=snd_events)
        converged = (d80 == 0 and d300 == 0 and newtxk == txk and
                     rx2['drains'] == rx['drains'])
        rx = rx2
        if converged:
            break
        anchors['d80'] += d80
        anchors['d300'] += d300
        txk = newtxk
    else:
        raise RuntimeError('anchor solve did not converge')
    # 终次重算 (shifts 用收敛后的 txk)
    all_acks = sorted(rx['acks'] + rx['sacks'], key=lambda a: a[0])
    rxw, rxreq = compute_schedule(rx['drains'], set(u[0] for u in tx['tupds']))
    tx = tx_model(all_acks, rxw, rxreq, anchors, cfgw_at)
    return frames, rx, tx, anchors, fend_of


# ---------------- 生成 + 校验 ----------------

def gen_memh(simdir, frames, tx, anchors):
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
        # 仅 conn1 (条目 0 归 synp 握手建立)
        for fld in FIELDS:
            fh.write('%X\n' % TCB1_INIT[fld])
    # app 脚本: 每帧 = 锚点项 (ty0, n=anchor) + 载荷词 (ty1)
    ty, d, k, l, n, ci = [], [], [], [], [], []
    for name, cid, plen in APP_FRAMES:
        ty.append(0); d.append(0); k.append(0); l.append(0)
        n.append(anchors[name]); ci.append(0)
        pl = payload(plen)
        for o in range(0, plen, 8):
            chunk = pl[o:o + 8]
            wd = int.from_bytes(chunk.ljust(8, b'\x00'), 'big')
            keep = (0xFF << (8 - len(chunk))) & 0xFF
            ty.append(1); d.append(wd); k.append(keep)
            l.append(1 if o + 8 >= plen else 0)
            n.append(0); ci.append(cid)
    w('txp_ty.memh',   ty, '%X')
    w('txp_data.memh', d,  '%016X')
    w('txp_keep.memh', k,  '%02X')
    w('txp_last.memh', l,  '%X')
    w('txp_gap.memh',  n,  '%X')
    w('txp_id.memh',   ci, '%X')


def expected_frame_bytes(fr):
    """模型帧 -> 线上内容字节 (不含前导/FCS)。TX 帧 dst IP = 对端 IP = CAM 的 sip
    字段 (dip 字段是本地 IP, 只用于 RX 匹配) — 曾错用 dip, 板测 SYN+ACK 目的 IP
    写成本机被 Windows 丢弃。"""
    cid = fr['cid']
    c = CONN[cid]
    pl = payload(fr['plen']) if fr['kind'] == 'data' else b''
    flags = (0x18 if fr['kind'] == 'data' else
             (0x12 if fr['kind'] == 'synack' else 0x10))
    eth = c['dmac'] + DUT_MAC + b'\x08\x00'
    tcp = struct.pack('!HHLLBBHHH', c['dport'], c['sport'], fr['seq'] & 0xFFFFFFFF,
                      fr['ack'] & 0xFFFFFFFF, 0x50, flags, c['rcv_wnd'], 0, 0)
    seg = tcp + pl
    ph = struct.pack('!4s4sBBH', struct.pack('!I', DUT_IP),
                     struct.pack('!I', c['sip']), 0, 6, len(seg))
    buf = ph + seg
    if len(buf) % 2:
        buf += b'\x00'
    cs = csum16(struct.unpack('!%dH' % (len(buf) // 2), buf))
    seg = seg[:16] + struct.pack('!H', cs) + seg[18:]
    total = 20 + len(seg)
    h = bytearray(struct.pack('!BBHHHBBH', 0x45, 0, total, fr['idx'] & 0xFFFF,
                              0, 64, 6, 0))
    h += struct.pack('!4s4s', struct.pack('!I', DUT_IP), struct.pack('!I', c['sip']))
    h[10:12] = struct.pack('!H', csum16(struct.unpack('!10H', bytes(h[:20]))))
    return eth + bytes(h) + seg


def parse_resp(fn):
    """返回 (gmii_bytes_per_frame, events)。行: '%02h %d' 字节 / FEND / ACK / SYNP / TUPD /
    COLL / STATS7 / STATS_TX / CAMF / TCBF。"""
    frames = []
    cur = []
    active = False
    bytecnt = 0          # 已见字节行数; 事件行 k = bytecnt - 2 (当拍字节行先写)
    ev = dict(fend=[], ack=[], synp=[], tupd=[], coll=[], stats7=None, stx=None,
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
                ev['synp'].append((bytecnt - 2, int(p[1], 16), int(p[2], 16),
                                   int(p[3], 16), int(p[4], 16), int(p[5], 16),
                                   int(p[6], 16)))
            elif p[0] == 'TUPD':
                ev['tupd'].append((int(p[1]), int(p[2]), int(p[3]), int(p[4], 16)))
            elif p[0] == 'COLL':
                ev['coll'].append(int(p[1]))
            elif p[0] == 'STATS7':
                ev['stats7'] = [int(x) for x in p[1:]]
            elif p[0] == 'STATS_TX':
                ev['stx'] = [int(x) for x in p[1:]]
            elif p[0] == 'CAMF':
                ev['camf'] = p[1:]
            elif p[0] == 'TCBF':
                ev['tcbf'] = p[1:]
            elif len(p) == 2:
                try:
                    b = int(p[0], 16)
                except ValueError:
                    continue
                bytecnt += 1
                if p[1] == '1':
                    cur.append(b)
                    active = True
                elif active:
                    frames.append(bytes(cur))
                    cur = []
                    active = False
    if active and cur:
        frames.append(bytes(cur))
    return frames, ev


def check(simdir):
    frames, rx, tx, anchors, fend_of = solve_and_build()
    fn = os.path.join(simdir, 'resp_tcp_chain.memh')
    if not os.path.exists(fn):
        print('missing %s' % fn)
        return False
    got, ev = parse_resp(fn)
    errs = []
    # ---- 帧序列 ----
    exp = tx['frames']
    if len(got) != len(exp):
        errs.append('frame count %d != %d' % (len(got), len(exp)))
    for i, (fb, fr) in enumerate(zip(got, exp)):
        ferr0 = len(errs)
        if len(fb) < 12 + 4:
            errs.append('frame %d runt %d' % (i, len(fb)))
            continue
        if fb[:8] != PRE:
            errs.append('frame %d preamble %s' % (i, fb[:8].hex()))
        body = fb[8:-4]
        fcs = fb[-4:]
        if struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF) != fcs:
            errs.append('frame %d fcs' % i)
        eb = expected_frame_bytes(fr)
        tag = '%s c%d %s' % (fr['kind'], fr['cid'],
                             ('len %d' % fr['plen']) if fr['kind'] == 'data'
                             else ('val %d' % fr['ack']))
        if len(body) < len(eb):
            errs.append('frame %d (%s) short %d < %d' % (i, tag, len(body), len(eb)))
            continue
        if body[:len(eb)] != eb:
            # 定位首个差异
            dpos = next(j for j in range(len(eb)) if body[j] != eb[j])
            errs.append('frame %d (%s) content diff @%d: %02x != %02x' %
                        (i, tag, dpos, body[dpos], eb[dpos]))
        pad = body[len(eb):]
        if any(pad):
            errs.append('frame %d (%s) nonzero pad' % (i, tag))
        print('frame %2d %-14s id=%d %s' % (i, tag, fr['idx'],
                                            'ok' if len(errs) == ferr0 else 'FAIL'))
    # ---- 事件序列 ----
    if ev['fend'] != rx['fends']:
        errs.append('FEND seq\n  exp %s\n  got %s' % (rx['fends'], ev['fend']))
    exp_ack = sorted([(k, i, v) for k, i, v, s in rx['acks'] + rx['sacks']])
    if ev['ack'] != exp_ack:
        errs.append('ACK seq\n  exp %s\n  got %s' % (exp_ack, ev['ack']))
    # SYNP 事件 (k 由字节行计数推得)
    exp_synp = []
    for k, fi in rx['syns']:
        f = frames[fi]
        c = CONN[f['cid']]
        exp_synp.append((k, int.from_bytes(c['dmac'], 'big'), c['sip'],
                         c['sport'], c['dport'], f['seq'], f['wnd']))
    if ev['synp'] != exp_synp:
        errs.append('SYNP seq\n  exp %s\n  got %s' % (exp_synp, ev['synp']))
    exp_tupd = sorted([(k, sel, i, v) for k, sel, i, v in tx['rxw']] +
                      [(k, sel, i, v) for k, sel, i, v in tx['tupds']] +
                      [(k, sel, i, v) for k, sel, i, v in rx['synp_tcbw']])
    if ev['tupd'] != exp_tupd:
        errs.append('TUPD seq\n  exp %s\n  got %s' % (exp_tupd, ev['tupd']))
    if ev['coll'] != tx['colls']:
        errs.append('COLL exp %s got %s' % (tx['colls'], ev['coll']))
    if len(tx['colls']) < 2:
        errs.append('engineered collisions < 2: %s' % tx['colls'])
    # ---- 统计 / TCB 终态 ----
    rs = rx['stats']
    exp7 = [rs['pss'], rs['nonmatch'], rs['ipcsum'], rs['crc'], rs['seq'],
            rs['ack'], rs['bytes']]
    if ev['stats7'] != exp7:
        errs.append('STATS7 exp %s got %s' % (exp7, ev['stats7']))
    if ev['stx'] != tx['stats']:
        errs.append('STATS_TX exp %s got %s' % (tx['stats'], ev['stx']))
    # CAMF = CAM 条目 0 = 握手建立的四元组 + 对端 MAC
    c0 = CONN[0]
    cexp = ['%08X' % c0['sip'], '%08X' % c0['dip'], '%04X' % c0['sport'],
            '%04X' % c0['dport'], '%012X' % int.from_bytes(c0['dmac'], 'big')]
    if [t.lower() for t in (ev['camf'] or [])] != [t.lower() for t in cexp]:
        errs.append('CAMF exp %s got %s' % (cexp, ev['camf']))
    texp = []
    for e in (0, 1):
        for fld in FIELDS:
            fmt = '%08X' if fld in ('rcv_nxt', 'snd_nxt', 'snd_una') else \
                  ('%04X' if fld in ('rcv_wnd', 'snd_wnd') else '%X')
            texp.append(fmt % tx['tcb'][e][fld])
    if [t.lower() for t in (ev['tcbf'] or [])] != [t.lower() for t in texp]:
        errs.append('TCBF exp %s got %s' % (texp, ev['tcbf']))
    print('anchors %s sdone %s colls %s' % (anchors, tx['sdone'], tx['colls']))
    print('SYNP exp %s got %s' % (exp_synp, ev['synp']))
    print('CAMF exp %s got %s' % (cexp, ev['camf']))
    print('STATS7 exp %s got %s' % (exp7, ev['stats7']))
    print('STATS_TX exp %s got %s' % (tx['stats'], ev['stx']))
    print('TCBF exp %s got %s' % (texp, ev['tcbf']))
    if errs:
        print('MISMATCH (%d)' % len(errs))
        for e in errs[:20]:
            print('  ' + e)
        return False
    print('CHAIN OK')
    return True


def main(simdir):
    frames, rx, tx, anchors, fend_of = solve_and_build()
    # ---- 余量断言 ----
    grant_k = [k for k, _, _, _ in tx['rxw']]
    for name, t in tx['starts']:
        for g in grant_k:
            assert abs(g - t) > 3, (name, t, g)
        for k, _, _, _ in rx['acks']:
            assert abs(k - t) > 2, (name, t, k)
    for a, b in zip(rx['fends'], rx['fends'][1:]):
        assert b[0] - a[0] >= 10, (a, b)
    assert len(tx['colls']) >= 2, tx['colls']
    gen_memh(simdir, frames, tx, anchors)
    print('anchors %s' % anchors)
    print('fends %s' % fend_of)
    print('syns %s sacks %s' % (rx['syns'], rx['sacks']))
    print('sdone %s colls %s' % (tx['sdone'], tx['colls']))
    print('expected TX frames:')
    for fr in tx['frames']:
        print('  id=%d %s c%d seq=%d ack=%d plen=%s' %
              (fr['idx'], fr['kind'], fr['cid'], fr['seq'], fr['ack'], fr['plen']))
    rs = rx['stats']
    print('STATS7 exp %s' % [rs['pss'], rs['nonmatch'], rs['ipcsum'], rs['crc'],
                             rs['seq'], rs['ack'], rs['bytes']])
    print('STATS_TX exp %s' % tx['stats'])
    print('TCBF exp %s' % [[tx['tcb'][e][f] for f in FIELDS] for e in (0, 1)])


if __name__ == '__main__':
    import sys
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p3sim')
    if len(sys.argv) > 2 and sys.argv[2] == 'check':
        sys.exit(0 if check(simdir) else 1)
    main(simdir)
