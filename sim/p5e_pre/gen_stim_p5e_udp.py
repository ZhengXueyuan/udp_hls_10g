#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P5e 前置实验: 激励生成 + 判据 (tb_p5_udp_split.v = tb_p5_app.v 的派生副本)。

用法:
  python gen_stim_p5e_udp.py <simdir>          # 生成 stim_data/dv/er.memh + 期望帧表
  python gen_stim_p5e_udp.py <simdir> check    # 校验 resp_p5_udp_split.memh

实验目的 (三个裁决):
  ① 拆分点 (rx_classify 的 m_slow_* 输出) 是否可行 —— 判据 = slow 口重建帧与注入帧
     **逐字节相同** + crs/terr 与 FCS 实测一致 (用 P5ESLW 原始字流重建)。
  ② udp_rx 能否零 shim 复用 —— 判据 = 匹配帧的 meta_* 逐位正确、载荷逐字节 +
     tkeep 连续高对齐 + tlast 恰在载荷末尾; 非匹配整帧吞掉 + 计数。
  ③ 坏 FCS 的 UDP 帧行为 (app RX 契约弱点) —— 判据 = 照常交付但 tuser[0]=0。

激励落在 stim 流前段 (256 拍空闲之后), 与 TB 自身 TCP app 流水并发 ⇒ 同时验证
"插入 udp_rx 不干扰 fast 路径" (final pat_mismatch/pat_done + canonical checker 旁证)。
"""
import io
import os
import struct
import sys
import zlib

TOOLS = r"D:\repo\ECO\udp_hls_10g\tools"
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
import gen_stim_udp_rx as G1          # eth_fcs / ip_hdr / csum16 (P1 已验证口径)

PRE = bytes([0x55] * 7) + b'\xD5'
IFG = bytes([0x07] * 12)
SRC_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
DST_MAC = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
SRC_IP = 0x0A000001                   # 10.0.0.1
MY_IP = 0xC0A86402                    # 192.168.100.2 (udp_rx cfg_dst_ip)
SPORT = 12345
UDP_PORT_MATCH = 8080
UDP_PORT_OTHER = 9999
MASK64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15


def xs_stream(n, seed=SEED):
    """xorshift64 字节流 (byte = s[31:24] 先取) —— 与 app_pattern / P1 同式。
    选它的理由: 对**字节错位**有判别力 (重排/移位立刻失配)。"""
    s = seed
    out = bytearray()
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s ^= (s << 13) & MASK64
        s ^= s >> 7
        s ^= (s << 17) & MASK64
    return bytes(out)


def mk_udp(dip, dport, n, bad_ipcsum=False, bad_fcs=False, udp_len=None):
    """udp_len: 显式覆盖 UDP 头里的长度字段 (None = 正确值 8+n)。
    ip total_len 恒按**真实**布局算 ⇒ IP 校验和自洽 (udp_rx 不查 ip total_len)。"""
    eth = DST_MAC + SRC_MAC + b'\x08\x00'
    pl = xs_stream(n)
    ip = G1.ip_hdr(SRC_IP, dip, 17, 5, 20 + 8 + n, bad_ipcsum)
    ul = (8 + n) if udp_len is None else udp_len
    fb = eth + ip + struct.pack('!HHHH', SPORT, dport, ul, 0) + pl
    fcs = G1.eth_fcs(fb)
    if bad_fcs:
        fcs = fcs[:-1] + bytes([fcs[-1] ^ 0x01])
    return fb, fcs, pl


def mk_tcp_syn(dip, dport):
    eth = DST_MAC + SRC_MAC + b'\x08\x00'
    ip = G1.ip_hdr(SRC_IP, dip, 6, 5, 40)
    th = struct.pack('!HHLLBBHHH', SPORT, dport, 0x11111111, 0, 0x50, 0x02,
                     0x4000, 0, 0)
    fb = eth + ip + th
    return fb, G1.eth_fcs(fb), b''


def mk_arp():
    eth = DST_MAC + SRC_MAC + b'\x08\x06'
    arp = (b'\x00\x01\x08\x00\x06\x04\x00\x01' +
           SRC_MAC + struct.pack('!I', SRC_IP) + b'\x00' * 6 +
           struct.pack('!I', MY_IP))
    fb = eth + arp
    return fb, G1.eth_fcs(fb), b''


# ---- 帧表 ----
#   kind: 'match'  = meta+载荷交付 (crs_ok 由 bad_fcs 决定)
#         'drop'   = 整帧吞掉, 只计数 (stat_drop_nonmatch)
#         'ipcsum' = IP 校验和错 -> stat_drop_ipcsum
#   emit  : 实际交付的载荷**字节数** (缺省 = len(payload)); 'drop'/'ipcsum' 恒 0
#   tlast : 交付流末尾是否带 TLAST (缺省 True; 长度不符被中止的帧 = False)
FRAMES = [
    dict(name='udp_m16',    kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 16)),
    dict(name='udp_m0',     kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 0)),
    dict(name='udp_m6',     kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 6)),
    dict(name='udp_m7',     kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 7)),
    dict(name='udp_m1000',  kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 1000)),
    dict(name='udp_nport',  kind='drop',   mk=lambda: mk_udp(MY_IP, UDP_PORT_OTHER, 16)),
    dict(name='udp_nip',    kind='drop',   mk=lambda: mk_udp(0x0A000001, UDP_PORT_MATCH, 16)),
    dict(name='udp_badcrc', kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 100, bad_fcs=True)),
    dict(name='udp_badipc', kind='ipcsum', mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 16, bad_ipcsum=True)),
    dict(name='tcp_syn',    kind='drop',   mk=lambda: mk_tcp_syn(MY_IP, UDP_PORT_MATCH)),
    dict(name='arp',        kind='drop',   mk=lambda: mk_arp()),
    dict(name='udp_m1472',  kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 1472)),
    dict(name='udp_m16b',   kind='match',  mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 16)),
]

# ---- R2 (P5E_ROUND=2): app RX 契约的畸变用例 (半帧/截断/组播不匹配) ----
#   udp_len_half: 载荷 40B 但 udp_len 声称 8+20=28 ⇒ meta_len=20; w5 hold 后
#     pcount=6, 第一拍 S_PAY 6+8<=20 交付 (pcount=14), 第二拍 14+8>20 ⇒ 中止
#     ⇒ 交付 1 字 = 8B, **无 TLAST** (下游看到半帧), 记 stat_drop_nonmatch+1,
#     **不计 stat_pass/stat_bytes**。
#   udp_len_over: 载荷 40B 但声称 udp_len=8+100 ⇒ meta_len=100; S_PAY 逐拍
#     6/14/22/30 均 <=100 ⇒ 交付 4 字 = 32B, 末字 (tlast 拍) 因
#     pcount(38)+2 != 100 被中止 ⇒ **无 TLAST**, stat_drop_nonmatch+1。
#   udp_len_lt8 : udp_len=4 < 8 ⇒ w4 拍被 udp_len_ok 拦下 (无 meta)
#   udp_mcast   : 组播 dst 239.1.2.3, cfg_multi_en=0 ⇒ 不匹配 (单播 IP 精确匹配)
FRAMES_R2 = [
    dict(name='udp_len_half', kind='partial', mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 40,
                                                                udp_len=8 + 20),
         emit=8, dlen=20),
    dict(name='udp_len_over', kind='partial', mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 40,
                                                                udp_len=8 + 100),
         emit=32, dlen=100),
    dict(name='udp_len_lt8',  kind='drop',    mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 16,
                                                                udp_len=4)),
    dict(name='udp_mcast',    kind='drop',    mk=lambda: mk_udp(0xEF010203, UDP_PORT_MATCH, 16)),
]

ROUND = os.environ.get('P5E_ROUND', '1')


# ---- R3 (P5E_ROUND=3): pcount 位宽边界 (udp_rx 的 12 位 pcount) ----
# rtl/udp_rx.v 的 `reg [11:0] pcount` 只 12 位, 而 S_PAY 的超长守卫写成
# `pcount + 12'd8 > meta_len_r` (12 位加法, 4095 后**回绕**)。推论:
#   载荷 <= 4096B: 末拍校验 pcount+pop8 == meta_len 恰好成立 -> 完整交付;
#   载荷 >= 4097B: pcount 回绕 -> 末拍校验失败 -> 帧落 S_DROP:
#                  载荷交付 6+8k 字节后**无 TLAST 中止**, 记 nonmatch。
# 本工程 1G (MTU 1500) 无影响; 但 10G 行情常见 9KB jumbo ⇒ P5e 必须先证伪/修正。
# 下面的 _pay_emit 是**精确复刻** (仅用于生成期自证, 不是判据本身)。
def _pay_emit(n, dlen):
    """复刻 rtl/udp_rx.v 的交付语义, 返回 (交付字节数, 末字是否带 TLAST, 原因)。

    关键 Verilog 语义 (P5e 实测修正过一次): `pcount` 是 `reg [11:0]`, 但
    **只有"寄存器更新" `pcount <= pcount + 12'd8` 按 12 位截断**; 两处比较
    (S_PAY 守卫 `pcount + 12'd8 > meta_len_r` 与末拍校验 `pcount + pop8 !=
    meta_len_r`) 是 **context-determined 表达式** —— 因为右操作数 meta_len_r
    是 16 位, 整个表达式在 16 位下求值, pcount 先零扩展到 16 位再加, **不回绕**。
    所以失败判据是 `(6 + 8*(words-7)) mod 4096 + last_keep == dlen`:
      A = 6+8*(words-7)  (交付前的 pcount 递推值, 恒有 A + last_keep == n == dlen)
      A < 4096 -> 通过; A >= 4096 -> pcount 寄存器已回绕, 末拍校验失败 -> 半帧。
    A = 8*words - 50 ⇒ 通过条件 words <= 518 ⇔ 载荷 n <= 4102 字节。"""
    words = (42 + n + 7) // 8
    last_keep = 42 + n - 8 * (words - 1)
    if words < 6:
        return 0, False, 'RUNT'                    # 头没走完帧就结束 -> nonmatch
    if words == 6:                                 # 走 S_HDR 短载荷特例
        if last_keep - 2 != dlen:
            return 0, False, 'SHORT-LEN'
        return max(0, last_keep - 2), (last_keep != 2), 'OK-SHORT'
    pc, delivered = 6, 0
    for _ in range(words - 7):                     # w6 .. w(words-2) 的 S_PAY 拍
        if (pc + 8) > dlen:                        # 16 位上下文: 不回绕
            return delivered, False, 'PAY-OVER'
        pc = (pc + 8) & 0xFFF                      # 寄存器: 12 位截断
        delivered += 8
    if last_keep == 0:
        return delivered, False, 'LAST-KEEP0'
    if (pc + last_keep) != dlen:                   # 16 位上下文: 不回绕
        return delivered, False, 'TAIL-MISMATCH'
    if last_keep <= 2:
        return delivered + 6 + last_keep, True, 'OK-SHORT'
    return delivered + 8 + (last_keep - 2), True, 'OK-TAIL'


# FRAMES_R3: kind='partial' 的 emit/tlast 由 _pay_emit 推导 (生成期自证), 不硬编码。
# 实测锚点: 4095 通过 / 4096 通过 (与我第一版 12 位回绕模型相反 ⇒ 模型已修正) /
# 5000 失败 (4992B 半帧)。下面的 4102/4103 用来钉死 A=4096 的确切边界。
FRAMES_R3 = [
    dict(name='udp_p4095', kind='match',   mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 4095)),
    dict(name='udp_p4096', kind='match',   mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 4096)),
    dict(name='udp_p4102', kind='match',   mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 4102)),
    dict(name='udp_p4103', kind='partial', mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 4103,
                                                             udp_len=8 + 4103)),
    dict(name='udp_p5000', kind='partial', mk=lambda: mk_udp(MY_IP, UDP_PORT_MATCH, 5000,
                                                             udp_len=8 + 5000)),
]


def frame_specs():
    if ROUND == '2':
        return FRAMES + FRAMES_R2
    if ROUND == '3':
        return FRAMES + FRAMES_R3
    return FRAMES


def build():
    """返回 [dict(name,kind,fb,fcs,pl,crs,emit,tlast,dlen)]
    dlen = 帧里 UDP 头**声明的**载荷长 (meta_len / stat_bytes 的口径)。"""
    out = []
    for spec in frame_specs():
        fb, fcs, pl = spec['mk']()
        crs = ((zlib.crc32(fb + fcs) ^ 0xFFFFFFFF) & 0xFFFFFFFF) == 0xDEBB20E3
        kind = spec['kind']
        dlen = spec.get('dlen', len(pl))
        if kind in ('drop', 'ipcsum'):
            emit, tlast = 0, True          # 不交付 (tlast 无意义)
        else:
            # 生成期自证: 交付字节/TLAST 由 _pay_emit 复刻推得, 不手算
            emit, tlast, why = _pay_emit(len(pl), dlen)
            if kind == 'match':
                # 0 长载荷帧 (udp_m0) 不发任何字 ⇒ AXIS TLAST 无意义, 只查字节数
                assert emit == len(pl) and (tlast or emit == 0), \
                    '%s: 声明 match 但 _pay_emit 推 (%d,%d,%s)' % (
                        spec['name'], emit, tlast, why)
                emit = len(pl)
            if spec.get('emit') is not None:
                assert spec['emit'] == emit, \
                    '%s: _pay_emit 推 emit=%d != 声明 %d (dlen=%d)' % (
                        spec['name'], emit, spec['emit'], dlen)
        out.append(dict(name=spec['name'], kind=kind, fb=fb, fcs=fcs, pl=pl,
                        crs=crs, emit=emit, tlast=tlast, dlen=dlen))
    return out


def generate(simdir):
    frames = build()
    segs = []
    for _ in range(256):                      # 与本门 canonical 同口径的 256 拍空闲前缀
        segs.append((0x07, 0))
    for fr in frames:
        for b in (PRE + fr['fb'] + fr['fcs']):
            segs.append((b, 1))
        for b in IFG:
            segs.append((b, 0))
    for _ in range(64):
        segs.append((0x07, 0))
    with io.open(os.path.join(simdir, 'stim_data.memh'), 'w', newline='\n') as f:
        f.write('\n'.join('%02X' % s[0] for s in segs) + '\n')
    with io.open(os.path.join(simdir, 'stim_dv.memh'), 'w', newline='\n') as f:
        f.write('\n'.join('%d' % s[1] for s in segs) + '\n')
    with io.open(os.path.join(simdir, 'stim_er.memh'), 'w', newline='\n') as f:
        f.write('\n'.join('0' for _ in segs) + '\n')
    print('gen_stim_p5e_udp[round=%s]: %d 帧 (match %d / nonmatch %d / ipcsum %d), '
          'stim=%d 拍 (256 空闲 + 字节流 + 64)'
          % (ROUND, len(frames),
             sum(1 for x in frames if x['kind'] == 'match'),
             sum(1 for x in frames if x['kind'] == 'drop'),
             sum(1 for x in frames if x['kind'] == 'ipcsum'),
             len(segs)))
    return frames


# ============================= 判据 =============================

def pop8(k):
    return bin(k).count('1')


def words_of(hexdata, keep):
    """从一个字 (tdata,tkeep) 取有效字节 (MSB 起, popcount(tkeep) 个)"""
    n = pop8(keep)
    return bytes((hexdata >> (56 - 8 * i)) & 0xFF for i in range(n))


def check(simdir):
    frames = generate(simdir)
    resp = os.path.join(simdir, 'resp_p5_udp_split.memh')
    slw, udp, metas, fends = [], [], [], []
    ustat = None
    p5stat = p5tx = None
    with io.open(resp, 'r', errors='replace') as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            if p[0] == 'P5ESLW':
                slw.append((int(p[1], 16), int(p[2], 16), int(p[3]),
                            int(p[4]), int(p[5]), int(p[6])))
            elif p[0] == 'P5EUDP':
                udp.append((int(p[1], 16), int(p[2], 16), int(p[3]),
                            int(p[4]), int(p[5])))
            elif p[0] == 'P5EMETA':
                metas.append((int(p[1], 16), int(p[2], 16), int(p[3], 16),
                              int(p[4], 16)))
            elif p[0] == 'P5EFEND':
                fends.append((int(p[1]), int(p[2])))
            elif p[0] == 'P5EUSTAT':
                ustat = tuple(int(x) for x in p[1:])
            elif p[0] == 'P5STAT':
                p5stat = tuple(int(x) for x in p[1:8])
            elif p[0] == 'P5TX':
                p5tx = tuple(int(x) for x in p[1:8])

    errs = []
    if ustat is None:
        errs.append('resp 缺 P5EUSTAT (TB 未跑到末尾? 检查 xsim 是否超时/死锁)')
        return errs
    if not slw:
        errs.append('slow 口零字 —— 拆分点没有数据 (rx_classify 接线? )')
        return errs

    # ---------- (1) 拆分点: 从 slow 原始字流重建帧, 与注入帧逐字节比对 ----------
    got, cur, cur_ok = [], bytearray(), True
    for (d, k, last, sop, crs, err) in slw:
        if sop:
            if cur:
                errs.append('slow 口: 上一帧未见 tlast 就来了新 SOP (截断)')
                cur = bytearray()
            cur_ok = True
        if pop8(k) == 0:
            errs.append('slow 口: tkeep=0 的零有效字')
        bb = words_of(d, k)
        if len(bb) > 0 and d & ((1 << (56 - 8 * (len(bb) - 1))) - 1) != 0:
            errs.append('slow 口: tkeep 外仍有非零数据位 (高阻无关位非零)')
        cur += bb
        if last:
            got.append((bytes(cur), crs, err))
            cur = bytearray()
    if cur:
        errs.append('slow 口: 末尾帧未收 tlast')

    exp_frames = frames[:len(got)] if len(got) <= len(frames) else frames
    if len(got) != len(frames):
        errs.append('slow 帧数 %d != 注入帧数 %d (slow 口丢/多帧)' % (len(got), len(frames)))
    for i, fr in enumerate(frames):
        if i >= len(got):
            break
        gb, gcrs, gerr = got[i]
        if gb != fr['fb']:
            n = min(len(gb), len(fr['fb']))
            j = next((x for x in range(n) if gb[x] != fr['fb'][x]), n)
            errs.append('slow 帧#%d (%s) 字节不符: len %d vs %d, 首差 @%d'
                        % (i, fr['name'], len(gb), len(fr['fb']), j))
        elif gcrs != fr['crs']:
            errs.append('slow 帧#%d (%s): crs=%d 应为 %d'
                        % (i, fr['name'], gcrs, fr['crs']))
        if gerr:
            errs.append('slow 帧#%d (%s): terr=1' % (i, fr['name']))

    # ---------- (2) udp_rx: meta / 载荷 / fend ----------
    # meta 只在"匹配"帧发 (kind match=完整交付 / partial=声明长不符被中止,
    # 两者都发 meta); drop/ipcsum 不发 meta。
    exp_meta = [x for x in frames if x['kind'] in ('match', 'partial')]
    exp_match = [x for x in frames if x['kind'] == 'match']
    exp_drop = [x for x in frames if x['kind'] == 'drop']
    exp_ipc = [x for x in frames if x['kind'] == 'ipcsum']

    if len(metas) != len(exp_meta):
        errs.append('meta 数 %d != 期望 %d (match+partial 帧数)' % (len(metas), len(exp_meta)))
    for i, fr in enumerate(exp_meta):
        if i >= len(metas):
            break
        smac, sip, sport, mlen = metas[i]
        # meta_len = 帧里 UDP 头**声明**的载荷长 (与 RTL 一致; 畸变帧取声明值)
        if smac != int.from_bytes(SRC_MAC, 'big'):
            errs.append('frame %s meta_src_mac %012X != %012X'
                        % (fr['name'], smac, int.from_bytes(SRC_MAC, 'big')))
        if sip != SRC_IP:
            errs.append('frame %s meta_src_ip %08X != %08X' % (fr['name'], sip, SRC_IP))
        if sport != SPORT:
            errs.append('frame %s meta_src_port %04X != %04X'
                        % (fr['name'], sport, SPORT))
        if mlen != fr['dlen']:
            errs.append('frame %s meta_len %d != %d' % (fr['name'], mlen, fr['dlen']))

    # 载荷流: **扁平字节流 + TLAST 偏移表** 逐字节比对。
    # 这样表述同时覆盖 ① 0 长载荷帧 (不发字) ② 声明长不符被中止的半帧
    # (发若干字但**无 TLAST**, 与下一帧的字直接相邻) —— 两类都不产生"段"。
    got_stream, got_tlast = bytearray(), []
    for (d, k, last, crc_ok, err) in udp:
        got_stream += words_of(d, k)
        if last:
            got_tlast.append((len(got_stream), crc_ok))
            if err:
                errs.append('udp_rx TLAST 拍 tuser[1]=err 应为 0')
    exp_stream, exp_tlast = bytearray(), []
    for fr in frames:
        if fr['emit'] > 0:
            exp_stream += fr['pl'][:fr['emit']]
            if fr['tlast']:
                exp_tlast.append((len(exp_stream), 1 if fr['crs'] else 0))
    if bytes(got_stream) != bytes(exp_stream):
        n = min(len(got_stream), len(exp_stream))
        j = next((x for x in range(n) if got_stream[x] != exp_stream[x]), n)
        errs.append('udp_rx 载荷字节流不符: len %d vs %d, 首差 @%d'
                    % (len(got_stream), len(exp_stream), j))
    if got_tlast != exp_tlast:
        errs.append('udp_rx TLAST 位置/crc_ok 表 %s != 期望 %s'
                    % (got_tlast, exp_tlast))
    for (d, k, last, crc_ok, err) in udp:
        if not last and k != 0xFF:
            errs.append('udp_rx 非末字 tkeep=%02X != FF' % k)
        if last and k == 0:
            errs.append('udp_rx 末字 tkeep == 0')
    # 逐帧交付报告 (判据的可读证据)
    off = 0
    for fr in frames:
        if fr['emit'] <= 0:
            continue
        mark = 'TLAST crc_ok=%d' % (1 if fr['crs'] else 0) if fr['tlast'] \
            else 'NO-TLAST (半帧)'
        print('    %-12s 交付 %4d/%4d B (声明 meta_len=%d)  %s'
              % (fr['name'], fr['emit'], len(fr['pl']), fr['dlen'], mark))
        off += fr['emit']
    print('  载荷字节流合计 %d B (期望 %d), TLAST 表 %s'
          % (len(got_stream), len(exp_stream),
             'OK' if got_tlast == exp_tlast else 'MISMATCH'))

    # ---------- fend / 统计 ----------
    if len(fends) != len(exp_match):
        errs.append('fend 数 %d != 匹配帧数 %d' % (len(fends), len(exp_match)))
    for i, fr in enumerate(exp_match):
        if i >= len(fends):
            break
        ferr, flen = fends[i]
        if flen != fr['dlen']:
            errs.append('fend#%d (%s) meta_len %d != %d'
                        % (i, fr['name'], flen, fr['dlen']))
        if ferr != (0 if fr['crs'] else 1):
            errs.append('fend#%d (%s) ferr=%d 应为 %d'
                        % (i, fr['name'], ferr, 0 if fr['crs'] else 1))

    # stat_bytes 口径 = **声明** meta_len 之和 (udp_rx 累加 meta_len_r), 只算 crs 好的
    # 完整交付帧 (partial 帧落 S_DROP, 不计 pass/bytes)
    exp_pass = sum(1 for x in exp_match if x['crs'])
    exp_crc = sum(1 for x in exp_match if not x['crs'])
    exp_bytes = sum(x['dlen'] for x in exp_match if x['crs'])
    exp_nm = len(exp_drop) + len([x for x in frames if x['kind'] == 'partial'])
    got_stat = (ustat[0], ustat[1], ustat[2], ustat[3], ustat[4])
    want_stat = (exp_pass, exp_nm, len(exp_ipc), exp_crc, exp_bytes)
    if got_stat != want_stat:
        errs.append('udp_rx 统计 %s != 期望 (pass,nonmatch,ipcsum,crc,bytes) %s'
                    % (got_stat, want_stat))
    print('  slow 帧 %d / 字 %d ; udp_rx 载荷 %d B / TLAST %d 处 / meta %d / fend %d'
          % (len(got), len(slw), len(got_stream), len(got_tlast), len(metas),
             len(fends)))
    print('  meta 实测 (src_mac src_ip src_port len) [帧名 / 期望 len]:')
    for i, m in enumerate(metas):
        if i < len(exp_meta):
            print('    %012X %08X %04X %-5d [%s / 期望 %d]'
                  % (m + (exp_meta[i]['name'], exp_meta[i]['dlen'])))
        else:
            print('    %012X %08X %04X %d' % m)
    print('  udp_rx 统计 pass=%d nonmatch=%d ipcsum=%d crc=%d bytes=%d | mac_drop=%d stall=%d'
          % ustat)
    if p5stat:
        print('  fast 路径旁证: pat_tx_bytes=%d pat_tx_frames=%d pat_rx_bytes=%d '
              'pat_mismatch=%d pat_done=%d' % p5stat[:5])
    if p5tx:
        print('  tx: frames=%d bytes=%d ack=%d drop_len=%d fin=%d rst=%d eend=%d'
              % p5tx[:7])
    return errs


def main():
    simdir = sys.argv[1] if len(sys.argv) > 1 else r"D:\repo\ECO\udp_hls_10g\sim\p5e_pre"
    if len(sys.argv) > 2 and sys.argv[2] == 'check':
        errs = check(simdir)
        if errs:
            print('P5e UDP SPLIT GATE: FAIL (%d)' % len(errs))
            for e in errs[:40]:
                print('  - %s' % e)
            return 1
        print('P5e UDP SPLIT GATE: PASS')
        return 0
    generate(simdir)
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
