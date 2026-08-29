#!/usr/bin/env python
"""rx_classify xsim 刺激生成 + 周期精确参考模型 (规范驱动, 非 RTL 镜像)。

DUT 规范: 3 字 skid (w0..w2), w2 拍定路由 (ethertype @w1[31:16]==0x0800 &&
proto @w2[7:0]==6 -> fast, 否则 slow); w2 前 tlast -> runt 一律 slow。
DRAIN 倒空 skid (s_tready=0), 然后 PASS 直通 (s_tready=所选路由 tready)。
sideband {tdata,tkeep,tlast,tuser,tcrs,terr} 全透传。帧尾拍计 stat_fast/stat_slow。

三模式: nostall / stall (fast 3高1低, slow 2高1低, 不同相) / hard (双路硬停窗)。
用法: python gen_stim_p4_rxclass.py <simdir>          # 生成刺激+期望
      python gen_stim_p4_rxclass.py <simdir> --check   # 比对 resp vs exp
"""
import os
import sys

FILL, DRAIN, PASS = 0, 1, 2
FAST, SLOW = 0, 1


def mk_frame(ethertype, proto, nbytes, crs=1, err=0, gapmap=None):
    """构造字流帧: [(data,keep,last,user,crs,err,gap_before)]。"""
    b = bytearray(nbytes)
    dst = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]
    src = [0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0]
    for i in range(6):
        if i < nbytes:
            b[i] = dst[i]
        if 6 + i < nbytes:
            b[6 + i] = src[i]
    if nbytes > 12:
        b[12] = (ethertype >> 8) & 0xFF
    if nbytes > 13:
        b[13] = ethertype & 0xFF
    if nbytes > 14:
        b[14] = 0x45
    if nbytes > 23:
        b[23] = proto & 0xFF
    for i in range(24, nbytes):
        b[i] = (i * 5 + 1) & 0xFF
    words = []
    nw = (nbytes + 7) // 8
    for wi in range(nw):
        chunk = bytes(b[wi * 8:(wi + 1) * 8])
        data = int.from_bytes(chunk.ljust(8, b'\x00'), 'big')
        keep = (0xFF << (8 - len(chunk))) & 0xFF
        last = 1 if wi == nw - 1 else 0
        gap = 0 if gapmap is None else gapmap.get(wi, 0)
        words.append((data, keep, last, 1 if wi == 0 else 0,
                      crs if last else 0, err if last else 0, gap))
    return words


def build_stream():
    """帧序列 -> 字流 [(data,keep,last,user,crs,err,gap)]。"""
    F = []
    F += mk_frame(0x0800, 6, 40, gapmap={0: 3})            # tcp5 -> fast
    F += mk_frame(0x0800, 17, 32, gapmap={0: 2})           # udp4 -> slow
    F += mk_frame(0x0800, 1, 32, gapmap={0: 2})            # icmp4 -> slow
    F += mk_frame(0x0806, 0, 28, gapmap={0: 2})            # arp4 -> slow
    F += mk_frame(0x88B5, 0, 36, gapmap={0: 2})            # unknown et -> slow
    F += mk_frame(0x0800, 6, 6, gapmap={0: 2})             # runt 1 字 -> slow
    F += mk_frame(0x0800, 6, 12, gapmap={0: 2})            # runt 2 字 -> slow
    F += mk_frame(0x0800, 6, 24, gapmap={0: 2})            # tlast@w2 TCP -> fast
    F += mk_frame(0x0800, 17, 24, gapmap={0: 2})           # tlast@w2 UDP -> slow
    F += mk_frame(0x0800, 6, 32, gapmap={0: 2})            # tlast@w3 TCP -> fast
    F += mk_frame(0x0800, 6, 40, crs=0, gapmap={0: 2})     # 坏 FCS 仍 fast
    F += mk_frame(0x0800, 6, 40, err=1, gapmap={0: 2})     # rx_er 仍 fast
    F += mk_frame(0x0800, 6, 96, gapmap={0: 2})            # 12 字长帧 fast
    F += mk_frame(0x0800, 6, 40, gapmap={0: 0})            # b2b TCP
    F += mk_frame(0x0800, 17, 40, gapmap={0: 0})           # b2b UDP (0 间隔)
    F += mk_frame(0x0800, 6, 40, gapmap={0: 0})            # b2b TCP
    F += mk_frame(0x0806, 0, 28, gapmap={0: 2})            # b2b ARP
    F += mk_frame(0x0800, 6, 48, gapmap={0: 2, 2: 1, 4: 1})  # 帧内气泡
    return F


def frdy_at(mode, k, hw):
    if mode == 'stall':
        return 0 if k % 4 == 3 else 1
    if mode == 'hard':
        return 0 if hw[0] <= k < hw[1] else 1
    return 1


def srdy_at(mode, k, hw):
    if mode == 'stall':
        return 0 if k % 3 == 0 else 1
    if mode == 'hard':
        return 0 if hw[0] <= k < hw[1] else 1
    return 1


def model(words, mode, hw):
    """周期精确模型。返回 (lines, stat_fast, stat_slow)。"""
    # TB 源驱动寄存器
    v = 0
    d = kk = l = u = c = e = 0
    idx = 0
    gap = 0
    nstim = len(words)
    # DUT 寄存器
    state = FILL
    route = SLOW
    n = 0
    sk = [(0, 0, 0, 0, 0, 0)] * 3
    stat_fast = 0
    stat_slow = 0
    lines = []
    k = 0
    kmax = 40000
    while k < kmax:
        # TB 的 f_rdy/s_rdy 为寄存器: 周期 j 的值 = 模式函数(j-1), 周期 0 = 复位值 1
        frdy = 1 if k == 0 else frdy_at(mode, k - 1, hw)
        srdy = 1 if k == 0 else srdy_at(mode, k - 1, hw)
        m_tready_sel = frdy if route == FAST else srdy
        s_tready = 1 if state == FILL else (m_tready_sel if state == PASS else 0)
        s_acc = v and s_tready
        o_v = 1 if state == DRAIN else (v if state == PASS else 0)
        o_acc = o_v and m_tready_sel
        o = sk[0] if state == DRAIN else (d, kk, l, u, c, e)
        if o_acc:
            lines.append('%s %016X %02X %d %d %d %d' %
                         ('F' if route == FAST else 'S',
                          o[0], o[1], o[2], o[3], o[4], o[5]))
        # ---- DUT 状态更新 (NBA 语义: 全部由旧值计算) ----
        state_n, route_n, n_n = state, route, n
        sk_n = list(sk)
        if state == FILL:
            if s_acc:
                sk_n[n] = (d, kk, l, u, c, e)
                if l:
                    route_n = SLOW
                    n_n = n + 1
                    state_n = DRAIN
                elif n == 2:
                    is_tcp = (sk[1][0] >> 16) & 0xFFFF == 0x0800 and (d & 0xFF) == 6
                    route_n = FAST if is_tcp else SLOW
                    n_n = 3
                    state_n = DRAIN
                else:
                    n_n = n + 1
        elif state == DRAIN:
            if o_acc:
                if sk[0][2]:
                    state_n = FILL
                    n_n = 0
                    if route == FAST:
                        stat_fast += 1
                    else:
                        stat_slow += 1
                else:
                    sk_n = [sk[1], sk[2], sk[2]]
                    n_n = n - 1
                    if n == 1:
                        state_n = PASS
        else:  # PASS
            if s_acc and l:
                state_n = FILL
                if route == FAST:
                    stat_fast += 1
                else:
                    stat_slow += 1
        state, route, n, sk = state_n, route_n, n_n, sk_n
        # ---- TB 源更新 (与 tb_rx_classify.v NBA 一致) ----
        if v and s_tready:
            v = 0
        if (not v) or (v and s_tready):
            if gap > 0:
                gap -= 1
            elif idx < nstim:
                d, kk, l, u, c, e, g0 = words[idx]
                v = 1
                gap = g0
                idx += 1
        k += 1
        if idx >= nstim and not v and state == FILL and k > 200:
            break
    return lines, stat_fast, stat_slow


def generate(simdir):
    words = build_stream()
    # hard 窗口 [40,60): 落在帧流中段 (全流 ~90 字, nostall 约 100 拍排完),
    # 冻结双路输出 20 拍, 覆盖 DRAIN-hold 与 PASS-hold。
    hw0, hw1 = 40, 60

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % x for x in vals) + '\n')
    w('rc_data.memh', [x[0] for x in words], '%016X')
    w('rc_keep.memh', [x[1] for x in words], '%02X')
    w('rc_last.memh', [x[2] for x in words], '%X')
    w('rc_user.memh', [x[3] for x in words], '%X')
    w('rc_crs.memh', [x[4] for x in words], '%X')
    w('rc_err.memh', [x[5] for x in words], '%X')
    w('rc_gap.memh', [x[6] for x in words], '%X')
    with open(os.path.join(simdir, 'rc_nstim.memh'), 'w') as fh:
        fh.write('%X\n' % len(words))
    with open(os.path.join(simdir, 'hardwin_rc.memh'), 'w') as fh:
        fh.write('%X\n%X\n' % (hw0, hw1))
    for mode in ('nostall', 'stall', 'hard'):
        lines, sf, ss = model(words, mode, (hw0, hw1))
        with open(os.path.join(simdir, 'exp_rc_%s.memh' % mode), 'w') as fh:
            for ln in lines:
                fh.write(ln + '\n')
            fh.write('STATS %d %d\n' % (sf, ss))
        print('%s: %d lines, fast=%d slow=%d' % (mode, len(lines), sf, ss))
    return words


def check(simdir):
    ok_all = True
    for mode in ('nostall', 'stall', 'hard'):
        exp = [l.strip().lower() for l in
               open(os.path.join(simdir, 'exp_rc_%s.memh' % mode)) if l.strip()]
        fn = os.path.join(simdir, 'resp_rc_%s.memh' % mode)
        if not os.path.exists(fn):
            print('%s: MISSING %s' % (mode, fn))
            ok_all = False
            continue
        resp = [l.strip().lower() for l in open(fn) if l.strip()]
        ok = exp == resp
        if not ok:
            for i in range(max(len(exp), len(resp))):
                a = exp[i] if i < len(exp) else '<none>'
                b = resp[i] if i < len(resp) else '<none>'
                if a != b:
                    print('%s LINE %d: exp %r resp %r' % (mode, i, a, b))
                    break
        print('%s: %s (%d lines)' % (mode, 'PASS' if ok else 'FAIL', len(resp)))
        ok_all &= ok
    print('tb_rx_classify: %s' % ('PASS' if ok_all else 'FAIL'))
    return ok_all


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else '.'
    if '--check' in sys.argv:
        sys.exit(0 if check(simdir) else 1)
    generate(simdir)
