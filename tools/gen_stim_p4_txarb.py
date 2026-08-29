#!/usr/bin/env python
"""tx_arb xsim 刺激生成 + 周期精确参考模型 (规范驱动)。

DUT 规范 (rtl/tx_arb.v): 帧级 2:1 mux。busy/sel_fast 寄存器: !busy 时
f_valid->锁 fast / 否则 s_valid->锁 slow; busy 锁到 m 侧 tlast 消费拍;
数据通路纯组合 (m = sel ? fast : slow), 帧间 1 拍重仲裁气泡。

刺激: 两路独立帧流 (fast/slow 各自: 帧词表 + 词间/帧间 gap), 长度扫尾形,
含: 空闲时单 fast / 单 slow; 同拍竞争 (fast 胜); slow 帧中 fast 到达 (fast 等
帧尾); fast 帧中 slow 到达 (slow 等); 背靠背同源; 交替。
三模式: nostall / stall (m_tready 3高1低) / hard (硬停窗)。
用法: python gen_stim_p4_txarb.py <simdir> [--check]
"""
import os
import sys


def build_streams():
    """(fast_words, slow_words): [(tdata64, tkeep, tlast, gap)]。

    gap = 该词被接受后的空闲拍数 (TB/模型同约定)。帧内容编码可辨识来源:
    fast 帧内容 0xF0.. 起, slow 0x50.. 起。
    """
    def frame(fid_byte, nbytes, gap_head=3, gap_tail=3):
        ws = []
        nw = (nbytes + 7) // 8
        for wi in range(nw):
            nb = min(8, nbytes - wi * 8)
            data = int.from_bytes(bytes([fid_byte] * 8), 'big')
            keep = (0xFF << (8 - nb)) & 0xFF
            last = 1 if wi == nw - 1 else 0
            g = gap_head if wi == 0 else 0
            if wi == nw - 1:
                g = gap_tail
            ws.append((data, keep, last, g))
        return ws

    fast = []
    slow = []
    # 1) 单 fast 帧 (slow 空闲)
    fast += frame(0xF0, 16)
    # 2) 单 slow 帧
    slow += frame(0x50, 16)
    # 3) 同拍竞争: fast 胜 (两边 gap_head=0 同时到达)
    fast += frame(0xF1, 24, gap_head=0)
    slow += frame(0x51, 60, gap_head=0)
    # 4) slow 帧中 fast 到达: slow 长帧先发, fast 插入 (等 slow 帧尾)
    slow += frame(0x52, 200, gap_head=3)
    fast += frame(0xF2, 8, gap_head=40)
    # 5) fast 帧中 slow 到达: slow 等 fast 帧尾
    fast += frame(0xF3, 120, gap_head=3)
    slow += frame(0x53, 32, gap_head=30)
    # 6) 背靠背: fast 两连帧 (gap_tail=0)
    fast += frame(0xF4, 16, gap_tail=0)
    fast += frame(0xF5, 40)
    # 7) 交替 slow/fast
    slow += frame(0x54, 24)
    fast += frame(0xF6, 24)
    # 8) 单字帧两路
    fast += frame(0xF7, 5)
    slow += frame(0x55, 7)
    return fast, slow


def trdy_at(mode, k, hw):
    if mode == 'stall':
        return 0 if k % 4 == 2 else 1
    if mode == 'hard':
        return 0 if hw[0] <= k < hw[1] else 1
    return 1


def model(fast, slow, mode, hw):
    # 两路 TB 源寄存器
    fv = 0
    fd_ = fk = fl = 0
    fi = 0
    fgap = 0
    sv = 0
    sd = sk = sl = 0
    si = 0
    sgap = 0
    # DUT 寄存器
    busy = 0
    sel_fast = 0
    lines = []
    k = 0
    while k < 100000:
        trdy = 1 if k == 0 else trdy_at(mode, k - 1, hw)
        # ---- 组合数据通路 ----
        m_tvalid = busy and (fv if sel_fast else sv)
        m_tdata = fd_ if sel_fast else sd
        m_tkeep = fk if sel_fast else sk
        m_tlast = fl if sel_fast else sl
        f_rdy = busy and sel_fast and trdy
        s_rdy = busy and (not sel_fast) and trdy
        if m_tvalid and trdy:
            lines.append('%016X %02X %d' % (m_tdata, m_tkeep, m_tlast))
        # ---- 仲裁寄存器 NBA ----
        busy_n = busy
        sel_n = sel_fast
        if not busy:
            if fv:
                busy_n = 1
                sel_n = 1
            elif sv:
                busy_n = 1
                sel_n = 0
        elif m_tvalid and trdy and m_tlast:
            busy_n = 0
        # ---- TB 源推进 (接受拍可同拍重载; 未授权保持) ----
        if (not fv) or (fv and f_rdy):
            if fgap > 0:
                fgap -= 1
                if fv:
                    fv = 0
            elif fi < len(fast):
                fd_, fk, fl, fgap = fast[fi]
                fv = 1
                fi += 1
            elif fv:
                fv = 0
        if (not sv) or (sv and s_rdy):
            if sgap > 0:
                sgap -= 1
                if sv:
                    sv = 0
            elif si < len(slow):
                sd, sk, sl, sgap = slow[si]
                sv = 1
                si += 1
            elif sv:
                sv = 0
        busy = busy_n
        sel_fast = sel_n
        k += 1
        if fi >= len(fast) and si >= len(slow) and not fv and not sv and not busy \
                and k > 400:
            break
    return lines


def w32(fn, vals, fmt='%X'):
    with open(fn, 'w') as fh:
        fh.write('\n'.join(fmt % x for x in vals) + '\n')


def generate(simdir):
    fast, slow = build_streams()
    hw0, hw1 = 60, 130
    for tag, ws in (('fa', fast), ('sa', slow)):
        w32(os.path.join(simdir, '%s_data.memh' % tag), [x[0] for x in ws],
            '%016X')
        w32(os.path.join(simdir, '%s_keep.memh' % tag), [x[1] for x in ws], '%02X')
        w32(os.path.join(simdir, '%s_last.memh' % tag), [x[2] for x in ws])
        w32(os.path.join(simdir, '%s_gap.memh' % tag), [x[3] for x in ws], '%X')
        with open(os.path.join(simdir, '%s_nstim.memh' % tag), 'w') as fh:
            fh.write('%X\n' % len(ws))
    with open(os.path.join(simdir, 'hardwin_ta.memh'), 'w') as fh:
        fh.write('%X\n%X\n' % (hw0, hw1))
    for mode in ('nostall', 'stall', 'hard'):
        lines = model(fast, slow, mode, (hw0, hw1))
        with open(os.path.join(simdir, 'exp_ta_%s.memh' % mode), 'w') as fh:
            for ln in lines:
                fh.write(ln + '\n')
        print('%s: %d words' % (mode, len(lines)))
    # 独立参考 (帧级): 逐帧 (来源, 内容) — nostall 词流按帧重组后逐路顺序比对
    exp_lines = [l.strip() for l in
                 open(os.path.join(simdir, 'exp_ta_nostall.memh'))]
    # 每路词序必须等于该路输入词序 (帧不被撕); 首字节 [63:56] = 源标识
    for tag, ws, fid in (('fast', fast, 0xF0), ('slow', slow, 0x50)):
        got = [l for l in exp_lines
               if (int(l.split()[0], 16) >> 56) >= fid and
               (int(l.split()[0], 16) >> 56) < fid + 0x10]
        want = ['%016X %02X %d' % (d, kk, l) for d, kk, l, g in ws]
        got_n = ['%016X %02X %d'.lower() % (int(l.split()[0], 16), int(l.split()[1], 16),
                                    int(l.split()[2]))
                 for l in got]
        assert [x.lower() for x in got_n] == [w.lower() for w in want], \
            '%s stream words torn: %d != %d' % (tag, len(got_n), len(want))
    print('xref OK: per-source word order intact')


def check(simdir):
    ok_all = True
    for mode in ('nostall', 'stall', 'hard'):
        exp = [l.strip().lower() for l in
               open(os.path.join(simdir, 'exp_ta_%s.memh' % mode)) if l.strip()]
        fn = os.path.join(simdir, 'resp_ta_%s.memh' % mode)
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
    print('tb_tx_arb: %s' % ('PASS' if ok_all else 'FAIL'))
    return ok_all


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else '.'
    if '--check' in sys.argv:
        sys.exit(0 if check(simdir) else 1)
    generate(simdir)
