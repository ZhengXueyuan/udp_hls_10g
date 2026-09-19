#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_stim_p5_app.py — P5a app 接口门: 激励生成 + 判据 (tb_p5_app.v)

用法:
  python gen_stim_p5_app.py <simdir>            # 生成 stim_*.memh (极简空闲流)
  python gen_stim_p5_app.py <simdir> check      # 校验 resp_p5_app.memh

判据 (P5a 出口):
  ① CONN_UP 事件字逐位正确 (peer_ip/port/mac/slot/kind, 源 = slow_cfg_adp 的
     ADD 收尾授权拍)
  ② app 发 TX_BYTES (默认 1MB) 图案: 每帧载荷逐字节 == xorshift64 图案
     (偏移 = seq - (ISS+1)); seq 覆盖并集 == [ISS+1, ISS+1+TX_BYTES) 连续无洞;
     flags=0x18/doff=0x50/plen<=1460/window==0xC000/FCS 有效
  ③ 注入一个 2000B app 帧 (p5bad.memh N) ⇒ stat_drop_len 恰 1, 其后流水继续
     (并集仍完整, 无 stat_eend, 无死锁)
  ④ P4 逐帧不变量: 无合并巨帧 (ECOMAX <= 183, 每帧 plen <= 1460)、stat_eend==0、
     mac abort==0; RX 侧: 注入的 100B 图案数据段被 app 校验器逐字节比对通过
     (pat_rx_bytes == 100, pat_mismatch == 0)

退出码: 0 = 全过, 1 = 有 FAIL, 2 = 参数/文件错。
"""
import os
import struct
import sys
import zlib

TOOLS = os.path.dirname(os.path.abspath(__file__))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
import gen_stim_p4_chain as G4          # parse_gmii 复用 (有 __main__ 守卫)

MASK64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15
TX_SEGSZ = 1460
ISS = 0x12345678
SND0 = ISS + 1
PEER_ISN = 0x20000000
PEER_IP = 0xC0A86401
MY_IP = 0xC0A86402
PEER_PORT = 0x3039
MY_PORT = 0x1F90
PEER_MAC = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
DUT_MAC = G4.DUT_MAC
ISN0 = SND0                          # 首数据帧 seq


def xs_stream(n, seed=SEED):
    """xorshift64 字节流 (与 rtl/app_pattern.v / peer 对端同式):
    byte = s[31:24] 先取, 再 s ^= s<<13; s ^= s>>7; s ^= s<<17"""
    s = seed
    out = bytearray()
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s ^= (s << 13) & MASK64
        s ^= s >> 7
        s ^= (s << 17) & MASK64
    return bytes(out)


def read_bad(simdir):
    """p5bad.memh: 坏帧注入序号 (0 = 不注入)"""
    p = os.path.join(simdir, 'p5bad.memh')
    if not os.path.exists(p):
        return 0
    with open(p) as fh:
        txt = fh.read().split()
    return int(txt[0]) if txt else 0


def gen_stim(simdir):
    """极简 RX 空闲流 (256 拍): 本门 RX 流全由 TB 的 PC 模型注入。"""
    n = 256
    with open(os.path.join(simdir, 'stim_data.memh'), 'w') as f:
        f.write('07\n' * n)
    with open(os.path.join(simdir, 'stim_dv.memh'), 'w') as f:
        f.write('00\n' * n)
    with open(os.path.join(simdir, 'stim_er.memh'), 'w') as f:
        f.write('00\n' * n)
    bad = read_bad(simdir)
    print('gen_stim_p5_app: stim %d 拍空闲; bad_frame=%d' % (n, bad))
    return 0


def fcs_ok(fb):
    """捕获帧 = 8 前导 + 帧体 + 4 FCS (zlib 值小端)"""
    if len(fb) < 12:
        return False
    return int.from_bytes(fb[-4:], 'little') == (zlib.crc32(fb[8:-4]) & 0xFFFFFFFF)


def check(simdir):
    errs = []
    warns = []
    resp = os.path.join(simdir, 'resp_p5_app.memh')
    frames, ev = parse_p5(resp)
    bad = read_bad(simdir)
    tx_frames_exp = None

    # ---- 统计行 ----
    st = ev.get('p5stat')
    tx = ev.get('p5tx')
    arb = ev.get('p5arb')
    dbg = ev.get('p5dbg')
    if st is None or tx is None:
        print('FAIL: resp 缺 P5STAT/P5TX 行 (仿真未收尾?)')
        return 1
    (pat_tx_bytes, pat_tx_frames, pat_rx_bytes, pat_mismatch, pat_done,
     tx_bytes_cfg, pat_bad_frames) = st
    (txf, txb, txa, drop_len, fin, rst, eend) = tx
    bad_idx, rxdata_done = arb
    print('P5STAT tx_bytes=%d tx_frames=%d rx_bytes=%d mismatch=%d done=%d '
          'cfg_bytes=%d bad_frames=%d'
          % (pat_tx_bytes, pat_tx_frames, pat_rx_bytes, pat_mismatch, pat_done,
             tx_bytes_cfg, pat_bad_frames))
    print('P5TX frames=%d bytes=%d ack=%d drop_len=%d fin=%d rst=%d eend=%d'
          % (txf, txb, txa, drop_len, fin, rst, eend))
    print('P5ARB bad_idx=%d rxdata_done=%d' % (bad_idx, rxdata_done))
    if dbg:
        print('P5DBG scan_round=%d active=%d act_id=%d frm_seen=%d echo_seen=%d '
              'rdy0=%d ev_up=%d' % dbg)

    # ---- ① CONN_UP 事件字 (寄存器 0x00..0x04 快照) ----
    reg = ev.get('p5reg', {})
    need = [0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x09, 0x0A, 0x10, 0x11, 0x12,
            0x13, 0x50, 0x90, 0x91, 0x92, 0x9F]
    miss = [a for a in need if a not in reg]
    if miss:
        errs.append('P5REG 缺地址 %s' % [hex(a) for a in miss])
    else:
        if reg[0x00] != 0x00000000:
            errs.append('事件 FIFO 状态 0x00=%08x (期望 0x00000000: 非空且无丢弃)'
                        % reg[0x00])
        if reg[0x01] != 0x00000000:
            errs.append('事件字1 =%08x (期望 kind=0 CONN_UP / slot=0 -> 0)'
                        % reg[0x01])
        if reg[0x02] != PEER_IP:
            errs.append('事件 peer_ip=%08x != %08x' % (reg[0x02], PEER_IP))
        if reg[0x03] != ((PEER_PORT << 16) | (int.from_bytes(PEER_MAC[:2], 'big'))):
            errs.append('事件 port/mac_hi=%08x != %08x'
                        % (reg[0x03], (PEER_PORT << 16) |
                           int.from_bytes(PEER_MAC[:2], 'big')))
        if reg[0x04] != int.from_bytes(PEER_MAC[2:], 'big'):
            errs.append('事件 mac_lo=%08x != %08x'
                        % (reg[0x04], int.from_bytes(PEER_MAC[2:], 'big')))
        if reg[0x9F] != 0x50354131:
            errs.append('设计标识 0x9F=%08x != 0x50354131' % reg[0x9F])
        if reg[0x90] != 1:
            errs.append('CONN_UP 计数=%d != 1' % reg[0x90])
        if reg[0x91] != 0:
            errs.append('CONN_DOWN 计数=%d != 0' % reg[0x91])
        if reg[0x92] != 0:
            errs.append('事件丢弃计数=%d != 0' % reg[0x92])
        # 每连接块 (slot0): +0 state=1 +2 snd_nxt -- ESTAB 且 snd_nxt 已推进
        if (reg[0x10] & 0xF) != 1:
            errs.append('conn0 state=%d != 1 (ESTAB)' % (reg[0x10] & 0xF))
    # 事件源寄存器 (slow_cfg_adp 锁存保持)
    evsrc = ev.get('evsrc')
    if evsrc is None:
        errs.append('缺 EVSRC 行')
    else:
        _, eip, eport, emac, s_add, s_del = evsrc
        if eip != PEER_IP or eport != PEER_PORT or emac != int.from_bytes(PEER_MAC, 'big'):
            errs.append('EVSRC 字段不符: ip=%08x port=%04x mac=%012x'
                        % (eip, eport, emac))
        if s_add != 1 or s_del != 0:
            errs.append('slow_cfg_adp stat_add=%d stat_del=%d (期望 1/0)'
                        % (s_add, s_del))

    # ---- 帧分类 + ② 图案逐字节 ----
    pat = xs_stream(pat_tx_bytes if pat_tx_bytes else 0)
    d0 = []          # (seq, plen, payload, idx)
    acks = 0
    others = 0
    bad_fcs = 0
    for fb in frames:
        if not fcs_ok(fb):
            bad_fcs += 1
            continue
        body = fb[8:-4]
        if len(body) < 42:
            others += 1
            continue
        if body[12:14] != b'\x08\x00' or body[23] != 6:
            others += 1
            continue
        iplen, = struct.unpack('!H', body[16:18])
        sport, dport = struct.unpack('!HH', body[34:38])
        seq, ack = struct.unpack('!II', body[38:46])
        doff, flags = body[46], body[47]
        if (sport, dport) != (MY_PORT, PEER_PORT):
            others += 1
            continue
        if flags == 0x10:
            acks += 1
            continue
        if flags != 0x18:
            others += 1
            continue
        plen = iplen - 40
        if doff != 0x50:
            errs.append('数据帧 doff=%02x != 0x50 (seq=%08x)' % (doff, seq))
        if plen > TX_SEGSZ:
            errs.append('数据帧 plen=%d > %d (seq=%08x) — 合并巨帧'
                        % (plen, TX_SEGSZ, seq))
        win, = struct.unpack('!H', body[48:50])
        if win != 0xC000:
            errs.append('数据帧 window=%04x != 0xC000 (seq=%08x)' % (win, seq))
        if not (ack == PEER_ISN + 1 or ack == PEER_ISN + 1 + 100):
            errs.append('数据帧 ack=%08x 非法 (期望 %08x 或 +100)'
                        % (ack, PEER_ISN + 1))
        off = seq - ISN0
        pay = body[54:54 + plen]
        if off < 0 or off + plen > len(pat):
            errs.append('数据帧 seq=%08x plen=%d 越出 TX_BYTES 范围' % (seq, plen))
        elif pay != pat[off:off + plen]:
            k = next(i for i in range(plen) if pay[i] != pat[off + i])
            errs.append('载荷失配 seq=%08x off=%d byte[%d] got %02x exp %02x'
                        % (seq, off, k, pay[k], pat[off + k]))
        d0.append((seq, plen, off, pay))

    if bad_fcs:
        errs.append('%d 帧 FCS 无效' % bad_fcs)
    d0.sort()
    # 覆盖并集 == [ISN0, ISN0 + TX_BYTES) 连续无洞无重叠
    cov_end = ISN0
    holes = 0
    for seq, plen, off, _ in d0:
        if seq > cov_end:
            holes += 1
        cov_end = max(cov_end, seq + plen)
    total = sum(p for _, p, _, _ in d0)
    # 注入的超长帧被 RTL 帧内中止 (不上线): app 报的帧数含它, 线上不含
    exp_wire_frames = pat_tx_frames - pat_bad_frames
    print('帧分类: conn0 数据 %d 帧 / 纯 ACK %d / 其它 %d; 载荷合计 %d B; '
          '覆盖 [%08x, %08x); app 报帧 %d (坏帧 %d)'
          % (len(d0), acks, others, total, ISN0, cov_end, pat_tx_frames,
             pat_bad_frames))
    if total != pat_tx_bytes:
        errs.append('线上载荷合计 %d != app 报告 tx_bytes %d' % (total, pat_tx_bytes))
    if cov_end != ISN0 + pat_tx_bytes:
        errs.append('覆盖尾 %08x != 期望 %08x' % (cov_end, ISN0 + pat_tx_bytes))
    if holes:
        errs.append('覆盖有 %d 处空洞 (seq 间断)' % holes)
    if len(d0) != exp_wire_frames:
        errs.append('线上 conn0 数据帧 %d != app 报帧 %d - 坏帧 %d'
                    % (len(d0), pat_tx_frames, pat_bad_frames))
    exp_frames = (pat_tx_bytes + TX_SEGSZ - 1) // TX_SEGSZ
    if exp_wire_frames != exp_frames:
        errs.append('线上帧数 %d != ceil(%d/%d)=%d'
                    % (exp_wire_frames, pat_tx_bytes, TX_SEGSZ, exp_frames))

    # ---- ③ 坏帧注入 ----
    if bad_idx != 0:
        if pat_bad_frames != 1:
            errs.append('app 未注入坏帧 (stat_bad_frames=%d, 序号 %d)'
                        % (pat_bad_frames, bad_idx))
        if drop_len != 1:
            errs.append('stat_drop_len=%d != 1 (坏帧序号 %d 未触发帧内中止)'
                        % (drop_len, bad_idx))
        else:
            print('坏帧守卫: stat_drop_len=1 (注入序号 %d), 其后流水继续 '
                  '(线上 %d 帧 / %d B 连续无洞)'
                  % (bad_idx, len(d0), total))
    else:
        if drop_len != 0:
            errs.append('stat_drop_len=%d != 0 (无注入却有超长帧中止)' % drop_len)
        if pat_bad_frames != 0:
            errs.append('stat_bad_frames=%d != 0 (无注入)' % pat_bad_frames)

    # ---- ④ 不变量 ----
    if eend != 0:
        errs.append('stat_eend=%d != 0 (S_PAY 欠载)' % eend)
    smac = ev.get('smac')
    if smac is None:
        errs.append('缺 STATS_MAC 行')
    else:
        mf, abort, eend2 = smac
        if abort != 0:
            errs.append('mac abort=%d != 0' % abort)
        if eend2 != 0:
            errs.append('STATS_MAC 行 eend=%d != 0' % eend2)
        if mf == 0:
            errs.append('mac 上线帧数 0')
    ecomax = ev.get('ecomax')
    # 注入超长帧门: 那一帧本身 2000B (= 250 beat) 无 tlast, ECOMAX 上限放宽到
    # 249; 其余情况 (含无注入) 上限 = 1460B 帧的 182 非尾词 + 1 = 183
    eco_lim = 249 if pat_bad_frames else 183
    if ecomax is None:
        errs.append('缺 ECOMAX 行')
    elif ecomax > eco_lim:
        errs.append('ECOMAX=%d > %d (帧器输入出现合并巨帧)'
                    % (ecomax, eco_lim))
    # RX: 注入的 100B 图案数据段
    if rxdata_done:
        if pat_rx_bytes != 100:
            errs.append('app RX 收到 %d B != 100 (TB 注入数据段)'
                        % pat_rx_bytes)
        if pat_mismatch != 0:
            errs.append('app RX 图案失配 %d 字节 (期望 0)' % pat_mismatch)
        print('app RX: 收到 %d B, 失配 %d 字节' % (pat_rx_bytes, pat_mismatch))
    else:
        # W5: 不得静默降级 — RX 校验子判据必须真的跑到
        errs.append('TB 未注入 RX 数据段 (rxdata_done=0): app RX 逐字节校验 '
                    '子判据未成立 (检查 p5rx.memh 触发点 vs 实发帧数)')
    if pat_tx_bytes != tx_bytes_cfg:
        errs.append('app 报告 tx_bytes %d != TB TX_BYTES %d'
                    % (pat_tx_bytes, tx_bytes_cfg))
    if not pat_done:
        errs.append('app 未完成 (pat_done=0) — 传输未达 TX_BYTES')

    for w in warns:
        print('WARN: %s' % w)
    if errs:
        print('')
        for e in errs:
            print('MISMATCH: %s' % e)
        print('P5 APP FAIL (%d 项)' % len(errs))
        return 1
    print('P5 APP OK')
    return 0


def parse_p5(fn):
    """resp_p5_app.memh: 字节行 ("%02h %d") + P5* 行 (parse_gmii 认不出, 自己解)

    parse_gmii 遇到未知行会当字节行解析 -> 先滤掉 P5*/EVSRC 行再喂它 (临时文件)"""
    keep = []
    with open(fn, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if p and (p[0].startswith('P5') or p[0] == 'EVSRC'):
                continue
            keep.append(line)
    ff = fn + '.p4filter'
    with open(ff, 'w') as fh:
        fh.writelines(keep)
    frames, ev = G4.parse_gmii(ff)
    p5 = {}
    reg = {}
    with open(fn, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if not p or (not p[0].startswith('P5') and p[0] != 'EVSRC'):
                continue
            if p[0] == 'P5STAT':
                p5['p5stat'] = tuple(int(x) for x in p[1:8])
            elif p[0] == 'P5TX':
                p5['p5tx'] = tuple(int(x) for x in p[1:8])
            elif p[0] == 'P5ARB':
                p5['p5arb'] = (int(p[1]), int(p[2]))
            elif p[0] == 'P5DBG':
                p5['p5dbg'] = tuple(int(x) for x in p[1:8])
            elif p[0] == 'P5REG':
                reg[int(p[1])] = int(p[2], 16)
            elif p[0] == 'EVSRC':
                p5['evsrc'] = (int(p[1]), int(p[2], 16), int(p[3], 16),
                               int(p[4], 16), int(p[5]), int(p[6]))
    ev.update(p5)
    ev['p5reg'] = reg
    return frames, ev


def checkstatus(simdir):
    """app_status_uart 单元门: 解码行 vs 期望串 (TB 驱动的固定快照)"""
    exp = ("P5A1 ST=1 NX=12345679 UA=12345678 RW=C000 RN=20000065 "
           "RX=00001234 TX=0056789A TF=0123 MM=0007 OC=1ABCD EV=0003 DP=0001 "
           "RY=8001 EC=02 DL=0003 FI=0001 RS=0000" + " " * 10 + "\r\n")
    p = os.path.join(simdir, 'status_line.txt')
    if not os.path.exists(p):
        print('FAIL: status_line.txt 不存在 (TB 未产出)')
        return 1
    with open(p, 'rb') as fh:
        got = fh.read()
    try:
        g = got.decode('ascii')
    except Exception:
        g = repr(got)
    print('STATUS got : %r' % g)
    print('STATUS exp : %r' % exp)
    if got != exp.encode():
        print('MISMATCH: app_status_uart 行内容不符')
        return 1
    print('P5 STATUS OK')
    return 0


def checkwrapper(simdir):
    """wrapper 级 APP_MODE 门 (W1): 内部 GMII 捕获 -> FCS + 图案逐字节 + seq 连续

    W1 原症状 (app 侧 tready 退化成 m_ready => axis_pipe 在 m_valid=1 期间再收
    一个字) 会让载荷整字丢失/重复 => 图案逐字节当场 FAIL。"""
    errs = []
    resp = os.path.join(simdir, 'resp_p5_wrapper.memh')
    if not os.path.exists(resp):
        print('FAIL: resp_p5_wrapper.memh 不存在')
        return 1
    frames, ev = G4.parse_gmii(resp)
    d0 = []
    bad_fcs = 0
    others = 0
    for fb in frames:
        if not fcs_ok(fb):
            bad_fcs += 1
            continue
        body = fb[8:-4]
        if len(body) < 42 or body[12:14] != b'\x08\x00' or body[23] != 6:
            others += 1
            continue
        sport, dport = struct.unpack('!HH', body[34:38])
        if (sport, dport) != (MY_PORT, PEER_PORT):
            others += 1
            continue
        iplen, = struct.unpack('!H', body[16:18])
        seq, ack = struct.unpack('!II', body[38:46])
        flags = body[47]
        plen = iplen - 40
        if flags != 0x18 or plen <= 0:
            others += 1
            continue
        if body[46] != 0x50:
            errs.append('doff=%02x != 0x50 (seq=%08x)' % (body[46], seq))
        if body[0:6] != PEER_MAC:
            errs.append('dst mac %s != peer %s (seq=%08x)'
                        % (body[0:6].hex(), PEER_MAC.hex(), seq))
        if body[6:12] != DUT_MAC:
            errs.append('src mac %s != DUT (seq=%08x)' % (body[6:12].hex(), seq))
        if ack < PEER_ISN + 1 or ack > PEER_ISN + 1 + 100:
            errs.append('ack=%08x 越界 (seq=%08x)' % (ack, seq))
        win, = struct.unpack('!H', body[48:50])
        if win != 0xC000:
            errs.append('window=%04x != 0xC000 (seq=%08x)' % (win, seq))
        d0.append((seq, plen, body[54:54 + plen]))
    print('wrapper GMII: %d 帧 (conn0 数据 %d / 其它 %d / 坏 FCS %d)'
          % (len(frames), len(d0), others, bad_fcs))
    if bad_fcs:
        errs.append('%d 帧 FCS 无效' % bad_fcs)
    if len(d0) < 2:
        errs.append('wrapper 只出了 %d 个 conn0 数据帧 (<2) — APP_MODE 通路没通 '
                    '(W1 自环/背压丢失会表现为丢字或不出帧)' % len(d0))
    pat = xs_stream(1 << 20)
    d0.sort()
    cov_end = None
    for seq, plen, pay in d0:
        off = seq - ISN0
        if cov_end is None:
            if seq != ISN0:
                errs.append('首帧 seq=%08x != %08x' % (seq, ISN0))
        elif seq != cov_end:
            errs.append('seq 不连续: %08x != 上帧尾 %08x' % (seq, cov_end))
        cov_end = seq + plen
        if off < 0 or off + plen > len(pat):
            errs.append('seq=%08x 越界' % seq)
            continue
        if pay != pat[off:off + plen]:
            k = next(i for i in range(plen) if pay[i] != pat[off + i])
            errs.append('载荷失配 seq=%08x off=%d byte[%d] got %02x exp %02x '
                        '(W1: axis_pipe 背压丢失的典型症状)'
                        % (seq, off, k, pay[k], pat[off + k]))
    if d0:
        print('wrapper 图案: %d 帧 / %d B, 覆盖 [%08x, %08x)'
              % (len(d0), sum(p for _, p, _ in d0), ISN0, cov_end))
    if errs:
        for e in errs:
            print('MISMATCH: %s' % e)
        print('P5 WRAPPER FAIL (%d 项)' % len(errs))
        return 1
    print('P5 WRAPPER OK (wrapper APP_MODE app-TX 通路端到端逐字节正确)')
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    simdir = sys.argv[1]
    if len(sys.argv) >= 3 and sys.argv[2] == 'check':
        sys.exit(check(simdir))
    if len(sys.argv) >= 3 and sys.argv[2] == 'checkstatus':
        sys.exit(checkstatus(simdir))
    if len(sys.argv) >= 3 and sys.argv[2] == 'checkwrapper':
        sys.exit(checkwrapper(simdir))
    sys.exit(gen_stim(simdir))
