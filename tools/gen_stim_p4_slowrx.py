#!/usr/bin/env python
"""slow_rx_adp xsim 刺激生成 + 周期精确参考模型 (规范驱动)。

DUT 规范: 64bit 字流 -> frame_fifo 整帧缓冲 (snap@SOP; tlast 拍若 tcrs&&!terr
&&!abort&&!full 则 commit, 否则 rollback; 单字 SOP&tlast runt 静默丢; s_tready=1,
fifo 满吞字打 abort) -> 字节播放器 (8B 前导 55*7+D5 + 内容字节, tlast 在最后内容
字节, 无 FCS) -> 2048x9 fifo -> hls_rx {7'b0,tlast,byte}, 接受拍出流。
stat_commit/stat_drop。

三模式: nostall / stall (hls_rx_tready 3高1低) / hard (硬停窗)。
用法: python gen_stim_p4_slowrx.py <simdir> [--check]
"""
import os
import sys

P_IDLE, P_PRE, P_LOAD, P_EMIT = 0, 1, 2, 3


def keep2n(k):
    n = 0
    for i in range(8):
        if (k >> (7 - i)) & 1:
            n = i + 1
    return max(n, 1)


def mk_frame(nbytes, crs=1, err=0, gap0=2, fill=None):
    b = bytearray(nbytes)
    for i in range(nbytes):
        b[i] = ((i * 5 + 1) & 0xFF) if fill is None else fill[i]
    words = []
    nw = (nbytes + 7) // 8
    for wi in range(nw):
        chunk = bytes(b[wi * 8:(wi + 1) * 8])
        data = int.from_bytes(chunk.ljust(8, b'\x00'), 'big')
        keep = (0xFF << (8 - len(chunk))) & 0xFF
        last = 1 if wi == nw - 1 else 0
        words.append((data, keep, last, 1 if wi == 0 else 0,
                      crs if last else 0, err if last else 0,
                      gap0 if wi == 0 else 0))
    return words, bytes(b)


def build_stream_wd():
    """看门狗测试刺激: 单 60B 帧 (o_fifo 有数据 + 永久不读 -> 饥饿超时)。"""
    w, b = mk_frame(60)
    return w, [('commit', b)]


def build_stream():
    """返回 (字流, 帧内容列表 [(commit?, content_bytes)] 按输入序)。"""
    words = []
    frames = []

    def add(nbytes, crs=1, err=0, gap0=2, expect='commit'):
        w, b = mk_frame(nbytes, crs, err, gap0)
        words.extend(w)
        frames.append((expect, b))

    for ln in (9, 15, 16, 17, 23, 24, 25, 31, 32, 33, 60, 64, 100, 500, 1522):
        add(ln)                                   # 15 个好帧 (全 tkeep 余数)
    add(30, crs=0, expect='drop')                 # 坏 FCS -> rollback
    add(40)                                       # 回卷后首帧必须干净
    add(30, err=1, expect='drop')                 # rx_er -> rollback
    add(40)
    add(8, expect='drop')                         # 单字 runt 静默丢
    add(40)
    add(40, gap0=0)                               # 背靠背 x3
    add(40, gap0=0)
    add(40, gap0=0)
    add(4200, gap0=4000, expect='drop')           # >511 字: fifo 满吞+abort
    add(40, gap0=2)
    return words, frames


def trdy_at(mode, k, hw):
    if mode == 'stall':
        return 0 if k % 4 == 2 else 1
    if mode == 'hard':
        return 0 if hw[0] <= k < hw[1] else 1
    if mode == 'wd':
        return 0                            # 全程不读: 首个字节落地即开始饥饿
    return 1


WDOG = 1000           # 与 tb_slow_rx 的 DUT 参数一致
OCC_GATE = 256        # 开播节流阈值 (与 RTL 一致)


class Ffifo(object):
    """frame_fifo(73, 512, 9) 周期语义。"""

    def __init__(self):
        self.mem = [0] * 512
        self.wptr = 0
        self.rptr = 0
        self.wsnap = 0
        self.dout = 0

    def full(self):
        # 与 RTL 一致 (frame_fifo 已修为 fifo_sync 同式: 真满 = 低位同+绕回位异)
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
        wptr_pre = self.wptr          # snap 快照 = 本拍写槽 (增量前的 wptr)
        if wr_ok:
            self.mem[self.wptr & 0x1FF] = din
        if rollbk:
            self.wptr = self.wsnap    # 回卷读的是旧 wsnap (与 snap 不同拍语义)
        else:
            self.wptr = self.wptr + (1 if wr_ok else 0)
        if rd_ok:
            self.rptr = rptr_n
        self.dout = din if bypass else self.mem[rptr_n & 0x1FF]
        if snap:
            self.wsnap = wptr_pre
        return


class Sfifo(object):
    """fifo_sync(9, 2048, 11) 周期语义。"""

    def __init__(self):
        self.mem = [0] * 2048
        self.wptr = 0
        self.rptr = 0
        self.dout = 0

    def full(self):
        return ((self.wptr & 0x7FF) == (self.rptr & 0x7FF)) and \
               ((self.wptr >> 11) != (self.rptr >> 11))

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
        if wr_ok:
            self.wptr += 1
        if rd_ok:
            self.rptr = rptr_n
        self.dout = din if bypass else self.mem[rptr_n & 0x7FF]


def model(words, mode, hw):
    # TB 源寄存器
    v = 0
    d = kk = l = u = c = e = 0
    idx_src = 0
    gap = 0
    nstim = len(words)
    # DUT 寄存器
    ff = Ffifo()
    of = Sfifo()
    abort = 0
    in_frame = 0
    resync_drop = 0
    committed = 0
    stat_commit = 0
    stat_drop = 0
    pstate = P_IDLE
    pre_cnt = 0
    wreg = 0
    wlast = 0
    nb = 8
    bidx = 0
    ff_rd = 0
    o_wr = 0
    o_din = 0
    occ = 0                 # o_fifo 占用 (写-读滚动, 与 RTL 同步)
    starv = 0               # 看门狗饥饿计数
    rst_cnt = 0             # 复位脉冲计数
    hls_rst_n = 1
    wd_fire_k = -1          # wd 模式: 首个复位脉冲拍
    lines = []
    k = 0
    while k < 200000:
        trdy = 1 if k == 0 else trdy_at(mode, k - 1, hw)
        ff_full = ff.full()
        ff_empty = ff.empty()
        o_full = of.full()
        o_empty = of.empty()
        # ---- 输入侧组合 (与 RTL 逐式一致, 含 in_frame/resync_drop) ----
        s_acc = v                       # s_tready == 1
        sop_any = s_acc and u
        sop_multi = sop_any and (not l)
        sop_1w = sop_any and l
        trunc_evt = sop_any and in_frame
        ff_wr = (s_acc and not resync_drop and not sop_1w and not trunc_evt
                 and not abort and not ff_full)
        ff_snap = 1 if (sop_multi and not in_frame and not resync_drop) else 0
        frame_end = s_acc and l and not u and not resync_drop
        frame_bad = abort or ff_full or (not c) or e
        do_commit = frame_end and not frame_bad
        do_rollbk = (frame_end and frame_bad) or trunc_evt
        ff_din = (l << 72) | (kk << 64) | d
        # ---- 输出侧组合 (hls_rx) ----
        hls_tvalid = not o_empty
        rd_o = hls_tvalid and trdy
        if rd_o:
            lines.append('%04X' % (of.dout & 0x1FF))
        # ---- NBA 计算 ----
        abort_n = abort
        in_frame_n = in_frame
        resync_drop_n = resync_drop
        pstate_n, pre_cnt_n = pstate, pre_cnt
        wreg_n, wlast_n, nb_n, bidx_n = wreg, wlast, nb, bidx
        ff_rd_n, o_wr_n, o_din_n = 0, 0, o_din
        if ff_snap:
            in_frame_n = 1
        if frame_end:
            in_frame_n = 0
            abort_n = 0
            if frame_bad:
                stat_drop += 1
            else:
                stat_commit += 1
        if trunc_evt:
            in_frame_n = 0
            abort_n = 0
            stat_drop += 1
            if not l:
                resync_drop_n = 1
        elif resync_drop and s_acc and l:
            resync_drop_n = 0
        if (s_acc and (not u) and ff_full and not abort and in_frame
                and (not l)):
            abort_n = 1
        if ff_snap and ff_full:
            abort_n = 1
        if sop_1w and (not in_frame) and (not resync_drop):
            stat_drop += 1
        # 播放器 (开播节流: occ > 256 不开新帧, 与 RTL 一致)
        if pstate == P_IDLE:
            if committed != 0 and occ <= OCC_GATE:
                pstate_n = P_PRE
                pre_cnt_n = 0
        elif pstate == P_PRE:
            if not o_full:
                o_wr_n = 1
                o_din_n = 0x0D5 if pre_cnt == 7 else 0x055
                if pre_cnt == 7:
                    pstate_n = P_LOAD
                pre_cnt_n = (pre_cnt + 1) & 7
        elif pstate == P_LOAD:
            if not ff_empty:
                wreg_n = ff.dout & 0xFFFFFFFFFFFFFFFF
                wlast_n = (ff.dout >> 72) & 1
                nb_n = keep2n((ff.dout >> 64) & 0xFF)
                bidx_n = 0
                ff_rd_n = 1
                pstate_n = P_EMIT
        else:  # P_EMIT
            if not o_full:
                cur = (wreg >> (56 - 8 * (bidx & 7))) & 0xFF
                last_byte = 1 if (wlast and bidx == nb - 1) else 0
                o_wr_n = 1
                o_din_n = (last_byte << 8) | cur
                if bidx == nb - 1:
                    if wlast:
                        pstate_n = P_IDLE
                    else:
                        pstate_n = P_LOAD
                bidx_n = (bidx + 1) & 0xF
        # committed: +1 commit / -1 开播 (P_IDLE 开播拍即减, 与 RTL 一致)
        start_play = (pstate == P_IDLE) and (committed != 0) and (occ <= OCC_GATE)
        if do_commit and not start_play:
            committed += 1
        elif (not do_commit) and start_play:
            committed -= 1
        # o_fifo 占用 (写=旧 o_wr 且未满, 读=rd_o) — 与 RTL occ 同拍
        occ = occ + (1 if o_wr else 0) - (1 if rd_o else 0)
        # 看门狗 (与 RTL 同逻辑): starve = tvalid && !tready 持续 WDOG 拍 ->
        # hls_rst_n 拉 64 拍。WDRST 行进 exp/resp 比对。
        starve = 1 if ((not o_empty) and not trdy) else 0
        if rst_cnt != 0:
            if rst_cnt == 1:                 # 先判后减 (RTL: 判旧值, NBA 减)
                hls_rst_n = 1
                lines.append('WDRST 1 %d' % (k + 1))   # 沿可见性晚 1 拍
            rst_cnt -= 1
            starv = 0
        elif starve:
            if starv >= WDOG:
                starv = 0
                rst_cnt = 64
                hls_rst_n = 0
                lines.append('WDRST 0 %d' % (k + 1))
                wd_fire_k = k
            else:
                starv += 1
        else:
            starv = 0
        # ---- 提交 NBA ----
        abort = abort_n
        in_frame = in_frame_n
        resync_drop = resync_drop_n
        pstate, pre_cnt = pstate_n, pre_cnt_n
        wreg, wlast, nb, bidx = wreg_n, wlast_n, nb_n, bidx_n
        ff.step(ff_wr, ff_din, ff_snap, do_rollbk, ff_rd)
        of.step(o_wr, o_din, rd_o)
        ff_rd = ff_rd_n
        o_wr = o_wr_n
        o_din = o_din_n
        # ---- TB 源 (tready==1) ----
        if v:
            v = 0
        if not v:
            if gap > 0:
                gap -= 1
            elif idx_src < nstim:
                d, kk, l, u, c, e, g0 = words[idx_src]
                v = 1
                gap = g0
                idx_src += 1
        # wd 模式: 首个复位脉冲后 100 拍收尾 (TB: wait(done)->wait(脉冲)->+100)
        if (mode == 'wd' and wd_fire_k >= 0 and k > wd_fire_k + 100
                and idx_src >= nstim and not v):
            break
        k += 1
        if (idx_src >= nstim and not v and pstate == P_IDLE and committed == 0
                and of.empty() and k > 400):
            break
    return lines, stat_commit, stat_drop


def generate(simdir):
    words, frames = build_stream()
    hw0, hw1 = 300, 360

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % x for x in vals) + '\n')
    w('sr_data.memh', [x[0] for x in words], '%016X')
    w('sr_keep.memh', [x[1] for x in words], '%02X')
    w('sr_last.memh', [x[2] for x in words], '%X')
    w('sr_user.memh', [x[3] for x in words], '%X')
    w('sr_crs.memh', [x[4] for x in words], '%X')
    w('sr_err.memh', [x[5] for x in words], '%X')
    w('sr_gap.memh', [x[6] for x in words], '%X')
    with open(os.path.join(simdir, 'sr_nstim.memh'), 'w') as fh:
        fh.write('%X\n' % len(words))
    with open(os.path.join(simdir, 'hardwin_sr.memh'), 'w') as fh:
        fh.write('%X\n%X\n' % (hw0, hw1))
    # wd 模式独立刺激 (单帧 — 与泛洪刺激混用会让看门狗反复触发, 比对窗口不定)
    wd_words, _ = build_stream_wd()
    w('sr_wd_data.memh', [x[0] for x in wd_words], '%016X')
    w('sr_wd_keep.memh', [x[1] for x in wd_words], '%02X')
    w('sr_wd_last.memh', [x[2] for x in wd_words], '%X')
    w('sr_wd_user.memh', [x[3] for x in wd_words], '%X')
    w('sr_wd_crs.memh',  [x[4] for x in wd_words], '%X')
    w('sr_wd_err.memh',  [x[5] for x in wd_words], '%X')
    w('sr_wd_gap.memh',  [x[6] for x in wd_words], '%X')
    with open(os.path.join(simdir, 'sr_wd_nstim.memh'), 'w') as fh:
        fh.write('%X\n' % len(wd_words))
    for mode in ('nostall', 'stall', 'hard', 'wd'):
        wds = wd_words if mode == 'wd' else words
        lines, sc, sd = model(wds, mode, (hw0, hw1))
        with open(os.path.join(simdir, 'exp_sr_%s.memh' % mode), 'w') as fh:
            for ln in lines:
                fh.write(ln + '\n')
            fh.write('STATS %d %d\n' % (sc, sd))
        print('%s: %d bytes, commit=%d drop=%d' % (mode, len(lines), sc, sd))
    # 独立参考 (字节级): 直接由帧定义重算, 交叉验证模型
    ref = []
    for expect, b in frames:
        if expect == 'commit':
            ref.extend([0x55] * 7 + [0xD5])
            ref.extend(b)
    ncommit = sum(1 for e, _ in frames if e == 'commit')
    exp_lines = [l for l in open(os.path.join(simdir, 'exp_sr_nostall.memh'))]
    exp_bytes = [int(x, 16) & 0xFF for x in exp_lines if not x.startswith('STATS')]
    assert exp_bytes == ref, 'model byte stream != independent ref'
    tlasts = [i for i, x in enumerate(exp_lines) if not x.startswith('STATS')
              and (int(x, 16) >> 8) & 1]
    exp_tlast = []
    acc = 0
    for expect, b in frames:
        if expect == 'commit':
            acc += 8 + len(b)
            exp_tlast.append(acc - 1)
    assert tlasts == exp_tlast, 'tlast positions != ref'
    print('xref OK: %d commits, %d bytes, tlast@%d frames' %
          (ncommit, len(ref), len(exp_tlast)))
    return words


def check(simdir):
    ok_all = True
    for mode in ('nostall', 'stall', 'hard', 'wd'):
        exp = [l.strip().lower() for l in
               open(os.path.join(simdir, 'exp_sr_%s.memh' % mode)) if l.strip()]
        fn = os.path.join(simdir, 'resp_sr_%s.memh' % mode)
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
    print('tb_slow_rx: %s' % ('PASS' if ok_all else 'FAIL'))
    return ok_all


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else '.'
    if '--check' in sys.argv:
        sys.exit(0 if check(simdir) else 1)
    generate(simdir)
