#!/usr/bin/env python
"""tcp_tx_frame 全链刺激生成 + GMII 帧解码验证。

帧序 = 脚本序 (ACK 插队规则: 只在数据帧边界调度, len100 帧中注入的 ack 在该帧后)。
逐帧语义验证: dmac/dip/端口按 conn, ethertype 0x0800, proto 6, total_len=40+plen,
ip id=帧序号, ip/tcp 校验和重算, seq=该 conn 运行 snd_nxt (数据帧后 +=plen, ACK 不变),
ack 字段 (数据=rcv_nxt, ACK=请求值), flags (0x18/0x10), window=rcv_wnd, 载荷逐字节,
FCS 重算 (zlib.crc32 小端)。末尾比 STATS/TCBF。总结 'TCP_TX OK' / 'MISMATCH'。
"""
import os
import struct
import zlib

SRC_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC1])
SRC_IP = 0xC0A86402

# conn 配置 (与 TB cphase 写入一致)。CAM sport = 对端端口 (线上 dst_port),
# CAM dport = 本地端口 (线上 src_port)。
CONN = {
    0: dict(dmac=bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]), dip=0xC0A86402,
            peer_port=0x3039, local_port=0x1F90,
            rcv_nxt=1000, snd_nxt0=6000, rcv_wnd=0x2000),
    1: dict(dmac=bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01]), dip=0xC0A86409,
            peer_port=0xD431, local_port=0x1F91,
            rcv_nxt=77, snd_nxt0=900, rcv_wnd=0x1800),
}


def payload(n):
    return bytes(((i * 7 + 3) & 0xFF) for i in range(n))


def words_of(pl):
    ws = []
    if not pl:
        ws.append((0, 0, 1))          # 零长帧: 单拍 tlast 且 tkeep=0
        return ws
    for k in range(0, len(pl), 8):
        chunk = pl[k:k + 8]
        w = int.from_bytes(chunk.ljust(8, b"\x00"), "big")
        keep = (0xFF << (8 - len(chunk))) & 0xFF
        ws.append((w, keep, k + 8 >= len(pl)))
    return ws


def csum16(hw):
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def ip_csum_ref(tlen, idv, dip):
    hw = [0x4500, tlen & 0xFFFF, idv & 0xFFFF, 0x0000, 0x4006, 0x0000,
          (SRC_IP >> 16) & 0xFFFF, SRC_IP & 0xFFFF,
          (dip >> 16) & 0xFFFF, dip & 0xFFFF]
    return csum16(hw)


def tcp_csum_ref(cid, seq, ackf, flags, pl):
    c = CONN[cid]
    tcp_len = 20 + len(pl)
    pseudo = [(SRC_IP >> 16) & 0xFFFF, SRC_IP & 0xFFFF,
              (c['dip'] >> 16) & 0xFFFF, c['dip'] & 0xFFFF,
              0x0006, tcp_len]
    hdr = [c['local_port'], c['peer_port'],
           (seq >> 16) & 0xFFFF, seq & 0xFFFF,
           (ackf >> 16) & 0xFFFF, ackf & 0xFFFF,
           0x5000 | flags, c['rcv_wnd'], 0, 0]
    hws = []
    for i in range(0, len(pl), 2):
        b = pl[i:i + 2]
        hws.append((b[0] << 8) | (b[1] if len(b) > 1 else 0))
    return csum16(pseudo + hdr + hws)


def build_script():
    """返回 (script, frames)。script = ('W',w,k,l,tid)/('G',n)/('A',cid,val);
    frames = 期望发送顺序 ('data',cid,payload)/('ack',cid,val)。"""
    script = []
    frames = []

    def data(cid, n, mid_ack=None):
        pl = payload(n)
        ws = words_of(pl)
        for j, (w, k, l) in enumerate(ws):
            script.append(('W', w, k, l, cid))
            if mid_ack and j == 6:
                # 帧中插 gap 5 拍 (含 ack 脉冲拍), 其间打 ack -> 验证 ACK 排队等数据帧发完
                script.append(('G', 2))
                script.append(('A', mid_ack[0], mid_ack[1]))
                script.append(('G', 2))
        frames.append(('data', cid, pl))
        if mid_ack:
            frames.append(('ack', mid_ack[0], mid_ack[1]))

    for n in [1, 2, 3, 6, 7, 8, 9, 10]:
        data(0, n)
    script.append(('A', 0, 1001)); frames.append(('ack', 0, 1001))
    script.append(('A', 0, 1002)); frames.append(('ack', 0, 1002))   # 背靠背
    data(1, 42)
    script.append(('A', 1, 88));   frames.append(('ack', 1, 88))
    data(0, 100, mid_ack=(0, 1500))
    data(0, 1500)
    data(0, 0)                     # 单拍 tlast keep=0
    data(0, 5)
    return script, frames


def generate(simdir):
    script, frames = build_script()
    ty, d, k, l, n, ci, av = [], [], [], [], [], [], []
    for s in script:
        if s[0] == 'W':
            ty.append(1); d.append(s[1]); k.append(s[2]); l.append(1 if s[3] else 0)
            n.append(0); ci.append(s[4]); av.append(0)
        elif s[0] == 'G':
            ty.append(0); d.append(0); k.append(0); l.append(0)
            n.append(s[1]); ci.append(0); av.append(0)
        else:
            ty.append(2); d.append(0); k.append(0); l.append(0)
            n.append(0); ci.append(s[1]); av.append(s[2])

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('txp_ty.memh',   ty, '%X')      # $readmemh 十六进制
    w('txp_data.memh', d,  '%016X')
    w('txp_keep.memh', k,  '%02X')
    w('txp_last.memh', l,  '%X')
    w('txp_gap.memh',  n,  '%X')
    w('txp_id.memh',   ci, '%X')
    w('txp_av.memh',   av, '%08X')
    return frames


def parse_gmii(fn):
    """GMII 流 -> 帧字节列表 (剥前导 55x7+D5, 含 FCS)。"""
    frames = []
    cur = []
    active = False
    with open(fn) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('STATS') or line.startswith('TCBF'):
                continue
            parts = line.split()
            if len(parts) != 2:
                continue
            en, b = parts
            if en == '1':
                cur.append(int(b, 16))
                active = True
            elif active:
                frames.append(bytes(cur))
                cur = []
                active = False
    return frames


def check_frame(fb, fr, idx, seq):
    """验证一帧: 返回错误字符串或 None。帧 = 前导8 + 内容 + FCS4 (无 pad: 54+plen >= 54 > 46)。"""
    errs = []
    is_data = fr[0] == 'data'
    cid = fr[1]
    c = CONN[cid]
    pl = fr[2] if is_data else b''
    n = len(pl)
    ackf = c['rcv_nxt'] if is_data else fr[2]
    flags = 0x18 if is_data else 0x10
    if len(fb) < 12:
        return 'runt %d' % len(fb)
    pre = fb[:8]
    if pre != bytes([0x55] * 7 + [0xD5]):
        errs.append('preamble %s' % pre.hex())
    body = fb[8:-4]
    fcs = fb[-4:]
    if struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF) != fcs:
        errs.append('fcs %s vs %s' % (fcs.hex(),
                                      struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF).hex()))
    if len(body) != 54 + n:
        errs.append('len %d != %d' % (len(body), 54 + n))
    if len(body) < 54:
        return ';'.join(errs + ['short']) if errs else 'short'
    if body[:6] != c['dmac']:
        errs.append('dmac %s' % body[:6].hex())
    if body[6:12] != SRC_MAC:
        errs.append('src_mac %s' % body[6:12].hex())
    if body[12:14] != b'\x08\x00':
        errs.append('ethertype')
    if body[14] != 0x45:
        errs.append('ver/ihl %02x' % body[14])
    if struct.unpack('!H', body[16:18])[0] != 40 + n:
        errs.append('total_len %d != %d' % (struct.unpack('!H', body[16:18])[0], 40 + n))
    if struct.unpack('!H', body[18:20])[0] != idx & 0xFFFF:
        errs.append('id %d != %d' % (struct.unpack('!H', body[18:20])[0], idx))
    if body[20:22] != b'\x00\x00':
        errs.append('frag %s' % body[20:22].hex())
    if body[22] != 0x40 or body[23] != 0x06:
        errs.append('ttl/proto %02x%02x' % (body[22], body[23]))
    iph = struct.unpack('!10H', body[14:34])
    s = sum(iph)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('ip_csum fold %04x' % s)
    if struct.unpack('!I', body[26:30])[0] != SRC_IP:
        errs.append('src_ip %08x' % struct.unpack('!I', body[26:30])[0])
    if struct.unpack('!I', body[30:34])[0] != c['dip']:
        errs.append('dip %08x' % struct.unpack('!I', body[30:34])[0])
    if struct.unpack('!H', body[34:36])[0] != c['local_port']:
        errs.append('sport %04x' % struct.unpack('!H', body[34:36])[0])
    if struct.unpack('!H', body[36:38])[0] != c['peer_port']:
        errs.append('dport %04x' % struct.unpack('!H', body[36:38])[0])
    if struct.unpack('!I', body[38:42])[0] != seq & 0xFFFFFFFF:
        errs.append('seq %d != %d' % (struct.unpack('!I', body[38:42])[0], seq))
    if struct.unpack('!I', body[42:46])[0] != ackf & 0xFFFFFFFF:
        errs.append('ack %d != %d' % (struct.unpack('!I', body[42:46])[0], ackf))
    if body[46] != 0x50:
        errs.append('doff %02x' % body[46])
    if body[47] != flags:
        errs.append('flags %02x != %02x' % (body[47], flags))
    if struct.unpack('!H', body[48:50])[0] != c['rcv_wnd']:
        errs.append('window %04x' % struct.unpack('!H', body[48:50])[0])
    if struct.unpack('!H', body[52:54])[0] != 0:
        errs.append('urg')
    tc = struct.unpack('!H', body[50:52])[0]
    ref = tcp_csum_ref(cid, seq, ackf, flags, pl)
    if tc != ref:
        errs.append('tcp_csum %04x != %04x' % (tc, ref))
    if body[54:54 + n] != pl:
        errs.append('payload')
    return ';'.join(errs) if errs else None


def check(simdir):
    frames = generate(simdir)
    fn = os.path.join(simdir, 'resp_tcp_tx.memh')
    if not os.path.exists(fn):
        print('missing %s' % fn)
        return False
    got = parse_gmii(fn)
    errs = []
    if len(got) != len(frames):
        errs.append('frame count %d != %d' % (len(got), len(frames)))
    snd = {cid: CONN[cid]['snd_nxt0'] for cid in CONN}
    for i, (fb, fr) in enumerate(zip(got[:len(frames)], frames)):
        cid = fr[1]
        seq = snd[cid]
        e = check_frame(fb, fr, i, seq)
        if fr[0] == 'data':
            tag = 'data c%d len %d' % (cid, len(fr[2]))
            snd[cid] += len(fr[2])
        else:
            tag = 'ack c%d val %d' % (cid, fr[2])
        if e:
            errs.append('frame %d (%s): %s' % (i, tag, e))
            print('frame %2d %-16s FAIL: %s' % (i, tag, e))
        else:
            print('frame %2d %-16s ok' % (i, tag))
    for fb, fr in zip(got[len(frames):], frames[len(frames):]):
        pass
    # 统计 + TCB 终态
    stats = None
    tcbf = None
    with open(fn) as fh:
        for line in fh:
            if line.startswith('STATS'):
                stats = [int(x) for x in line.split()[1:]]
            elif line.startswith('TCBF'):
                tcbf = [int(x, 16) for x in line.split()[1:]]
    n_data = sum(1 for f in frames if f[0] == 'data')
    n_ack = len(frames) - n_data
    exp_stats = [len(frames), sum(len(f[2]) for f in frames if f[0] == 'data'), n_ack, 0]
    if stats != exp_stats:
        errs.append('stats %s != %s' % (stats, exp_stats))
    print('STATS got %s expect %s' % (stats, exp_stats))
    exp_tcbf = [snd[0] & 0xFFFFFFFF, snd[1] & 0xFFFFFFFF]
    if tcbf != exp_tcbf:
        errs.append('tcbf %s != %s' % (tcbf, exp_tcbf))
    print('TCBF got %s expect %s (snd_nxt0=%d snd_nxt1=%d)' % (tcbf, exp_tcbf, snd[0], snd[1]))
    if errs:
        print('MISMATCH')
        for e in errs:
            print('  ' + e)
        return False
    print('TCP_TX OK')
    return True


if __name__ == '__main__':
    import sys
    simdir = sys.argv[1] if len(sys.argv) > 1 else 'sim/p3sim'
    if len(sys.argv) > 2 and sys.argv[2] == 'check':
        ok = check(simdir)
        sys.exit(0 if ok else 1)
    script, frames = build_script()
    generate(simdir)
    print('%d frames, %d script lines' % (len(frames), len(script)))
