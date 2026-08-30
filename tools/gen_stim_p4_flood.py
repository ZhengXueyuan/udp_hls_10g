#!/usr/bin/env python
"""P4a 泛洪探针刺激: ARP -> 150 个 UDP 64B 背靠背泛洪 -> 350k 拍空闲 -> ARP。
观测: 泛洪后 ARP 应答是否还出 (慢路径是否卡死)。
用法: python gen_stim_p4_flood.py <simdir>
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_p4_chain as P4
import gen_stim_tcp_chain as C

PRE = C.PRE


def main():
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p4sim')
    frames = []
    # ARP #1 (基线: 应答应答)
    fb, fcs = P4.mk_arp_req()
    frames.append((fb, fcs, 2000))
    # 150 个 UDP 64B 背靠背 (gap=12 = IFG)
    fb, fcs, _ = P4.mk_udp()
    for i in range(150):
        frames.append((fb, fcs, 12))
    # 长空闲 (慢路径排空)
    frames.append((None, None, 350000))
    # ARP #2 (探针: 慢路径活着?)
    fb, fcs = P4.mk_arp_req()
    frames.append((fb, fcs, 2000))
    off = 0
    items = []
    for fb, fcs, gap in frames:
        off += gap
        if fb is None:
            continue
        items.append((off + 8, fb, fcs))
        off += 8 + len(fb) + 4 + 12
    nstim = off + 100
    data = [0] * nstim
    dv = [0] * nstim
    for first, fb, fcs in items:
        stream = PRE + fb + fcs
        for j, b in enumerate(stream):
            data[first - 8 + j] = b
            dv[first - 8 + j] = 1
    for fn, vals, fmt in (('stim_data.memh', data, '%02X'),
                          ('stim_dv.memh', dv, '%d'),
                          ('stim_er.memh', [0] * nstim, '%d')):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    with open(os.path.join(simdir, 'cfg_tcb.memh'), 'w') as fh:
        for fld in C.FIELDS:
            fh.write('%X\n' % C.TCB1_INIT[fld])
    print('flood stim: nstim=%d (%.1f ms), frames=%d' %
          (nstim, nstim * 8 / 1e6, len(items)))


if __name__ == '__main__':
    main()
