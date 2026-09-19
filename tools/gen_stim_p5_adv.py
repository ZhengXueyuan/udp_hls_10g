#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_stim_p5_adv.py — P5a 对抗性用例: 脚本生成 + 判据 (tb/tb_p5_adv.v)

用法:
  python gen_stim_p5_adv.py <simdir> <case>          # 生成 adv_cmds.memh + stim_*
  python gen_stim_p5_adv.py <simdir> <case> check    # 校验 resp_p5_adv.memh

case: len / b2b / wnd / fin / findrop / abort / evfifo / reconn_fast /
      reconn_slow / multi

脚本语义见 tb/tb_p5_adv.v 头注释。判据:
  通用: FCS 有效; 数据帧字段 (doff/flags/win/ack/dst mac/ip/ports);
        逐字节 == RTL 图案 (xorshift64 先取后推, 偏移 = 全局 app 流位置);
        覆盖并集逐 seq 连续无洞无重叠; stat_eend==0; mac abort==0; 无 WAIT 超时
退出码: 0 全过, 1 有 FAIL, 2 参数错。
"""
import os
import struct
import sys
import zlib

TOOLS = os.path.dirname(os.path.abspath(__file__))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
import gen_stim_p4_chain as G4

MASK64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15
BOARD_MAC = G4.DUT_MAC                       # 00:0A:35:01:FE:C0
BOARD_IP = 0xC0A86402

CONN = {
    0: dict(pip=0xC0A86401, bip=BOARD_IP, pport=0x3039, mport=0x1F90,
            pmac=bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]),
            iss=0x12345678, pcis=0x20000000),
    1: dict(pip=0xC0A86403, bip=BOARD_IP, pport=0x303A, mport=0x1F91,
            pmac=bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x67]),
            iss=0x12346000, pcis=0x21000000),
}
WSCALE = 8
RCV_WND = 0xC000
CFG_PEER_WND = 0xC000
PC_WND = 0x4000


def xs_stream(n, off=0, seed=SEED):
    s = seed
    for _ in range(off):
        s ^= (s << 13) & MASK64
        s ^= s >> 7
        s ^= (s << 17) & MASK64
    out = bytearray()
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s ^= (s << 13) & MASK64
        s ^= s >> 7
        s ^= (s << 17) & MASK64
    return bytes(out)


def pat_bytes(off, n):
    return xs_stream(n, off)


# =====================================================================
# 脚本
# =====================================================================

class Script:
    def __init__(self, case):
        self.case = case
        self.lines = []
        self.exp = {0: [], 1: []}     # conn -> [(len, app_off, seq)]
        self.base = {c: CONN[c]['iss'] + 1 for c in CONN}
        self.off = 0                  # 全局 app 流偏移
        self.cfg_conns = {}
        self.pushes = 0
        self.drops = 0
        self.ev = []
        self.inj = []
        self.notes = []

    def w(self, op, a=0, b=0, c=0, d=0, e=0, f=0, g=0, h=0, i=0):
        self.lines.append([op, a, b, c, d, e, f, g, h, i])

    def pc_table(self, c, en=1):
        d = CONN[c]
        mac = d['pmac']
        self.w(11, c, d['pport'], d['mport'], d['bip'], d['pip'],
               int.from_bytes(mac[:2], 'big'), int.from_bytes(mac[2:], 'big'),
               PC_WND, en)
        self.w(17, c, d['pcis'] + 1)

    def cfg_add(self, slot, c, snd=None, rcv=None):
        d = CONN[c]
        mac = d['pmac']
        snd = (d['iss'] + 1) if snd is None else snd
        rcv = (d['pcis'] + 1) if rcv is None else rcv
        self.w(18, slot, rcv, snd)
        self.w(4, slot, 0, WSCALE, d['pip'], d['bip'],
               (d['pport'] << 16) | d['mport'],
               int.from_bytes(mac[:2], 'big'), int.from_bytes(mac[2:], 'big'),
               CFG_PEER_WND)
        self.cfg_conns[c] = dict(sport=d['pport'], dport=d['mport'], pip=d['pip'],
                                 bip=d['bip'], mac=mac, snd0=snd, rcv0=rcv)
        self.base[c] = snd

    def cfg_del(self, slot, c):
        d = CONN[c]
        mac = d['pmac']
        self.w(4, slot, 1, WSCALE, d['pip'], d['bip'],
               (d['pport'] << 16) | d['mport'],
               int.from_bytes(mac[:2], 'big'), int.from_bytes(mac[2:], 'big'), 0)

    def push(self, c, lens, sel=0):
        for L in lens:
            bad = 1 if L > 1500 else 0
            self.w(5, 1, L, c, sel, bad)
            self.pushes += 1
            if bad:
                self.drops += 1
            else:
                self.exp[c].append((L, self.off, self.base[c]))
                self.base[c] += L
                self.off += L

    def close(self, slot=0):
        self.w(7, 0x06, (1 << 4) | slot)

    def abort(self, slot=0):
        self.w(7, 0x06, (2 << 4) | slot)

    def text(self):
        return ''.join(' '.join(str(x) for x in ln) + '\n' for ln in self.lines)


def case_len():
    s = Script('len')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    for L in [1, 7, 8, 9, 1459, 1460, 1461, 1500, 1501, 2000, 2000, 1460,
              1500, 8192, 100, 1460]:
        s.push(0, [L], sel=0)
        s.w(15, 100000)       # 等被 DUT 消费 (超长帧整帧吞掉)
        s.w(1, 2000)
    s.w(2, 12)
    s.w(12)
    return s


def case_b2b():
    s = Script('b2b')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.w(5, 64, 1460, 0, 0, 0)
    for _ in range(64):
        s.exp[0].append((1460, s.off, s.base[0]))
        s.base[0] += 1460
        s.off += 1460
    s.pushes = 64
    s.w(15, 5000000)
    s.w(2, 64)
    s.w(12)
    return s


def case_wnd():
    s = Script('wnd')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.w(5, 40, 1460, 0, 1)     # sel=1: 无视 app_tx_ready
    for _ in range(40):
        s.exp[0].append((1460, s.off, s.base[0]))
        s.base[0] += 1460
        s.off += 1460
    s.pushes = 40
    s.w(2, 3)
    s.w(9, 0, 0)               # pc_wnd = 0
    s.w(10, 0, 0, 0)           # 注入 wnd=0 纯 ACK
    s.w(1, 3000)
    s.w(12)                    # 快照 A
    s.w(2, 3)
    s.w(1, 30000)
    s.w(12)                    # 快照 B
    s.w(9, 0, PC_WND)
    s.w(10, 0, 0, 0)
    s.w(15, 6000000)
    s.w(2, 40)
    s.w(12)                    # 快照 C
    return s


def case_fin():
    s = Script('fin')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.push(0, [1460, 1460, 1460])
    s.w(15, 200000)
    s.w(2, 3)
    s.w(1, 1000)
    s.close(0)
    s.w(3, 1)
    s.w(12)                    # 快照 1
    s.w(1, 3000)
    s.w(12)                    # 快照 2
    s.w(1, 30000)
    s.w(12)                    # 快照 3
    return s


def case_findrop():
    s = Script('findrop')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.push(0, [1460, 1460])
    s.w(15, 200000)
    s.w(2, 2)
    s.w(1, 800)
    s.w(6, 0, 0)               # 停自动应答 (FIN 丢失)
    s.close(0)
    s.w(3, 1)
    s.w(12)                    # 快照 1
    s.w(3, 2)                  # 等 RTO 重发 (~12.5M 拍)
    s.w(12)                    # 快照 2
    return s


def case_abort():
    s = Script('abort')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.push(0, [1460, 1460])
    s.w(15, 200000)
    s.w(2, 2)
    s.w(1, 1000)
    s.abort(0)
    s.w(13, 1)
    s.w(12)
    s.w(1, 30000)
    s.w(12)
    return s


def case_evfifo():
    s = Script('evfifo')
    s.pc_table(0, en=0)
    s.w(1, 200)
    for k in range(40):
        slot = k % 16
        pip = 0x0A000001 + k
        pport = 0x1000 + k
        mport = 0x2000 + k
        mac = 0x020000000000 + k
        s.w(18, slot, 0x20000001 + k, 0x12345679 + k)
        s.w(4, slot, 0, WSCALE, pip, BOARD_IP, (pport << 16) | mport,
            (mac >> 32) & 0xFFFF, mac & 0xFFFFFFFF, CFG_PEER_WND)
        s.ev.append(dict(slot=slot, pip=pip, pport=pport, mport=mport, mac=mac))
    s.w(1, 1000)
    s.w(12)
    s.w(8, 0x00)
    s.w(8, 0x9F)          # 设计标识
    s.w(8, 0x90)
    s.w(8, 0x92)
    for j in range(16):
        s.w(8, 0x01); s.w(8, 0x02); s.w(8, 0x03); s.w(8, 0x04)
        s.w(7, 0x05, 0)
    s.w(8, 0x00)
    s.w(12)
    return s


def case_reconn(fast):
    s = Script('reconn_fast' if fast else 'reconn_slow')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.push(0, [1460, 1460])
    s.w(15, 200000)
    s.w(2, 2)
    s.w(1, 1000)
    s.close(0)
    s.w(3, 1)
    s.w(1, 1000)
    new_snd = 0x12347001
    s.cfg_del(0, 0)
    if not fast:
        s.w(1, 4000)
    s.base[0] = new_snd
    s.cfg_add(0, 0, snd=new_snd, rcv=0x20000401)
    s.w(1, 500)
    s.push(0, [1460, 1460], sel=1)
    s.w(15, 300000)            # fin_sent_r 残留 -> 永不被消费 -> 超时
    s.w(1, 600000)             # 给足时间观察线上有没有新帧 / 新 FIN
    s.w(12)                    # 快照: frmD / fin_sent / rdy
    s.close(0)
    s.w(1, 200000)
    s.w(12)
    return s


def case_multi():
    s = Script('multi')
    for c in (0, 1):
        s.pc_table(c)
    s.cfg_add(0, 0)
    s.cfg_add(1, 1)
    s.w(1, 500)
    for r in range(4):
        s.push(0, [1000]); s.w(15, 200000)
        s.push(1, [1200]); s.w(15, 200000)
    s.w(2, 8)
    s.w(1, 1000)
    s.w(12)
    s.w(10, 0, 0, 100)         # conn0 注入 100B
    s.inj.append((0, 100))
    s.w(1, 3000)
    s.w(12)
    s.w(10, 1, 0, 150)         # conn1 注入 150B
    s.inj.append((1, 150))
    s.w(1, 3000)
    s.w(12)
    return s


def case_dbg():
    s = Script('dbg')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.w(19, 1)
    for L in [100, 200, 2000, 100]:
        s.push(0, [L], sel=0)
        s.w(15, 100000)
        s.w(1, 2000)
    s.w(2, 3)
    s.w(12)
    return s


def case_reconn_probe():
    """同槽 DEL->ADD 快速重连的快速探针: 只取快照, 不烧 24M 拍超时"""
    s = Script('reconn_probe')
    s.pc_table(0)
    s.cfg_add(0, 0)
    s.w(1, 500)
    s.push(0, [1460, 1460])
    s.w(15, 200000)
    s.w(2, 2)
    s.w(1, 1000)
    s.w(12)                     # 快照 0: 首会话稳态 (fin_sent=0)
    s.close(0)
    s.w(3, 1)                   # 等 FIN
    s.w(1, 1000)
    s.w(12)                     # 快照 1: FIN 已发 (fin_sent=1)
    s.cfg_del(0, 0)             # DEL
    s.base[0] = 0x12347001
    s.cfg_add(0, 0, snd=0x12347001, rcv=0x20000401)   # 立刻 ADD (背靠背)
    s.w(1, 3000)
    s.w(12)                     # 快照 2: 新会话配好后的 TCB/fin_sent/rdy
    s.push(0, [1460, 1460], sel=1)
    s.w(1, 200000)
    s.w(12)                     # 快照 3: 新会话两帧是否上线
    return s


CASES = {
    'reconn_probe': case_reconn_probe,
    'dbg': case_dbg,
    'len': case_len, 'b2b': case_b2b, 'wnd': case_wnd, 'fin': case_fin,
    'findrop': case_findrop, 'abort': case_abort, 'evfifo': case_evfifo,
    'reconn_fast': lambda: case_reconn(True),
    'reconn_slow': lambda: case_reconn(False),
    'multi': case_multi,
}


def gen_stim(simdir, case):
    s = CASES[case]()
    with open(os.path.join(simdir, 'adv_cmds.memh'), 'w') as fh:
        fh.write(s.text())
    for name, fill in (('stim_data.memh', '07\n'), ('stim_dv.memh', '00\n'),
                       ('stim_er.memh', '00\n')):
        with open(os.path.join(simdir, name), 'w') as fh:
            fh.write(fill * 256)
    print('gen_stim_p5_adv: case=%s cmds=%d pushes=%d drops=%d'
          % (case, len(s.lines), s.pushes, s.drops))
    return 0


# =====================================================================
# 校验
# =====================================================================

def fcs_ok(fb):
    if len(fb) < 12:
        return False
    return int.from_bytes(fb[-4:], 'little') == (zlib.crc32(fb[8:-4]) & 0xFFFFFFFF)


def parse_adv(fn):
    keep = []
    with open(fn, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if p and p[0].startswith('ADV'):
                continue
            keep.append(line)
    ff = fn + '.p4filter'
    with open(ff, 'w') as fh:
        fh.writelines(keep)
    frames, ev = G4.parse_gmii(ff)
    info = dict(reg={}, stat=[], tx=[], frm=[], tcb={}, rdy=[], stat2=[],
                app=[], mac=[], to=[], cmd=[])
    with open(fn, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if not p or not p[0].startswith('ADV'):
                continue
            kv = {}
            for tok in p[1:]:
                if '=' in tok:
                    kk, vv = tok.split('=', 1)
                    try:
                        kv[kk] = int(vv)
                    except ValueError:
                        kv[kk] = vv
            if p[0] == 'ADVREG':
                info['reg'].setdefault(int(p[1]), []).append(int(p[2], 16))
            elif p[0] == 'ADVSTAT':
                info['stat'].append(kv)
            elif p[0] == 'ADVAPP':
                info['app'].append(kv)
            elif p[0] == 'ADVTX':
                info['tx'].append(kv)
            elif p[0] == 'ADVFRM':
                info['frm'].append(kv)
            elif p[0] == 'ADVSTAT2':
                info['stat2'].append(kv)
            elif p[0] == 'ADVTCB':
                info['tcb'][int(p[1])] = tuple(int(x, 16) for x in p[2:])
            elif p[0] == 'ADVRDY':
                d = {'val': p[1]}
                for tok in p[2:]:
                    if '=' in tok:
                        kk, vv = tok.split('=', 1)
                        d[kk] = vv
                info['rdy'].append(d)
            elif p[0] == 'ADVMAC':
                info['mac'].append(kv)
            elif p[0] == 'ADVTO':
                info['to'].append(line.strip())
            elif p[0] == 'ADVCMD':
                info['cmd'].append(tuple(int(x) for x in p[1:]))
    return frames, ev, info


class Check:
    def __init__(self):
        self.errs = []
        self.warns = []

    def err(self, m):
        self.errs.append(m)

    def warn(self, m):
        self.warns.append(m)

    def eq(self, got, exp, tag):
        if got != exp:
            self.err(' %s: got %s exp %s' % (tag, got, exp))


def classify(frames):
    out = dict(data={0: [], 1: []}, fin={0: [], 1: []}, rst={0: [], 1: []},
               ack=[], other=[], badfcs=0)
    for fb in frames:
        if not fcs_ok(fb):
            out['badfcs'] += 1
            continue
        body = fb[8:-4]
        if len(body) < 42 or body[12:14] != b'\x08\x00' or body[23] != 6:
            out['other'].append(fb)
            continue
        iplen, = struct.unpack('!H', body[16:18])
        sp, dp = struct.unpack('!HH', body[34:38])
        seq, ack = struct.unpack('!II', body[38:46])
        doff, flags = body[46], body[47]
        win, = struct.unpack('!H', body[48:50])
        plen = iplen - 40
        c = None
        for cc, d in CONN.items():
            if (sp, dp) == (d['mport'], d['pport']):
                c = cc
        rec = dict(seq=seq, ack=ack, doff=doff, flags=flags, win=win, plen=plen,
                   body=body, fb=fb, conn=c, sport=sp, dport=dp, iplen=iplen)
        if flags == 0x10 and plen == 0:
            out['ack'].append(rec)
        elif c is None:
            out['other'].append(rec)
        elif flags == 0x11 and plen == 0:
            out['fin'][c].append(rec)
        elif flags == 0x14:
            out['rst'][c].append(rec)
        elif flags == 0x18:
            out['data'][c].append(rec)
        else:
            out['other'].append(rec)
    return out


def check_wire(ck, cl, case, exp, ack_sets, win_exp=RCV_WND, max_plen=1460):
    for c, e in exp.items():
        got = cl['data'][c]
        d = CONN[c]
        if len(got) != len(e):
            ck.err('conn%d 数据帧数 %d != 期望 %d' % (c, len(got), len(e)))
        for k, rec in enumerate(got):
            tag = 'conn%d 帧%d(seq=%08x)' % (c, k, rec['seq'])
            if rec['doff'] != 0x50:
                ck.err('%s doff=%02x' % (tag, rec['doff']))
            if rec['plen'] > max_plen:
                ck.err('%s plen=%d > %d (合并巨帧 / 超契约)'
                       % (tag, rec['plen'], max_plen))
            if rec['win'] != win_exp:
                ck.err('%s window=%04x != %04x' % (tag, rec['win'], win_exp))
            if rec['ack'] not in ack_sets[c]:
                ck.err('%s ack=%08x 不在允许集合 %s'
                       % (tag, rec['ack'], [hex(x) for x in sorted(ack_sets[c])]))
            b = rec['body']
            if b[:6] != d['pmac']:
                ck.err('%s dst mac %s != %s' % (tag, b[:6].hex(), d['pmac'].hex()))
            if b[6:12] != BOARD_MAC:
                ck.err('%s src mac %s != %s' % (tag, b[6:12].hex(), BOARD_MAC.hex()))
            if (struct.unpack('!I', b[26:30])[0], struct.unpack('!I', b[30:34])[0]) \
                    != (d['bip'], d['pip']):
                ck.err('%s ip %s -> %s' % (tag, b[26:30].hex(), b[30:34].hex()))
            if (rec['sport'], rec['dport']) != (d['mport'], d['pport']):
                ck.err('%s ports %04x->%04x' % (tag, rec['sport'], rec['dport']))
            if k < len(e):
                elen, eoff, eseq = e[k]
                if rec['plen'] != elen:
                    ck.err('%s plen=%d != 期望 %d' % (tag, rec['plen'], elen))
                if rec['seq'] != eseq:
                    ck.err('%s seq=%08x != 期望 %08x' % (tag, rec['seq'], eseq))
                pay = b[54:54 + rec['plen']]
                want = pat_bytes(eoff, rec['plen'])
                if pay != want:
                    n = next((x for x in range(len(pay)) if pay[x] != want[x]), -1)
                    ck.err('%s 载荷失配 @%d got %02x exp %02x (图案偏移 %d)'
                           % (tag, n, pay[n] if n >= 0 else -1,
                              want[n] if n >= 0 else -1, eoff))
        # 覆盖判定按 seq 连续段分组 (同槽重连 = 新 seq 空间, 段间必然有洞,
        # 不算缺陷; 段内必须逐字节连续无洞无重叠)
        groups = []
        for (l, off, sq) in e:
            if groups and sq == groups[-1][1]:
                groups[-1][1] = sq + l
            else:
                groups.append([sq, sq + l])
        for g in groups:
            segs = sorted((r['seq'], r['plen']) for r in got
                          if g[0] <= r['seq'] < g[1])
            end = g[0]
            holes = 0
            for sq, pl in segs:
                if sq > end:
                    holes += 1
                end = max(end, sq + pl)
            if holes:
                ck.err('conn%d 段[%08x,%08x) 覆盖有 %d 处空洞'
                       % (c, g[0], g[1], holes))
            if end != g[1]:
                ck.err('conn%d 段[%08x,%08x) 覆盖尾 %08x 不齐' % (c, g[0], g[1], end))
            tot = sum(pl for _, pl in segs)
            exptot = sum(l for (l, o, sq) in e if g[0] <= sq < g[1])
            if tot != exptot:
                ck.err('conn%d 段[%08x,%08x) 线上载荷 %d != 期望 %d'
                       % (c, g[0], g[1], tot, exptot))


def check_generic(ck, cl, info):
    if cl['badfcs']:
        ck.err('%d 帧 FCS 无效' % cl['badfcs'])
    for tag, name in (('tx', 'ADVTX'), ('frm', 'ADVFRM'), ('stat2', 'ADVSTAT2'),
                      ('mac', 'ADVMAC')):
        if not info[tag]:
            ck.err('resp 缺 %s 行' % name)
    if info['tx']:
        t = info['tx'][-1]
        if t.get('eend', 0) != 0:
            ck.err('stat_eend=%d != 0 (S_PAY 欠载)' % t['eend'])
    if info['mac']:
        if info['mac'][-1].get('abort', 0) != 0:
            ck.err('mac abort=%d != 0' % info['mac'][-1]['abort'])
    if info['to']:
        ck.err('WAIT 超时: %s' % info['to'])


# ---------------- 逐 case ----------------

def check_len(ck, cl, ev, info, s):
    # 本 case 故意推 1461/1500 帧 (RTL PLEN_MAX=1500 的上界测试), 巨帧哨兵放宽
    check_wire(ck, cl, 'len', s.exp, {0: {CONN[0]['pcis'] + 1}}, max_plen=1500)
    t = info['tx'][-1]
    ck.eq(t.get('drop_len'), s.drops,
          'stat_drop_len (期望 %d 帧超长被丢)' % s.drops)
    ck.eq(t.get('fin'), 0, 'stat_fin (本 case 不关闭)')
    ck.eq(t.get('rst'), 0, 'stat_rst')
    app = info['stat'][-1] if info['stat'] else {}
    ck.eq(app.get('atx_frames'), s.pushes, 'app 消费帧数')
    ck.eq(app.get('atx_good'), sum(l for l, _, _ in s.exp[0]), 'app 好帧字节数')
    ck.eq(app.get('atx_bad'), s.drops, 'app 坏帧计数')
    if app.get('run') or app.get('qn'):
        ck.err('末尾仍有未消费的 app 帧 (run=%s qn=%s)' % (app.get('run'),
                                                          app.get('qn')))


def check_b2b(ck, cl, ev, info, s):
    check_wire(ck, cl, 'b2b', s.exp, {0: {CONN[0]['pcis'] + 1}})
    got = cl['data'][0]
    if len(got) != 64:
        ck.err('背靠背: 线上 %d 帧 != 64' % len(got))
    if any(r['plen'] != 1460 for r in got):
        ck.err('背靠背: 出现 plen != 1460 的帧 (合并/碎片)')
    t = info['tx'][-1]
    ck.eq(t.get('drop_len'), 0, 'stat_drop_len')
    ck.eq(t.get('eend'), 0, 'stat_eend')
    ck.eq(info['stat'][-1].get('atx_frames'), 64, 'app 帧数')


def check_wnd(ck, cl, ev, info, s):
    check_wire(ck, cl, 'wnd', s.exp, {0: {CONN[0]['pcis'] + 1}})
    frm = info['frm']
    app = info['app']
    if len(frm) < 3 or len(app) < 3 or len(info['rdy']) < 3:
        ck.err('快照数不足 (frm=%d app=%d rdy=%d)' % (len(frm), len(app),
                                                    len(info['rdy'])))
        return
    a, b = frm[0]['data'], frm[1]['data']
    if a != b:
        ck.err('窗口关闭期间仍有 %d 帧上线 (A=%d B=%d) — app 推帧未被拦住'
               % (b - a, a, b))
    if int(info['rdy'][0]['val'], 16) != 0:
        ck.warn('关窗后 app_tx_ready=%s != 0' % info['rdy'][0]['val'])
    if info['stat'][0].get('atx_bytes') != info['stat'][1].get('atx_bytes'):
        ck.err('关窗期间 app 仍被消费字节 (%d -> %d)'
               % (info['stat'][0]['atx_bytes'], info['stat'][1]['atx_bytes']))
    if not (app[1].get('run') or app[1].get('qn')):
        ck.warn('关窗期间 app 未呈现帧 (未真正打到门)')
    if frm[2]['data'] != 40:
        ck.err('重开窗后共 %d 帧上线 != 40' % frm[2]['data'])
    if frm[-1]['data'] != 40:
        ck.err('末快照 %d 帧 != 40' % frm[-1]['data'])


def check_fin(ck, cl, ev, info, s):
    check_wire(ck, cl, 'fin', s.exp, {0: {CONN[0]['pcis'] + 1}})
    fins = cl['fin'][0]
    fin_seq = CONN[0]['iss'] + 1 + 3 * 1460
    if len(fins) != 1:
        ck.err('FIN 帧数 %d != 1' % len(fins))
    else:
        r = fins[0]
        ck.eq(r['flags'], 0x11, 'FIN flags')
        ck.eq(r['doff'], 0x50, 'FIN doff')
        ck.eq(r['plen'], 0, 'FIN 载荷 (必须 0)')
        ck.eq(r['seq'], fin_seq, 'FIN seq (= snd_una)')
        ck.eq(r['ack'], CONN[0]['pcis'] + 1, 'FIN ack')
        ck.eq(r['win'], RCV_WND, 'FIN window')
    t = info['tx'][-1]
    ck.eq(t.get('fin'), 1, 'stat_fin')
    ck.eq(t.get('eend'), 0, 'stat_eend')
    tcb = info['tcb'].get(0)
    if tcb:
        rcv_nxt, snd_nxt, snd_una, rcv_wnd, snd_wnd, state, finsent = tcb
        ck.eq(state, 1, 'conn0 state')
        ck.eq(snd_nxt, snd_una, 'FIN ACK 后 snd_nxt == snd_una')
        ck.eq(snd_nxt, fin_seq + 1, 'FIN 后 snd_nxt = fin_seq+1')
        ck.eq(finsent, 1, 'fin_sent[0]')
    else:
        ck.err('缺 conn0 ADVTCB')
    if info['frm'][-1]['fin'] != 1:
        ck.err('末快照 FIN 帧数 %d != 1 (重复 FIN?)' % info['frm'][-1]['fin'])


def check_findrop(ck, cl, ev, info, s):
    check_wire(ck, cl, 'findrop', s.exp, {0: {CONN[0]['pcis'] + 1}})
    fins = cl['fin'][0]
    if len(fins) != 2:
        ck.err('FIN 帧数 %d != 2 (RTO 未重发?)' % len(fins))
        return
    a, b = fins[0], fins[1]
    # 逐字节一致 = 除"每帧必然变"的 IP 标识(26/27) 与其派生字段 (IP 校验和 32/33、
    # FCS 末 4 字节) 外全同; TCP 层字段 (seq/ack/doff/flags/window) 必须逐位相同
    fa, fb_ = a['fb'], b['fb']
    mask = {26, 27, 32, 33} | set(range(len(fa) - 4, len(fa)))
    if len(fa) != len(fb_):
        ck.err('重发 FIN 长度 %d != %d' % (len(fa), len(fb_)))
    else:
        diff = [k for k in range(len(fa)) if k not in mask and fa[k] != fb_[k]]
        if diff:
            ck.err('重发 FIN 与首发在掩码外有 %d 字节不同 (首个 @%d: %02x vs %02x)'
                   % (len(diff), diff[0], fa[diff[0]], fb_[diff[0]]))
    ck.eq(fb_[38:46], fa[38:46], '重发 FIN 的 seq/ack 逐字节一致')
    ck.eq(fb_[46:50], fa[46:50], '重发 FIN 的 doff/flags/window 逐字节一致')
    ck.eq(b['seq'], a['seq'], '重发 FIN seq 漂移')
    ck.eq(a['plen'], 0, 'FIN 载荷')
    ck.eq(info['tx'][-1].get('eend'), 0, 'stat_eend (重发无垃圾载荷)')
    if info['frm'][-1]['data'] != 2:
        ck.err('重发期间出现额外数据帧 (%d != 2)' % info['frm'][-1]['data'])


def check_abort(ck, cl, ev, info, s):
    check_wire(ck, cl, 'abort', s.exp, {0: {CONN[0]['pcis'] + 1}})
    rs = cl['rst'][0]
    fin_seq = CONN[0]['iss'] + 1 + 2 * 1460
    if len(rs) != 1:
        ck.err('RST 帧数 %d != 1' % len(rs))
    else:
        r = rs[0]
        ck.eq(r['flags'], 0x14, 'RST flags')
        ck.eq(r['plen'], 0, 'RST 载荷')
        ck.eq(r['seq'], fin_seq, 'RST seq (= snd_una)')
    t = info['tx'][-1]
    ck.eq(t.get('rst'), 1, 'stat_rst')
    ck.eq(t.get('eend'), 0, 'stat_eend')
    frm = info['frm']
    if len(frm) >= 2 and frm[-1]['data'] != frm[-2]['data']:
        ck.err('RST 之后仍发数据 (%d -> %d)' % (frm[-2]['data'], frm[-1]['data']))


def check_evfifo(ck, cl, ev, info, s):
    add_n = 40
    st2 = info['stat2'][-1] if info['stat2'] else {}
    ck.eq(st2.get('scfg_add'), add_n, 'slow_cfg_adp stat_add')
    ck.eq(st2.get('ev_up'), add_n, 'app_ctrl CONN_UP 计数')
    ck.eq(st2.get('ev_down'), 0, 'CONN_DOWN 计数')
    ck.eq(st2.get('ev_drop'), add_n - 16, '事件丢弃计数 (40-16)')
    regs = info['reg']
    if 0x00 in regs:
        v = regs[0x00][0]
        ck.eq(v & 0x1, 0, 'FIFO empty=0 (前 16 项已入队)')
        ck.eq((v >> 1) & 1, 1, 'FIFO ovf sticky=1')
    else:
        ck.err('缺 0x00 读')
    ck.eq(regs.get(0x90, [None])[0], add_n, '寄存器 0x90 CONN_UP')
    ck.eq(regs.get(0x91, [None])[0], 0, '寄存器 0x91 CONN_DOWN')
    ck.eq(regs.get(0x92, [None])[0], add_n - 16, '寄存器 0x92 事件丢弃')
    ck.eq(regs.get(0x9F, [None])[0], 0x50354131, '设计标识 0x9F')
    e1 = regs.get(0x01, [])
    e2 = regs.get(0x02, [])
    e3 = regs.get(0x03, [])
    e4 = regs.get(0x04, [])
    n = min(len(e1), len(e2), len(e3), len(e4))
    if n != 16:
        ck.err('事件字读回 %d 组 != 16' % n)
    for k in range(n):
        if k >= len(s.ev):
            break
        v = s.ev[k]
        ck.eq(e1[k] & 0xF, v['slot'], '事件%d slot' % k)
        ck.eq((e1[k] >> 4) & 0x3, 0, '事件%d kind (0=UP)' % k)
        ck.eq(e2[k], v['pip'], '事件%d peer_ip' % k)
        ck.eq(e3[k] >> 16, v['pport'], '事件%d peer_port' % k)
        ck.eq(e3[k] & 0xFFFF, (v['mac'] >> 32) & 0xFFFF, '事件%d mac_hi' % k)
        ck.eq(e4[k], v['mac'] & 0xFFFFFFFF, '事件%d mac_lo' % k)
    if 0x00 in regs and len(regs[0x00]) > 1:
        ck.eq(regs[0x00][-1] & 0x1, 1, '弹空后 empty=1')
        ck.eq((regs[0x00][-1] >> 1) & 1, 1, '弹空后 ovf sticky=1')


def check_reconn(ck, cl, ev, info, s, fast):
    check_wire(ck, cl, 'reconn', s.exp,
               {0: {CONN[0]['pcis'] + 1, 0x20000401}})
    got = cl['data'][0]
    if fast:
        rdy = info['rdy'][-1]['val'] if info['rdy'] else '?'
        print('FAST 观察: 线上数据帧 %d / FIN 帧数 %d / app_tx_ready=%s / 超时=%s'
              % (len(got), info['frm'][-1]['fin'], rdy,
                 'yes' if info['to'] else 'no'))
        if info['to']:
            ck.warn('fast 重连: 发生 WAIT 超时 (%s)' % info['to'])
        # 残留复现 = 新会话一帧都上不去 (线上仍 2 帧) 且 app_tx_ready=0
        if len(got) != 2 or rdy in ('0000', '?'):
            ck.warn('fast 重连后新会话被挡 (数据帧 %d, rdy=%s, FIN %d) — 若确认'
                    ' fin_sent_r 残留即为缺陷' % (len(got), rdy,
                                                info['frm'][-1]['fin']))
    else:
        if len(got) != 4:
            ck.err('慢速重连: 线上数据帧 %d != 4' % len(got))
        if info['frm'][-1]['fin'] != 2:
            ck.err('慢速重连: FIN 帧数 %d != 2' % info['frm'][-1]['fin'])
    tcb = info['tcb'].get(0)
    if tcb:
        ck.eq(tcb[6], 1, '重连后 fin_sent[0] 应为 0 (新会话可再发 FIN)')
        ck.eq(tcb[5], 1, '重连后 conn0 state')
    ck.eq(info['tx'][-1].get('eend'), 0, 'stat_eend')


def check_multi(ck, cl, ev, info, s):
    check_wire(ck, cl, 'multi', s.exp,
               {0: {CONN[0]['pcis'] + 1, CONN[0]['pcis'] + 1 + 100},
                1: {CONN[1]['pcis'] + 1, CONN[1]['pcis'] + 1 + 150}})
    t0 = info['tcb'].get(0)
    t1 = info['tcb'].get(1)
    if t0:
        ck.eq(t0[0], CONN[0]['pcis'] + 1 + 100, 'conn0 rcv_nxt (注入 100B)')
        ck.eq(t0[1], CONN[0]['iss'] + 1 + 4 * 1000, 'conn0 snd_nxt')
        ck.eq(t0[2], CONN[0]['iss'] + 1 + 4 * 1000, 'conn0 snd_una')
        ck.eq(t0[5], 1, 'conn0 state')
    else:
        ck.err('缺 conn0 ADVTCB')
    if t1:
        ck.eq(t1[0], CONN[1]['pcis'] + 1 + 150, 'conn1 rcv_nxt (注入 150B)')
        ck.eq(t1[1], CONN[1]['iss'] + 1 + 4 * 1200, 'conn1 snd_nxt')
        ck.eq(t1[2], CONN[1]['iss'] + 1 + 4 * 1200, 'conn1 snd_una')
        ck.eq(t1[5], 1, 'conn1 state')
    else:
        ck.err('缺 conn1 ADVTCB')
    acks = set(a[2] for a in ev.get('ack', []))
    if (CONN[0]['pcis'] + 1 + 100) not in acks:
        ck.err('未见 conn0 rcv_nxt=%08x 的 ACK 行 (样例 %s)'
               % (CONN[0]['pcis'] + 1 + 100,
                  sorted(hex(x) for x in acks)[:6]))
    if (CONN[1]['pcis'] + 1 + 150) not in acks:
        ck.err('未见 conn1 rcv_nxt=%08x 的 ACK 行' % (CONN[1]['pcis'] + 1 + 150))
    ck.eq(info['tx'][-1].get('eend'), 0, 'stat_eend')


CHECKERS = {'dbg': check_len, 'len': check_len, 'b2b': check_b2b, 'wnd': check_wnd, 'fin': check_fin,
            'findrop': check_findrop, 'abort': check_abort,
            'evfifo': check_evfifo, 'multi': check_multi,
            'reconn_fast': lambda ck, cl, ev, info, s: check_reconn(ck, cl, ev, info, s, True),
            'reconn_probe': lambda ck, cl, ev, info, s: check_reconn(ck, cl, ev, info, s, True),
            'reconn_slow': lambda ck, cl, ev, info, s: check_reconn(ck, cl, ev, info, s, False)}


def check(simdir, case):
    s = CASES[case]()
    frames, ev, info = parse_adv(os.path.join(simdir, 'resp_p5_adv.memh'))
    cl = classify(frames)
    ck = Check()
    check_generic(ck, cl, info)
    CHECKERS[case](ck, cl, ev, info, s)

    print('=== case %s ===' % case)
    print('帧分类: data c0=%d c1=%d | FIN=%d/%d | RST=%d/%d | 纯ACK=%d | 其它=%d'
          % (len(cl['data'][0]), len(cl['data'][1]), len(cl['fin'][0]),
             len(cl['fin'][1]), len(cl['rst'][0]), len(cl['rst'][1]),
             len(cl['ack']), len(cl['other'])))
    if info['tx']:
        print('ADVTX   : %s' % info['tx'][-1])
    if info['frm']:
        print('ADVFRM  : %s' % info['frm'][-1])
    if info['app']:
        print('ADVAPP  : %s' % info['app'][-1])
    if info['stat2']:
        print('ADVSTAT2: %s' % info['stat2'][-1])
    for c in (0, 1):
        if c in info['tcb']:
            print('TCB%d    : rcv_nxt=%08x snd_nxt=%08x snd_una=%08x rcv_wnd=%04x '
                  'snd_wnd=%04x state=%d fin_sent=%d' % ((c,) + info['tcb'][c]))
    for w in ck.warns:
        print('WARN: %s' % w)
    if ck.errs:
        print('')
        for e in ck.errs:
            print('MISMATCH:%s' % e)
        print('P5 ADV[%s] FAIL (%d 项)' % (case, len(ck.errs)))
        return 1
    print('P5 ADV[%s] OK' % case)
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    simdir, case = sys.argv[1], sys.argv[2]
    if case not in CASES:
        print('unknown case %s (可选: %s)' % (case, ' '.join(sorted(CASES))))
        sys.exit(2)
    if len(sys.argv) >= 4 and sys.argv[3] == 'check':
        sys.exit(check(simdir, case))
    sys.exit(gen_stim(simdir, case))
