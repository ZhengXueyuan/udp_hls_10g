#!/usr/bin/env python
"""mac_tx_64 xsim 刺激生成 + 周期精确期望模型。

模式 main:  60B 帧 (无 pad) + 42B 帧 (pad 4) + 8B 帧 (pad 38), 背靠背。
模式 abort: 仅 1 词 + 长空窗 10000 拍 -> 欠载中止 (runt 无 FCS); 残余 2 词开新帧。
   (欠载点严格确定: FIFO 只装过 1 词, 无容量博弈)
期望模型与 RTL 1:1 (16 词 FIFO / TB 握手 / TX 状态机 / 欠载中止)。
"""
import struct
import zlib
import os
import sys

PRE = bytes([0x55] * 7 + [0xD5])
MIN_PLEN = 46
FIFO_D = 16


def words_of(payload):
    ws = []
    for k in range(0, len(payload), 8):
        chunk = payload[k:k + 8]
        w = int.from_bytes(chunk.ljust(8, b"\x00"), "big")
        keep = (0xFF << (8 - len(chunk))) & 0xFF
        last = (k + 8 >= len(payload))
        ws.append((w, keep, last))
    return ws


def build_script(mode="main"):
    """返回 script 行列表: ('W', data, keep, last) / ('GAP', n)。"""
    script = []
    if mode == "main":
        for payload in (bytes(range(60)), bytes(range(42)), bytes(range(8))):
            for w in words_of(payload):
                script.append(('W',) + w)
    else:  # abort
        ws4 = words_of(bytes(range(24)))
        script.append(('W',) + ws4[0])
        script.append(('GAP', 10000))   # 远大于排空时间 -> 欠载点严格确定
        script.append(('W',) + ws4[1])
        script.append(('W',) + ws4[2])
    return script


def crc_step(c, b):
    for _ in range(8):
        c = (c >> 1) ^ 0xEDB88320 if (c ^ b) & 1 else c >> 1
        b >>= 1
    return c & 0xFFFFFFFF


def model(script, maxc=30000):
    """与 RTL+TB 1:1 的周期模型。返回 [(en, byte), ...] 与帧字节列表。"""
    fifo = []
    si = 0
    gap = 0
    tvalid = False
    presenting = False
    tdata = tkeep = tlast = 0
    state = 'IDLE'
    pre = 0
    cw = None          # (data, keep, last)
    idx = 0
    plen = 0
    pad = 0
    fcs_shr = 0
    fcs_cnt = 0
    ifg = 0
    crc = 0xFFFFFFFF
    out = []
    frames = []
    fbuf = []
    aborted = False

    for _ in range(maxc):
        # 本拍状态快照 (分支会改 state, CRC 更新须用本拍值, 与 RTL 组合 crc_en/crc_init 一致)
        cur_state = state
        is_d5 = (cur_state == 'PRE' and pre == 7)
        # ---- TB (RTL 非阻塞语义: 本拍可见信号 = 上拍计算值; 本拍计算下拍才生效) ----
        tready = len(fifo) < FIFO_D
        if tvalid and tready:
            fifo.append((tdata, tkeep, tlast))
        if gap > 0:
            gap_n = gap - 1
            presenting_n = False
            tvalid_n = False
            si_n = si
            tdata_n, tkeep_n, tlast_n = tdata, tkeep, tlast
        elif not presenting:
            if si < len(script):
                s = script[si]
                if s[0] == 'W':
                    tdata_n, tkeep_n, tlast_n = s[1], s[2], s[3]
                    presenting_n = True
                    tvalid_n = True
                    si_n = si + 1
                    gap_n = 0
                else:
                    tvalid_n = False
                    presenting_n = False
                    gap_n = s[1] - 1
                    si_n = si + 1
                    tdata_n, tkeep_n, tlast_n = tdata, tkeep, tlast
            else:
                tvalid_n = False
                presenting_n = False
                gap_n = 0
                si_n = si
                tdata_n, tkeep_n, tlast_n = tdata, tkeep, tlast
        else:  # presenting
            if tvalid and tready:
                presenting_n = False
                tvalid_n = False
            else:
                presenting_n = True
                tvalid_n = True
            gap_n = 0
            si_n = si
            tdata_n, tkeep_n, tlast_n = tdata, tkeep, tlast
        tvalid, presenting, gap, si = tvalid_n, presenting_n, gap_n, si_n
        tdata, tkeep, tlast = tdata_n, tkeep_n, tlast_n

        # ---- TX FSM ----
        if state == 'IDLE':
            en, txd = 0, 0x07
            if fifo:
                state, pre = 'PRE', 0
        elif state == 'PRE':
            en = 1
            if pre == 7:
                txd = 0xD5
                if fifo:
                    cw = fifo.pop(0)
                    idx = 0
                    plen = 0
                    state = 'DATA'
                else:
                    state, ifg, cw = 'IFG', 0, None
            else:
                txd = 0x55
                pre += 1
        elif state == 'DATA':
            en, txd = 1, (cw[0] >> (56 - 8 * idx)) & 0xFF
            plen += 1
            clen = bin(cw[1]).count('1')
            if idx == clen - 1:
                if cw[2]:
                    if plen >= MIN_PLEN:
                        state, fcs_cnt = 'FCS', 0
                        fcs_shr = crc_step(crc, txd) ^ 0xFFFFFFFF
                    else:
                        state = 'PAD'
                        pad = MIN_PLEN - plen
                elif fifo:
                    cw = fifo.pop(0)
                    idx = 0
                else:
                    # 中止: 本拍末字节照常发出 (RTL 组合 txd 语义), 帧冲刷放到字节入账后
                    state, cw = 'IDLE', None
                    aborted = True
            else:
                idx += 1
        elif state == 'PAD':
            en, txd = 1, 0x00
            if pad == 1:
                state, fcs_cnt = 'FCS', 0
                fcs_shr = crc_step(crc, 0x00) ^ 0xFFFFFFFF
            else:
                pad -= 1
        elif state == 'FCS':
            en, txd = 1, fcs_shr & 0xFF
            if fcs_cnt == 3:
                state, ifg = 'IFG', 0
            else:
                fcs_cnt += 1
                fcs_shr >>= 8
        elif state == 'IFG':
            en, txd = 0, 0x07
            if ifg == 11:
                state = 'IDLE'
                if fbuf:
                    frames.append(bytes(fbuf))
                    fbuf = []
            else:
                ifg += 1
        else:
            en, txd = 0, 0x07

        if is_d5:
            crc = 0xFFFFFFFF
        elif cur_state in ('DATA', 'PAD'):
            crc = crc_step(crc, txd)
        if en:
            fbuf.append(txd)
        if aborted:
            frames.append(bytes(fbuf))
            fbuf = []
            aborted = False
        out.append((en, txd))

        # 结束条件: 刺激发完且回 IDLE 且 FIFO 空
        if si >= len(script) and not tvalid and not fifo and state == 'IDLE' and len(out) > 100:
            break
    return out, frames


def write_stim(simdir, script):
    ty, d, k, l, n = [], [], [], [], []
    for s in script:
        if s[0] == 'W':
            ty.append(1); d.append(s[1]); k.append(s[2]); l.append(s[3]); n.append(0)
        else:
            ty.append(0); d.append(0); k.append(0); l.append(0); n.append(s[1])
    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('tx_ty.memh',   ty, '%X')     # $readmemh 按十六进制解析, 必须写 hex
    w('tx_data.memh', d,  '%016X')
    w('tx_keep.memh', k,  '%02X')
    w('tx_last.memh', l,  '%X')
    w('tx_gap.memh',  n,  '%X')


def write_expected(simdir, out, frames):
    """期望 GMII 流: 每行 'en byte'; 帧字节列表单独文件。"""
    with open(os.path.join(simdir, 'expected_tx.memh'), 'w') as fh:
        fh.write('\n'.join('%d %02X' % (en, b) for en, b in out) + '\n')
    with open(os.path.join(simdir, 'expected_frames.txt'), 'w') as fh:
        for f in frames:
            fh.write(f.hex().upper() + '\n')


def generate(simdir, mode="main"):
    script = build_script(mode)
    out, frames = model(script)
    write_stim(simdir, script)
    write_expected(simdir, out, frames)
    n_complete = sum(1 for f in frames if len(f) >= 58)   # 前导8+payload>=46+FCS4
    with open(os.path.join(simdir, "expected_tx_stats.txt"), "w") as fh:
        fh.write("%d %d\n" % (n_complete, len(frames) - n_complete))
    return frames


if __name__ == '__main__':
    frames = generate(sys.argv[1] if len(sys.argv) > 1 else 'sim')
    for i, f in enumerate(frames):
        print('frame %d: %d bytes, FCS=%s' % (i, len(f), f[-4:].hex().upper()))
