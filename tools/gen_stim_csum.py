#!/usr/bin/env python
"""checksum16 xsim 刺激生成 + 周期精确模型 (与 TB 非阻塞语义 1:1) + 参考校验和。

脚本行: (ty, data, keep)  ty: 0=GAP(n) 1=init(val) 2=word(data,keep) 3=add(udp_len) 4=fin
TB 语义: 每拍先按上拍计算值采样 DUT, 再计算下拍激励 (非阻塞)。
"""
import os
import random


def words_of(payload):
    ws = []
    for k in range(0, len(payload), 8):
        chunk = payload[k:k + 8]
        w = int.from_bytes(chunk.ljust(8, b"\x00"), "big")
        keep = (0xFF << (8 - len(chunk))) & 0xFF
        ws.append((w, keep))
    return ws


def ref_csum(payload, src_ip, dst_ip, udp_len):
    s = ((src_ip >> 16) + (src_ip & 0xFFFF) + (dst_ip >> 16) +
         (dst_ip & 0xFFFF) + 0x0011 + udp_len)
    for i in range(0, len(payload), 2):
        b = payload[i:i + 2]
        s += (b[0] << 8) | (b[1] if len(b) > 1 else 0)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_script(nframes=40, seed=7):
    rng = random.Random(seed)
    frames = []
    script = []
    for _ in range(nframes):
        src_ip = rng.getrandbits(32)
        dst_ip = rng.getrandbits(32)
        n = rng.randrange(0, 200)          # 含 0 长与奇数长
        payload = bytes(rng.getrandbits(8) for _ in range(n))
        udp_len = n + 8
        init_val = ((src_ip >> 16) + (src_ip & 0xFFFF) + (dst_ip >> 16) +
                    (dst_ip & 0xFFFF) + 0x0011)
        script.append((1, init_val, 0))
        for w, k in words_of(payload):
            script.append((2, w, k))
        script.append((3, udp_len, 0))
        script.append((4, 0, 0))
        script.append((0, 3, 0))
        frames.append(ref_csum(payload, src_ip, dst_ip, udp_len))
    return script, frames


def wsum(d, k):
    s = 0
    for hwi in range(4):
        j = 2 * hwi
        kb_hi, kb_lo = 7 - j, 7 - j - 1
        if not (k >> kb_hi) & 1:
            continue
        hi = (d >> (56 - 8 * j)) & 0xFF
        lo = ((d >> (56 - 8 * (j + 1))) & 0xFF) if (k >> kb_lo) & 1 else 0
        s += (hi << 8) | lo
    return s


def fold16(v):
    f1 = (v & 0xFFFF) + (v >> 16)
    return ((f1 & 0xFFFF) + (f1 >> 16)) & 0xFFFF


def model(script, maxc=20000):
    """周期精确模型, 返回每拍 (valid, csum) 与 TB 日志同约定 (拍首值)。"""
    acc = 0
    csum_out = 0
    valid_out = 0
    t_init = t_den = t_aen = t_fin = 0
    t_init_val = t_ddata = t_dkeep = t_aval = 0
    si = 0
    gap = 0
    resp = []
    for _ in range(maxc):
        # TB 日志 = 本拍 NBA 之前的 DUT 寄存器值 (上拍计算值), 先记再算
        resp.append((valid_out, csum_out))
        if t_init:
            acc_n = t_init_val & 0xFFFFFFFF
        elif t_aen:
            acc_n = (acc + t_aval) & 0xFFFFFFFF
        elif t_den:
            acc_n = (acc + wsum(t_ddata, t_dkeep)) & 0xFFFFFFFF
        else:
            acc_n = acc
        csum_n = (~fold16(acc)) & 0xFFFF if t_fin else csum_out
        valid_n = 1 if t_fin else 0
        acc, csum_out, valid_out = acc_n, csum_n, valid_n
        t_init = t_den = t_aen = t_fin = 0
        if gap > 0:
            gap -= 1
        elif si < len(script):
            ty, d, k = script[si]
            if ty == 0:
                gap = d - 1
            elif ty == 1:
                t_init, t_init_val = 1, d
            elif ty == 2:
                t_den, t_ddata, t_dkeep = 1, d, k
            elif ty == 3:
                t_aen, t_aval = 1, d
            elif ty == 4:
                t_fin = 1
            si += 1
    return resp


def generate(simdir, nframes=40, seed=7):
    script, refs = build_script(nframes, seed)
    ty, d, k = [], [], []
    for s in script:
        ty.append(s[0])
        d.append(s[1])
        k.append(s[2])

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('csum_ty.memh', ty, '%X')
    w('csum_data.memh', d, '%016X')
    w('csum_keep.memh', k, '%02X')
    with open(os.path.join(simdir, 'csum_refs.txt'), 'w') as fh:
        fh.write('\n'.join('%04X' % r for r in refs) + '\n')
    return script, refs


def check(simdir):
    script, refs = generate(simdir)          # 重新生成, 保证与 sim 文件一致
    resp = []
    with open(os.path.join(simdir, 'resp_csum.memh')) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            v, c = line.split()
            resp.append((int(v), int(c, 16)))
    exp = model(script, maxc=len(resp))
    nval = 0
    ok = True
    for i, (ev, ec) in enumerate(exp):
        rv, rc = resp[i]
        if ev != rv:
            print('MISMATCH valid @%d: model %d resp %d' % (i, ev, rv))
            ok = False
            break
        if ev and ec != rc:
            print('MISMATCH csum @%d: model %04X resp %04X' % (i, ec, rc))
            ok = False
            break
        nval += ev
    if ok:
        # 每个 valid 值必须等于独立参考
        val_refs = [ec for ev, ec in exp if ev]
        if val_refs != refs:
            print('REF MISMATCH: model %s ref %s' %
                  (['%04X' % v for v in val_refs],
                   ['%04X' % v for v in refs]))
            ok = False
    print('valid pulses: %d / %d frames' % (nval, len(refs)))
    return ok


if __name__ == '__main__':
    import sys
    simdir = sys.argv[1] if len(sys.argv) > 1 else 'sim'
    script, refs = generate(simdir)
    print('%d frames, %d script lines' % (len(refs), len(script)))
