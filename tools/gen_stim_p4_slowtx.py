#!/usr/bin/env python
"""slow_tx_adp xsim 刺激生成 + 周期精确参考模型 (规范驱动)。

DUT 规范: HLS 字节流 (tdata={6'b0,tlast,byte}, 帧 = 7*0x55+0xD5 前导 + 内容 +
4B FCS, tlast 在末 FCS 字节) -> 9bit 输入 fifo -> 字节 FSM (T_IDLE 窥首字节不弹/
T_PRE 剥前导: 跳 0x55 (cnt<15), 见 0xD5 且 cnt>=4 进 T_DATA, 其他 ->T_PURGE 吞到
tlast 回卷 / T_DATA: 4 字节回持剥 FCS + 索引直写打包左对齐字, in_last 拍毕业字节
直接合成末字带 tlast) -> frame_fifo 整帧缓冲 (snap@T_IDLE->T_PRE 拍, commit@
in_last 且 hc==4 且 !abort 且 !wf_full, 否则 rollback) -> 播放器 (O_IDLE 开播拍
committed-1, O_SEND 逐字, rd 组合) -> m_axis 字流。
stat_frames / stat_purge。

三模式: nostall / stall (m_axis_tready 3高1低) / hard (硬停窗)。
TB 源语义: 每拍 (v,d,l) 有效则写入 ififo (tready=!full 恒成立); gap 跟随该字节。
用法: python gen_stim_p4_slowtx.py <simdir> [--check]
"""
import os
import sys

T_IDLE, T_PRE, T_DATA, T_PURGE = 0, 1, 2, 3
O_IDLE, O_SEND = 0, 1


def mk_hls_frame(content, pre_55=7, bad_pre=False):
    if bad_pre:
        pre = [0x55] * pre_55 + [0x12]        # 无 D5 -> purge
    else:
        pre = [0x55] * pre_55 + [0xD5]
    return pre + list(content) + [0xDE, 0xAD, 0xBE, 0xEF]


def build_stream():
    """(字节流 [(data,last,gap)], 帧期望 [(want, content_bytes)])。"""
    stream = []
    expect = []

    def add(content, pre_55=7, bad_pre=False, gap_head=3, bubble=0,
            want='frames'):
        fb = mk_hls_frame(content, pre_55, bad_pre)
        for j, b in enumerate(fb):
            last = 1 if j == len(fb) - 1 else 0
            if j == 0:
                g = gap_head
            elif bubble and j % 3 == 0:
                g = bubble
            else:
                g = 0
            stream.append((b, last, g))
        expect.append((want, bytes(content)))

    for n in (1, 2, 3, 4, 5, 6, 7, 8, 9, 42, 60, 100, 300):
        add([(i * 5 + 1) & 0xFF for i in range(n)])
    add([0xAB] * 10, pre_55=10)                    # 长前导
    add([0xCD] * 20, bad_pre=True, want='purge')   # 无 D5 -> purge
    add([0xEF] * 16)                               # purge 后首帧必须干净
    add([(i * 3 + 7) & 0xFF for i in range(24)], bubble=2)   # 帧内空洞
    add([0x11] * 33, gap_head=0)                   # 背靠背 x3
    add([0x22] * 33, gap_head=0)
    add([0x33] * 33, gap_head=0)
    return stream, expect


def trdy_at(mode, k, hw):
    if mode == 'stall':
        return 0 if k % 4 == 2 else 1
    if mode == 'hard':
        return 0 if hw[0] <= k < hw[1] else 1
    return 1


class Ffifo(object):
    """frame_fifo(73, 512, 9) — 与 RTL 同式 (full = 低位同+绕回位异)。"""

    def __init__(self):
        self.mem = [0] * 512
        self.wptr = 0
        self.rptr = 0
        self.wsnap = 0
        self.dout = 0

    def full(self):
        return ((self.wptr & 0x1FF) == (self.rptr & 0x1FF)) and \
               ((self.wptr >> 9) & 1) != ((self.rptr >> 9) & 1)

    def empty(self):
        return self.wptr == self.rptr

    def step(self, wr, din, snap, rollbk, rd):
        full = self.full()
        empty = self.empty()
        rd_ok = rd and not empty
        wr_ok = wr and not full
        rptr_n = self.rptr + (1 if rd_ok else 0)
        bypass = wr_ok and ((rptr_n & 0x1FF) == (self.wptr & 0x1FF))
        wptr_pre = self.wptr
        if wr_ok:
            self.mem[self.wptr & 0x1FF] = din
        if rollbk:
            self.wptr = self.wsnap
        else:
            self.wptr = self.wptr + (1 if wr_ok else 0)
        if rd_ok:
            self.rptr = rptr_n
        self.dout = din if bypass else self.mem[rptr_n & 0x1FF]
        if snap:
            self.wsnap = wptr_pre


class Sfifo(object):
    """fifo_sync(9, 2048, 11)。"""

    def __init__(self):
        self.mem = [0] * 2048
        self.wptr = 0
        self.rptr = 0
        self.dout = 0

    def full(self):
        return ((self.wptr & 0x7FF) == (self.rptr & 0x7FF)) and \
               ((self.wptr >> 11) & 1) != ((self.rptr >> 11) & 1)

    def empty(self):
        return self.wptr == self.rptr

    def step(self, wr, din, rd):
        full = self.full()
        empty = self.empty()
        rd_ok = rd and not empty
        wr_ok = wr and not full
        rptr_n = self.rptr + (1 if rd_ok else 0)
        bypass = wr_ok and ((rptr_n & 0x7FF) == (self.wptr & 0x7FF))
        if wr_ok:
            self.mem[self.wptr & 0x7FF] = din
            self.wptr += 1
        if rd_ok:
            self.rptr = rptr_n
        self.dout = din if bypass else self.mem[rptr_n & 0x7FF]


def model(stream, mode, hw):
    # TB 源寄存器 (时钟化: 本拍 (v,d,l) 有效)
    v = 0
    d = l = 0
    idx_src = 0
    gap = 0
    nstim = len(stream)
    # DUT 寄存器
    ififo = Sfifo()
    wf = Ffifo()
    tstate = T_IDLE
    skip_cnt = 0
    hold = [0, 0, 0, 0]     # hold[0] 最老
    hc = 0
    pw = 0
    pc = 0
    abort = 0
    committed = 0
    ostate = O_IDLE
    stat_frames = 0
    stat_purge = 0
    lines = []
    k = 0
    while k < 300000:
        trdy = 1 if k == 0 else trdy_at(mode, k - 1, hw)
        i_empty = ififo.empty()
        i_full = ififo.full()
        wf_empty = wf.empty()
        wf_full = wf.full()
        # ---- 组合: 输入 fifo 读写 ----
        i_rd = 1 if (tstate != T_IDLE and not i_empty) else 0
        i_wr = v and not i_full            # hls_tx_tready = !i_full
        in_b = ififo.dout & 0xFF
        in_last = (ififo.dout >> 8) & 1
        # ---- 组合: 输出播放器 ----
        m_tvalid = 1 if (ostate == O_SEND and not wf_empty) else 0
        wf_rd = 1 if (m_tvalid and trdy) else 0
        m_tdata = wf.dout & 0xFFFFFFFFFFFFFFFF
        m_tkeep = (wf.dout >> 64) & 0xFF
        m_tlast = (wf.dout >> 72) & 1
        if m_tvalid and trdy:
            lines.append('%016X %02X %d' % (m_tdata, m_tkeep, m_tlast))
        # ---- NBA: 字节 FSM ----
        tstate_n = tstate
        skip_n = skip_cnt
        hold_n = list(hold)
        hc_n = hc
        pw_n = pw
        pc_n = pc
        abort_n = abort
        ostate_n = ostate
        wf_wr = 0
        wf_din = 0
        wf_snap = 0
        wf_rlbk = 0
        commit_p = 0
        if tstate == T_IDLE:
            if not i_empty:
                wf_snap = 1
                skip_n = 0
                tstate_n = T_PRE
        elif tstate == T_PRE:
            if not i_empty:
                if in_b == 0x55 and skip_cnt < 15:
                    skip_n = skip_cnt + 1
                elif in_b == 0xD5 and skip_cnt >= 4:
                    hold_n = [0, 0, 0, 0]
                    hc_n = 0
                    pw_n = 0
                    pc_n = 0
                    abort_n = 0
                    tstate_n = T_DATA
                else:
                    tstate_n = T_PURGE
        elif tstate == T_DATA:
            if not i_empty:
                if hc == 4:
                    grad = hold[0]
                    if not wf_full and not abort:
                        if pc == 7:
                            wf_wr = 1
                            wf_din = ((in_last << 72) | (0xFF << 64) |
                                      (pw & 0xFFFFFFFFFFFFFF00) | grad)
                            pc_n = 0
                            pw_n = 0
                        elif in_last:
                            wf_wr = 1
                            merged = pw | (grad << (56 - 8 * pc))
                            keep = ((0xFF << (8 - (pc + 1))) & 0xFF
                                    if pc + 1 < 8 else 0xFF)
                            wf_din = (1 << 72) | (keep << 64) | merged
                        else:
                            pw_n = pw | (grad << (56 - 8 * pc))
                            pc_n = pc + 1
                    else:
                        abort_n = 1
                hold_n = hold[1:] + [in_b]
                if hc != 4:
                    hc_n = hc + 1
                if in_last:
                    if hc == 4 and not abort and not wf_full:
                        stat_frames += 1
                        commit_p = 1
                    else:
                        wf_rlbk = 1
                        stat_purge += 1
                    tstate_n = T_IDLE
        else:  # T_PURGE
            if not i_empty and in_last:
                wf_rlbk = 1
                stat_purge += 1
                tstate_n = T_IDLE
        # ---- 输出播放器状态 ----
        start_play = (ostate == O_IDLE and committed != 0 and not wf_empty)
        if ostate == O_IDLE:
            if start_play:
                ostate_n = O_SEND
        else:
            if m_tvalid and trdy and m_tlast:
                ostate_n = O_IDLE
        # committed: +1 commit / -1 开播, 同拍互抵
        if commit_p and start_play:
            pass
        elif commit_p:
            committed += 1
        elif start_play:
            committed -= 1
        # ---- 提交 NBA ----
        tstate = tstate_n
        skip_cnt = skip_n
        hold = hold_n
        hc = hc_n
        pw = pw_n
        pc = pc_n
        abort = abort_n
        ostate = ostate_n
        ififo.step(i_wr, (l << 8) | d, i_rd)
        wf.step(wf_wr, wf_din, wf_snap, wf_rlbk, wf_rd)
        # ---- TB 源推进 (与 TB 一致: 接受拍可同拍重载; 满则保持) ----
        if (not v) or (v and i_wr):
            if gap > 0:
                gap -= 1
                if v:
                    v = 0
            elif idx_src < nstim:
                d, l, gap = stream[idx_src]
                v = 1
                idx_src += 1
            elif v:
                v = 0
        k += 1
        if (idx_src >= nstim and not v and tstate == T_IDLE and committed == 0
                and ostate == O_IDLE and ififo.empty() and wf.empty() and k > 400):
            break
    return lines, stat_frames, stat_purge


def w32(fn, vals, fmt='%X'):
    with open(fn, 'w') as fh:
        fh.write('\n'.join(fmt % x for x in vals) + '\n')


def generate(simdir):
    stream, expect = build_stream()
    hw0, hw1 = 150, 230
    w32(os.path.join(simdir, 'st_data.memh'), [x[0] for x in stream], '%02X')
    w32(os.path.join(simdir, 'st_last.memh'), [x[1] for x in stream])
    w32(os.path.join(simdir, 'st_gap.memh'), [x[2] for x in stream], '%X')
    with open(os.path.join(simdir, 'st_nstim.memh'), 'w') as fh:
        fh.write('%X\n' % len(stream))
    with open(os.path.join(simdir, 'hardwin_st.memh'), 'w') as fh:
        fh.write('%X\n%X\n' % (hw0, hw1))
    for mode in ('nostall', 'stall', 'hard'):
        lines, sf, sp = model(stream, mode, (hw0, hw1))
        with open(os.path.join(simdir, 'exp_st_%s.memh' % mode), 'w') as fh:
            for ln in lines:
                fh.write(ln + '\n')
            fh.write('STATS %d %d\n' % (sf, sp))
        print('%s: %d words, frames=%d purge=%d' % (mode, len(lines), sf, sp))
    # 独立参考 (帧级): 直接由帧定义重算期望字流, 与 nostall 模型交叉
    ref = []
    for want, content in expect:
        if want != 'frames':
            continue
        nw = (len(content) + 7) // 8
        for wi in range(nw):
            chunk = content[wi * 8:(wi + 1) * 8]
            data = int.from_bytes(chunk.ljust(8, b'\x00'), 'big')
            keep = (0xFF << (8 - len(chunk))) & 0xFF
            last = 1 if wi == nw - 1 else 0
            ref.append('%016X %02X %d' % (data, keep, last))
    exp_lines = [l.strip() for l in
                 open(os.path.join(simdir, 'exp_st_nostall.memh'))
                 if not l.startswith('STATS')]
    assert exp_lines == ref, 'model word stream != independent ref'
    print('xref OK: %d words' % len(ref))


def check(simdir):
    ok_all = True
    for mode in ('nostall', 'stall', 'hard'):
        exp = [l.strip().lower() for l in
               open(os.path.join(simdir, 'exp_st_%s.memh' % mode)) if l.strip()]
        fn = os.path.join(simdir, 'resp_st_%s.memh' % mode)
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
    print('tb_slow_tx: %s' % ('PASS' if ok_all else 'FAIL'))
    return ok_all


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else '.'
    if '--check' in sys.argv:
        sys.exit(0 if check(simdir) else 1)
    generate(simdir)
