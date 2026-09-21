#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_stim_p5_app.py — P5a app 接口门: 激励生成 + 判据 (tb_p5_app.v)

用法:
  python gen_stim_p5_app.py <simdir>            # 生成 stim_*.memh (极简空闲流)
  python gen_stim_p5_app.py <simdir> check      # 校验 resp_p5_app.memh
  python gen_stim_p5_app.py <simdir> close      # P5c-T4 关闭门 (同 stim, 独立 resp)
  python gen_stim_p5_app.py <simdir> close check   # 校验 resp_p5_close.memh

P5c-T4 `close` 门 (规格 §0 出口判据 ①-⑤; 编译期 -d P5_CLOSE, 见 sim/p5sim/
run_tb_p5_app.bat):
  ① 恰一个 FIN(0x11) / seq == snd_una / FIN 后 snd_nxt 恰 +1
  ② FIN 丢失 (PC 模型丢首个 FIN 的 ACK) -> RTO 重发, 逐字节一致, stat_eend == 0
  ③ abort -> RST(0x14) **线上真的出现** + state=0 (且 state=0 晚于 RST)
  ④ 同时关闭: 我方 FIN 先 => 恰 1 个 FIN 且 DEL 后不再发; DEL 先 => 0 个 FIN
  ⑤ 关闭超时到点: rst_req 置位 + RST 发出 + state=0 + CONN_DOWN 脉冲 +
     配额归还 (winq=0/pool 回满) + 新连接拿到非零 rcv_wnd (线上 window 字段)
  附加: 全帧 FCS 有效 / dst MAC 恒为对端 MAC (CAM 空置即垃圾帧) / 数据帧字段与
        载荷图案逐字节 / app 侧字节数与线上一致 / 计时器常量与生产的比例一致

判据 (P5a 出口):
  ① CONN_UP 事件字逐位正确 (peer_ip/port/mac/slot/kind, 源 = slow_cfg_adp 的
     ADD 收尾授权拍)
  ② app 发 TX_BYTES (默认 1MB) 图案: 每帧载荷逐字节 == xorshift64 图案
     (偏移 = seq - (ISS+1)); seq 覆盖并集 == [ISS+1, ISS+1+TX_BYTES) 连续无洞;
     flags=0x18/doff=0x50/plen<=1460/window == 0xC000 (P5b 第二轮 C19 恢复
     严格判据: 单连接 + 只注入 100B 且被立即消费 ⇒ 通告窗必然 == 授予配额;
     见 check() 处注释)/FCS 有效
  ③ 注入一个 2000B app 帧 (p5bad.memh N) ⇒ stat_drop_len 恰 1, 其后流水继续
     (并集仍完整, 无 stat_eend, 无死锁)
  ④ P4 逐帧不变量: 无合并巨帧 (ECOMAX <= 183, 每帧 plen <= 1460)、stat_eend==0、
     mac abort==0; RX 侧: 注入的 100B 图案数据段被 app 校验器逐字节比对通过
     (pat_rx_bytes == 100, pat_mismatch == 0)

  flow: P5b 窗口闭环门 (tb_p5_app 的 P5_FLOW 编译): ①逐拍占用 <= winq+2816+1518
    且 < 65528 ②mac stat_drop==0 ③通告右沿抖动有界 (容差 512B = 实测 308B 的
    ~1.7 倍) 且**抖动 < 接受裕度 ACC_MARGIN**(真安全条件) ④窗 <= 1 段 (对端模型
    停发) -> 重开 -> 零重传完成; **本门现已走过真 W=0** (实测 2 帧 window==0,
    板侧 stat_wu=2 ⇒ wu 通路真的发过), 但判据仍是"≤ 1 段", **不声称"判据证明了
    W=0 关窗"** (措辞约束 C23 保留, 事实基础已更新 — 见 checkflow 的 ④ 注释)
    ⑤stat_fc_upd>0 且 fc 挂起 < 16384 (活性) ⑥接受裕度 <= 物理余量 (必修4:
    ACC_MARGIN 从源码读, 并与实测占用峰值对账 — 不再硬编码 4096)。

退出码: 0 = 全过, 1 = 有 FAIL, 2 = 参数/文件错。
"""
import os
import re
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
RCV_WND = 0xC000        # 单连接配额/池上限 (= P5a 静态通告窗口值)
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
        # P5b C9: 设计标识演进 P5A1 -> P5B1 (格式/标识跟版本走, 不是放宽判据)
        if reg[0x9F] != 0x50354231:
            errs.append('设计标识 0x9F=%08x != 0x50354231 ("P5B1")' % reg[0x9F])
        # ---- P5b 流控寄存器 (单连接健康流: 确定性判据) ----
        if 0x96 not in reg or 0x9A not in reg or 0x9B not in reg or 0x97 not in reg:
            errs.append('缺 P5b 流控寄存器 dump (0x96/0x97/0x9A/0x9B)')
        else:
            if reg[0x9A] != RCV_WND:
                errs.append('winq[0]=%04x != %04x (C4: 单连接拿满池)'
                            % (reg[0x9A], RCV_WND))
            if reg[0x9B] != RCV_WND:
                errs.append('wu_mark[0]=%04x != %04x (C10: init 取 winq)'
                            % (reg[0x9B], RCV_WND))
            if reg[0x96] != 0:
                errs.append('stat_wu=%d != 0 (健康流零额外 wu 帧 — C6)' % reg[0x96])
            if reg[0x97] != 0:
                errs.append('pool=%d != 0 (单连接应拿满池)' % reg[0x97])
            print('P5b 流控寄存器: winq0=%04x wu_mark0=%04x pool=%05x stat_wu=%d '
                  'stat_fc_upd=%d redge0=%08x'
                  % (reg[0x9A], reg[0x9B], reg[0x97], reg[0x96],
                     reg.get(0x9C, -1), reg.get(0x99, 0)))
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
        # P5b 第二轮 C19: **恢复严格判据** (驳回第一版的 [0xC000-8192, 0xC000] 放宽)。
        # 审查实测: 严格判据 (win == 0xC000 逐字节) 对本门两份记录产物都 rc=0 ⇒
        # 旧口径下新判据是**纯放宽** (它能放过 17% 的欠通告), 而严格判据正是
        # C2/C4/C10 这套窗口算术最紧的端到端校验。
        # 为什么本门窗口必然恰好 = 0xC000: 单连接 ⇒ ev_up 授予 winq = WIN_POOL =
        # 0xC000; init 拍立即把 TCB.rcv_wnd 纠偏成 winq; 本门只注入 100B RX 数据
        # (occ <= 104B, 且随后被 app_pattern 立即消费) ⇒ redge = rcv_nxt + winq - occ,
        # W = redge - rcv_nxt = winq - occ; occ 回到 0 后扫描写回 0xC000。
        # 曾用于复现 P5a 静态语义的 P5WND=static 开关随之下线 (两口径已合并为严格判据;
        # 该环境变量不再有任何作用)。
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


FLOW_BYTES = 524288          # 对端发送总量 (与 tb_p5_app.v 的 FLOW_TOTAL 同值)
FLOW_SEGSZ = 1460
OCC_DELTA  = 2816            # C1b: ackq 深 x 每 ACK 帧拍数 x 到达速率 (1G)
OCC_UNIT   = 1518            # U: 单段最大字节 (54 + 1460 + 4)
WINQ_REF   = 0xC000
# P5b 必修4: 接受裕度 (ACC_MARGIN) 的物理余量预算 —— 与 tools/gen_stim_p5_adv.py
# 的同名常量同源 (那边有完整推导)。核心不等式:
#   WINQ_REF + OCC_DELTA + OCC_UNIT + SEG_MAX + ACC_MARGIN <= FIFO_BYTES
# 旧版把 ACC_MARGIN 硬编码成 4096, 与 RTL/wrapper 的真实参数**解耦** ⇒ 把
# ACC_MARGIN 改成 60000 时 ③ 的"抖动 < 裕度"判据自动变宽而无人察觉。现在从源码
# 读实际配置, 并额外用**实测占用峰值**对账 ⇒ 该安全方向有门了。
FIFO_BYTES = 8192 * 8
SEG_MAX    = 1500            # PLEN_MAX: win_ok 只看起始 seq ⇒ 单段可整段被接受
ACC_BUDGET = FIFO_BYTES - WINQ_REF - OCC_DELTA - OCC_UNIT - SEG_MAX   # 10550
_ROOT       = os.path.dirname(TOOLS)
WRAPPER_SRC = os.path.join(_ROOT, 'board', 'wrapper_p4.v')
FLOW_TB_SRC = os.path.join(_ROOT, 'tb', 'tb_p5_app.v')


def src_acc_margin(path):
    """从源码里取 .ACC_MARGIN 端口的实际配置值 (APP_MODE 取值)。

    支持 `.ACC_MARGIN(16'd4096)` 与 `.ACC_MARGIN(NAME)` + localparam NAME 两种写法。
    解析失败返回 None ⇒ 判据**必须**报错 (不允许静默跳过 = 静默放宽)。
    """
    try:
        with open(path, errors='replace') as fh:
            lines = fh.readlines()
    except OSError:
        return None
    for i, line in enumerate(lines):
        if '.ACC_MARGIN' not in line:
            continue
        m = re.search(r"16'd(\d+)", line)
        if m:
            return int(m.group(1))
        m = re.search(r"\.ACC_MARGIN\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", line)
        if not m:
            continue
        name = m.group(1)
        pat = re.compile(r"\b%s\b\s*=\s*(?:16'd|16'h)([0-9A-Fa-f]+)" % name)
        for ln in lines[i:] + lines[:i]:
            mm = pat.search(ln)
            if mm:
                return int(mm.group(1), 16) if "16'h" in ln else int(mm.group(1))
    return None


def check_acc_margin(errs, omax):
    """P5b 必修4: 接受裕度 <= 物理余量 (配置级 + 实测占用对账)。

    返回 ACC_MARGIN 值 (None = 解析失败, 已记 err)。灵敏度自测: 环境变量
    P5_WRAPPER_SRC / P5APP_TB_SRC 可指向带 60000 的副本 ⇒ 本判据必须 FAIL。
    """
    wpath = os.environ.get('P5_WRAPPER_SRC', WRAPPER_SRC)
    tpath = os.environ.get('P5APP_TB_SRC', FLOW_TB_SRC)
    wm = src_acc_margin(wpath)
    tm = src_acc_margin(tpath)
    if wm is None:
        errs.append('无法从 %s 解析 ACC_MARGIN (判据不允许静默跳过)' % wpath)
        return None
    if tm is None:
        errs.append('无法从 %s 解析 ACC_MARGIN (判据不允许静默跳过)' % tpath)
        return None
    if tm != wm:
        errs.append('全链 TB 的 ACC_MARGIN=%d != wrapper APP_MODE 值 %d '
                    '(C12 扩展: 参数也必须镜像 — 门必须在与板级相同的配置下跑)'
                    % (tm, wm))
    if wm > ACC_BUDGET:
        errs.append('接受裕度 ACC_MARGIN=%d > 物理余量 %d (FIFO %d - 配额 %d - '
                    'Δ %d - U %d - 单段 %d) — 接受界可把 frame_fifo 顶爆'
                    % (wm, ACC_BUDGET, FIFO_BYTES, WINQ_REF, OCC_DELTA, OCC_UNIT,
                       SEG_MAX))
    # 实测对账: 已观测到的占用峰值 + 裕度 + 单段必须仍装得下
    if omax + wm + SEG_MAX > FIFO_BYTES:
        errs.append('实测占用峰值 %d + ACC_MARGIN %d + 单段 %d > FIFO %d — '
                    '接受裕度吃掉的安全余量已被实测占用挤破'
                    % (omax, wm, SEG_MAX, FIFO_BYTES))
    print('接受裕度: ACC_MARGIN=%d (wrapper/TB 一致), 物理余量上限 %d; '
          '实测占用峰值 %d + 裕度 + 单段 %d = %d <= FIFO %d'
          % (wm, ACC_BUDGET, omax, SEG_MAX, omax + wm + SEG_MAX, FIFO_BYTES))
    return wm


def parse_flow(resp):
    """flow 门 resp: P5ACK 逐帧右沿 + FLOW* 汇总 + P5REG 寄存器快照"""
    ev = {}
    acks = []
    reg = {}
    with open(resp, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            if p[0] == 'P5ACK':
                acks.append((int(p[1]), int(p[2], 16), int(p[3], 16),
                             int(p[4], 16)))
            elif p[0] == 'FLOWB':
                ev['flowb'] = tuple(int(x) for x in p[1:9])
            elif p[0] == 'FLOWO':
                ev['flowo'] = tuple(int(x) for x in p[1:4])
            elif p[0] == 'FLOWP':
                ev['flowp'] = tuple(int(x) for x in p[1:7])
            elif p[0] == 'FLOWM':
                ev['flowm'] = tuple(int(x) for x in p[1:9])
            elif p[0] == 'FLOWS':
                ev['flows'] = (int(p[1]), int(p[2], 16), int(p[3], 16),
                               int(p[4], 16))
            elif p[0] == 'P5REG':
                reg[int(p[1])] = int(p[2], 16)
    return ev, acks, reg


def checkflow(simdir):
    """P5b flow 门判据 (规格 §3):
    ① 逐拍占用: occ <= winq + 2816 + 1518 且硬界 occ < 65528
       (2816 = ackq 深 x 每 ACK 帧拍数 x 到达速率 的**保守上界**, 取它是为了
        "宁可误报也不漏报安全破坏"; 实测 Δ 远小于它 — 见 ③ 的实测值)
    ② mac_rx_64.stat_drop == 0 (窗口收缩及时 ⇒ 物理缓冲不丢帧)
    ③ 通告右沿 (ack+window) 抖动 <= 512B 且 < 接受裕度 ACC_MARGIN (序比较)
    ④ 窗 <= 1 段 (本门对端模型因此停发; **本门现已走过真 W=0** — 见 C23 注释)
       -> 恢复 -> 零重传完成 (图案逐字节全对)
    ⑤ stat_fc_upd > 0 (窗口写口真的动过) + fc 挂起 < 16384 拍 (活性假设)
    ⑥ 接受裕度 <= 物理余量 (必修4): ACC_MARGIN 从 wrapper/TB 源码读 (不再硬编码),
       并与**实测占用峰值**对账: occ_max + ACC_MARGIN + 单段 <= frame_fifo 容量。
    """
    errs = []
    resp = os.path.join(simdir, 'resp_p5_flow.memh')
    if not os.path.exists(resp):
        print('FAIL: resp_p5_flow.memh 不存在')
        return 1
    ev, acks, reg = parse_flow(resp)
    for k in ('flowb', 'flowo', 'flowp', 'flowm', 'flows'):
        if k not in ev:
            print('FAIL: resp 缺 %s 行 (仿真未收尾?)' % k.upper())
            return 1
    sb, sfr, sw, smm, ska, sevf, spc, sgap = ev['flowb']
    omax, osoft, ohard = ev['flowo']
    pack, pback, psent, retx, mdrop, pretx = ev['flowp']
    pass_, dseq, dcrc, dipc, dnm, dtrunc, tack, tdrop = ev['flowm']
    quiet, psnd_nxt, praw, rcv_nxt = ev['flows']
    print('FLOWB sink: bytes=%d frames=%d words=%d mismatch=%d kaerr=%d '
          'evfrm=%d pauses=%d gap_max=%d' % (sb, sfr, sw, smm, ska, sevf, spc,
                                             sgap))
    print('FLOWO occ: max=%d soft_viol=%d hard_viol=%d (软界=%d 硬界=65528)'
          % (omax, osoft, ohard, WINQ_REF + OCC_DELTA + OCC_UNIT))
    print('FLOWP peer: acks=%d right_back=%d sent=%d retx=%d mac_drop=%d '
          'peer_retx=%d' % (pack, pback, psent, retx, mdrop, pretx))
    print('FLOWM rx pass=%d seq=%d crc=%d ipcsum=%d nonmatch=%d trunc=%d '
          'tx_ack=%d ack_drop=%d'
          % (pass_, dseq, dcrc, dipc, dnm, dtrunc, tack, tdrop))
    print('FLOWS quiet=%d psnd_nxt=%08x praw=%08x conn0_rcv_nxt=%08x'
          % (quiet, psnd_nxt, praw, rcv_nxt))
    wins = [w for (_, _, w, _) in acks]
    print('P5ACK 帧 %d 条; window 取值集合 %s'
          % (len(acks), sorted(set(wins))[:8]))

    # ---- ① 逐拍占用 (C1b) ----
    if osoft != 0:
        errs.append('逐拍占用超软界 %d 拍 (occ > winq + %d + %d)'
                    % (osoft, OCC_DELTA, OCC_UNIT))
    if ohard != 0:
        errs.append('逐拍占用触硬界 %d 拍 (occ >= 65528)' % ohard)
    if omax > WINQ_REF + OCC_DELTA + OCC_UNIT:
        errs.append('occ 峰值 %d > 软界 %d' % (omax, WINQ_REF + OCC_DELTA +
                                                OCC_UNIT))

    # ---- ⑥ 接受裕度 <= 物理余量 (P5b 必修4; 必须在 ③ 之前取到 margin) ----
    margin = check_acc_margin(errs, omax)

    # ---- ② 物理不丢帧 ----
    if mdrop != 0:
        errs.append('mac_rx_64.stat_drop=%d != 0 (物理缓冲丢帧 — 窗口收缩不及时)'
                    % mdrop)
    if dtrunc != 0:
        errs.append('RX 截断帧 %d (线路/链路级异常)' % dtrunc)
    if dcrc != 0 or dipc != 0 or dnm != 0:
        errs.append('RX 丢弃异常: crc=%d ipcsum=%d nonmatch=%d (对端组帧错?)'
                    % (dcrc, dipc, dnm))

    # ---- ③ 通告右沿不撤回 (P5b 第二轮 C22: 容差由 4276 收紧到 256) ----
    # 严格"单调不降"在本设计下**结构性不成立**: 帧里的 right = ack + window, 两个
    # 字段各有各的陈旧度 —— ack 来自 ACK 队列 (请求拍采样), window 来自 TCB (上次
    # fc 写 = 上次扫描的 redge - c_rcv_nxt), 二者独立 ⇒ right 可在 redge 附近上下
    # 抖动。真正约束回退幅度的是**两次 fc 写之间的到达量** (实测最大 136 B), 不是
    # 旧注释里那个 ackq 推导的上界 (2816/4276 = 实测的 ~30 倍, 足以静默放行一次
    # "真撤窗" —— 3 段)。故 TOL 取实测的 ~2 倍 (256 B), 并**同时打印最大回退幅度**
    # (只数次数不数幅度的话, 一次 4000B 的撤回会静默通过)。
    # 容差定标 (P5b 第二轮实测 + 机制):
    #   帧里的 right = ack + window 两字段**采样时刻不同** —— ack 来自 ACK 队列
    #   (请求拍采样), window 来自 TCB (上次 fc 写)。队列越深/越慢, 两者时差越大,
    #   right 的逐帧起伏(=抖动)就越大。实测 (C20 撤销整段绕行后, 真实短段参与):
    #   回退 37 次 / 最大 308 B —— 是**抖动**, 不是撤窗 (板侧 redge 由构造单调,
    #   见 C1)。
    #   ① 抖动上界 TOL = 512 B: 实测 308 的 ~1.7 倍, 且 ≈ 1/3 段 —— 真正的
    #      "撤窗"(≥1 段) 仍被拒; 旧值 4276 (=2816+1460) 是实测 14 倍, 能静默
    #      放过一次 3 段撤回 (C22 的关切), 故一并收紧。
    #   ② **安全性判据 (新增, 真正的安全条件)**: 抖动幅度必须被接受裕度
    #      (ACC_MARGIN) 严格覆盖 —— 对端在旧右沿下发出的数据落地时, 接受界 =
    #      rcv_nxt + win + ACC_MARGIN ≥ redge + ACC_MARGIN; 而对端最多发到
    #      redge + 抖动 ⇒ 只要 抖动 < ACC_MARGIN 就**不会拒收合法在飞数据**
    #      (这条不成立时, 现象是 seq 丢弃 + 対端重传, 即本门 ①/④ 的活体指标)。
    TOL = 512
    # P5b 必修4: 安全界 = **从源码读到的**实际 ACC_MARGIN (不再硬编码 4096; 见 ⑥)
    bad = 0
    back_n = 0
    back_max = 0
    rmax = None
    for (idx, ack, win, right) in acks:
        if rmax is not None:
            d = (right - rmax) & 0xFFFFFFFF
            if d >= 0x80000000:
                d -= 0x100000000
            if d < 0:
                back_n += 1
                back_max = max(back_max, -d)
            if d < -TOL:
                bad += 1
                if bad <= 3:
                    print('  右沿撤回超容差: 帧%d max=%08x -> %08x (ack=%08x win=%04x)'
                          % (idx, rmax, right, ack, win))
            if ((right - rmax) & 0xFFFFFFFF) < 0x80000000 and right != rmax:
                rmax = right
        else:
            rmax = right
    if bad:
        errs.append('通告右沿撤回超容差 %d 次 (> %d B — 真撤窗, 在飞数据会被拒)'
                    % (bad, TOL))
    print('右沿抖动: 回退 %d 次 / 最大幅度 %d B (抖动容差 %d B; 安全界 = 接受裕度 %s B)'
          % (back_n, back_max, TOL, margin))
    if margin is None:
        print('  (跳过"抖动 < 裕度"判据: ACC_MARGIN 解析失败, 已计 FAIL)')
    elif back_max >= margin:
        errs.append('通告右沿最大回退 %d B >= 接受裕度 ACC_MARGIN %d B — '
                    '合法在飞数据会被拒 (安全界破: 应增大裕度或收紧窗口写口)'
                    % (back_max, margin))
    if pback > 8:
        errs.append('TB 侧右沿回退计数 %d (> 8: 撤回过于频繁, 超出实测抖动预期)'
                    % pback)
    else:
        print('TB 侧右沿回退计数 %d (本 checker 实测最大幅度 %d B)' % (pback, back_max))

    # ---- ④ 窗关 -> 重开 -> 零重传完成 ----
    if not acks:
        errs.append('板侧一条 ACK 都没收到 (RX 链路没通?)')
    else:
        # 窗"关死"判据: 通告窗收到 <= 1 段 (1460B)。
        # **事实更新 (P5b 收尾, 独立验收 agent 实测统计)**: 本门**现已走过真 W=0** ——
        # 362 条 ACK 里 window ∈ [0, 49152], ==0 的有 2 帧 (ACK #213/#214),
        # <=1460 的共 11 帧; 且板侧 stat_wu = 2 ⇒ wu (窗口重开 ACK) 通路真的发出过
        # (wu_zero 触发, 不只是单元级 tb_p5_fc 的 T7 证据)。C23 早先记的
        # "window ∈ [168,49152]、==0 的 0 帧" 是**撤销 D9 绕行之前**的旧口径, 已过时。
        # **措辞约束仍然保留 (C23)**: 本判据本身只要求 "<= 1 段", 没有要求 ==0
        # ⇒ 判据/报告不得写"判据证明了真 W=0 关窗"; 可以写"本门现已覆盖真 W=0 关窗
        # + wu 重开" (实测事实), 两者不要混。
        z = [i for i, w in enumerate(wins) if w <= 1460]
        if not z:
            errs.append('全程通告窗未收到 <= 1 段 (窗口从未收到一段以下 — '
                        '慢消费者没形成背压?)')
        else:
            first0 = z[0]
            after = [w for w in wins[first0:] if w > 1460]
            if not after:
                errs.append('窗 <= 1 段之后从未重开 (wu ACK 通路失效 ⇒ 对端永久停等)')
            else:
                print('窗 <= 1 段 @ACK#%d (win=%d), 之后重开到 %04x (@ACK#%d)'
                      % (first0, wins[first0], max(after),
                         first0 + next(i for i, w in enumerate(wins[first0:])
                                       if w == max(after))))
    if retx != 0:
        errs.append('板侧 stat_retx=%d != 0 (窗口闭环下不应有重传)' % retx)
    # 对端重传: **允许但必须有界**。窗口关死时对端在旧窗口下合法发出的边界段会被
    # tcp_rx 按超窗拒收 (规格 C1b Δ 在接收侧的必然推论), 真实 TCP 发送端靠 dup-ACK
    # 快速重传自愈 ⇒ 本门建模之; 每次关窗事件最多 1 次重传 (跨度 3 段)。
    if pretx > 4:
        errs.append('对端重传 %d 次 (> 4: 关窗丢失面超出 C1b 预期)' % pretx)
    elif pretx:
        print('对端重传 %d 次 (关窗边界段的 dup-ACK 快速重传 — 见 checker 注释)'
              % pretx)
    if sb != FLOW_BYTES:
        errs.append('消费者收到 %d B != %d B (传输未完成)' % (sb, FLOW_BYTES))
    if psent != FLOW_BYTES:
        errs.append('对端报告已发 %d B != %d B' % (psent, FLOW_BYTES))
    if smm != 0:
        errs.append('图案逐字节失配 %d 字节 (静默损坏/丢字/串帧)' % smm)
    if ska != 0:
        errs.append('tkeep 非法 (空洞/零) %d 次 — AXIS 合同被破坏' % ska)
    if sevf != 0:
        errs.append('空字 %d 次' % sevf)
    if sfr == 0:
        errs.append('消费者一帧都没收到')
    # P5b 第二轮 C20: 撤销"只发整段"绕行后, 对端在窗口吃紧时会发**中流短段**
    # (此前只有收尾段是短的) ⇒ 覆盖同样字节数需要的段数 > ceil(total/1460)。
    # 故帧数判据改为下界 (少一帧 = 整段被合并/丢失, 那才是异常), 上界不设 —
    # 真正的完整性由 ①b 字节数精确 + ①c 图案逐字节共同把关。
    exp_fr = (FLOW_BYTES + FLOW_SEGSZ - 1) // FLOW_SEGSZ
    if sfr < exp_fr:
        errs.append('消费者帧数 %d < %d (整段被合并/丢失 — 帧边界异常)'
                    % (sfr, exp_fr))
    else:
        print('消费者帧数 %d (下界 %d; 多出 = 窗口中流短段, C20 后为预期)'
              % (sfr, exp_fr))
    if spc < 2:
        errs.append('暂停次数 %d < 2 (慢消费者用例没跑到位)' % spc)
    if dseq != 0:
        errs.append('板侧 RX seq 丢弃 %d (窗口内不该有)' % dseq)

    # ---- ⑤ 窗口写口真的动过 + 活性 ----
    fcupd = reg.get(0x9C, -1)
    fcwait = reg.get(0x9D, -1)
    if fcupd <= 0:
        errs.append('stat_fc_upd=%d (窗口纠偏写从未发生 — 窗口闭环是死的)' % fcupd)
    print('寄存器: pool=%d redge0=%08x winq0=%04x wu_mark0=%04x stat_fc_upd=%d '
          'stat_fc_wait_max=%d' % (reg.get(0x97, -1), reg.get(0x99, -1),
                                   reg.get(0x9A, -1), reg.get(0x9B, -1),
                                   fcupd, fcwait))
    if fcwait < 0:
        errs.append('缺 0x9D (fc 挂起观测) dump')
    elif fcwait > 16384:
        errs.append('fc 请求最长挂起 %d 拍 > 16384 (C1b 的 Δ 界失效 — 活性假设破了)'
                    % fcwait)
    if tack == 0:
        errs.append('板侧一条 ACK 都没发出 (tx_stat_ack=0)')
    if tdrop != 0:
        errs.append('板侧 ACK 队列丢弃 %d (ackq 32 深仍溢出)' % tdrop)
    stat_wu = reg.get(0x96, -1)
    if stat_wu is not None and stat_wu == 0:
        print('提示: stat_wu=0 — 本用例的窗口重开是靠数据 ACK 捎带完成的?')
    if reg.get(0x08, 0) != 0:
        print('提示: 收尾时 RX 占用 = %d (非 0 说明还有残留数据未消费)'
              % reg.get(0x08))

    if errs:
        print('')
        for e in errs:
            print('MISMATCH: %s' % e)
        print('P5 FLOW FAIL (%d 项)' % len(errs))
        return 1
    print('P5 FLOW OK (窗口闭环: 收缩->收到 <= 1 段(对端停发)->重开->零重传完成)')
    return 0


def checkstatus(simdir):
    """app_status_uart 单元门: 解码行 vs 期望串 (TB 驱动的固定快照)"""
    # P5b C9: 状态行 168 -> 220 字符 (行尾追加 AK/AD/TS/WQ/WM/WU/PO/PX)。
    # 判据仍是**逐字节全等** (未放宽): 前 156 字符与 P5a 逐字节相同, 行尾的
    # 10 个填充空格变成 P5b 字段段。字段值 = TB 预设的可辨识图案。
    # P5f: 行 220 -> 304 字符 (行尾再追加 UDP app 段 URB/UMM/URF/UOV/UPC/UPA/UTB/UTF)。
    exp = ("P5B1 ST=1 NX=12345679 UA=12345678 RW=C000 RN=20000065 "
           "RX=00001234 TX=0056789A TF=0123 MM=0007 OC=1ABCD EV=0003 DP=0001 "
           "RY=8001 EC=02 DL=0003 FI=0001 RS=0000 "
           "AK=BEEF AD=00CD TS=5 WQ=C000 WM=6035 WU=0011 PO=1C0DE PX=0009"
           " URB=00ABCDEF UMM=00000047 URF=05DC UOV=000A UPC=0002 UPA=0001"
           " UTB=12345678 UTF=0BB8"
           + "\r\n")
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


# =====================================================================
# P5c-T4: close 门 (tb_p5_app.v -d P5_CLOSE)
# ---------------------------------------------------------------------
# 判据来源: 规格 §0 (出口判据 ①-⑤) + §1 G2/G3 + T1/T3 实施记录。
# 证据全部来自 TB 落盘: 线上帧字节流 (resp 的 "%02h 1" 行, 逐帧 FCS 校验)、
#   P5FRM (每帧拍号 + 解出的字段; idx 与字节流帧序一一对应 -> 交叉校验)、
#   P5EVT (FINREQ/RSTREQ/ST0/EVDOWN 拍号)、P5PH (阶段边界与计数增量)、
#   P5REGP (阶段寄存器快照)、P5APPTX (app 侧进度/停推现场)。
# 计时器缩放 (绝不放宽的说明见下 close_timer_assert): TB 覆盖 RTO_LIM/FIN_TO_LIM
#   为缩放值 (生产 12.5M/50.0M 拍在 xsim 里跑不动; 与 sim/p5close 同一做法),
#   但**比例保持 4xRTO** 且**生产常量由源码断言** ---- 缩放只换计时器长短, 不换
#   任何代码路径 (RST/state=0/CONN_DOWN/配额归还全走同一份 RTL)。
RTL_TX_SRC  = os.path.join(_ROOT, 'rtl', 'tcp_tx_frame.v')
RTL_APP_SRC = os.path.join(_ROOT, 'rtl', 'app_ctrl.v')
TB_CLOSE_SRC = os.path.join(_ROOT, 'tb', 'tb_p5_app.v')
RTO_TICK_PER_LIM = 256          # RTO = RTO_LIM x 16 tick x 16 连接 (tcp_tx_frame.v)
FIN_TO_RTO_RATIO = 4            # FIN_TO_LIM x 256 拍 = 4 x RTO (app_ctrl.v T3 注)
PROD_RTO_LIM  = 48828           # 生产值 (rtl/tcp_tx_frame.v parameter)
PROD_FIN_TO_LIM = 195313        # 生产值 (rtl/app_ctrl.v parameter)
PEER_MAC_B = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
DUT_MAC_B  = bytes(DUT_MAC)
# 阶段 -> 判据 (与 tb_p5_app.v 的 ph_open id 对齐)
PH_NAME = {1: 'A: 干净关闭 (①)', 2: 'B: FIN 丢失+RTO+关闭超时 (②⑤)',
           3: 'D1: 同时关闭, 我方 FIN 先 (④)', 4: 'D2: 同时关闭, DEL 先 (④)',
           5: 'F: 新连接窗口 (⑤)', 6: 'C: abort (③)', 7: 'G: abort fence 探针 (③)'}


def _kv(parts):
    d = {}
    for x in parts:
        if '=' in x:
            k, v = x.split('=', 1)
            try:
                d[k] = int(v)
            except ValueError:
                d[k] = v
    return d


def close_parse(resp):
    """resp_p5_close.memh -> (GMII 帧列表, P5* 行字典)"""
    keep = []
    ev = {'evt': [], 'ph': {}, 'frm': {}, 'regp': {}, 'apptx': {}}
    with open(resp, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            if p[0].startswith('P5') or p[0] == 'EVSRC':
                t = p[0]
                if t == 'P5CFG':
                    ev['cfg'] = _kv(p[1:])
                elif t == 'P5START':
                    ev['start'] = _kv(p[1:]).get('k')
                elif t == 'P5TX':
                    ev['tx'] = [int(x) for x in p[1:8]]
                elif t == 'P5STAT':
                    ev['stat'] = [int(x) for x in p[1:8]]
                elif t == 'TCBF':
                    ev['tcbf'] = p[1:]
                elif t == 'P5CLOSE':
                    ev['close'] = _kv(p[2:])
                elif t == 'P5PH':
                    ev['ph'][int(p[1])] = dict(
                        base=int(p[2], 16), d=int(p[3]), f=int(p[4]),
                        r=int(p[5]), ev=int(p[6]), t0=int(p[7]), t1=int(p[8]))
                elif t == 'P5EVT':
                    ev['evt'].append((p[1], int(p[2]),
                                      int(p[3]) if len(p) > 3 else None))
                elif t == 'P5REGP':
                    ev['regp'].setdefault(int(p[1]), {})[int(p[2])] = int(p[3], 16)
                elif t == 'P5APPTX':
                    ev['apptx'][int(p[1])] = dict(zip(
                        ('bytes', 'frames', 'tvalid', 'tready', 'active', 'done'),
                        [int(x) for x in p[2:8]]))
                elif t == 'P5FRM':
                    ev['frm'][int(p[1])] = dict(
                        t0=int(p[2]), t1=int(p[3]),
                        etype=int(p[4] + p[5], 16), proto=int(p[6], 16),
                        flags=int(p[7], 16), seq=int(p[8], 16),
                        ack=int(p[9], 16), win=int(p[10], 16),
                        iplen=int(p[11], 16), dmac=int(p[12], 16),
                        smac=int(p[13], 16), sport=int(p[14], 16),
                        dport=int(p[15], 16))
                continue
            keep.append(line)
    ff = resp + '.p4filter'
    with open(ff, 'w') as fh:
        fh.writelines(keep)
    frames, _ = G4.parse_gmii(ff)
    return frames, ev


def tcp_fields(fb):
    """捕获帧 -> TCP 字段 (非 IPv4/TCP 返回 None)"""
    if len(fb) < 12 + 54:
        return None
    body = fb[8:-4]
    if len(body) < 54 or body[12:14] != b'\x08\x00' or body[23] != 6:
        return None
    iplen, = struct.unpack('!H', body[16:18])
    sport, dport = struct.unpack('!HH', body[34:38])
    seq, ack = struct.unpack('!II', body[38:46])
    plen = iplen - 40
    return dict(sport=sport, dport=dport, seq=seq, ack=ack, doff=body[46],
                flags=body[47], win=struct.unpack('!H', body[48:50])[0],
                dmac=body[0:6], smac=body[6:12], plen=plen,
                iplen=iplen, pay=body[54:54 + max(0, plen)])


def _src_param(path, name, pat):
    """从 RTL/TB 源码里取参数默认值 (解析失败 -> None; 判据不允许静默跳过)"""
    try:
        with open(path, errors='replace') as fh:
            txt = fh.read()
    except OSError:
        return None
    m = re.search(pat, txt)
    return int(m.group(1)) if m else None


def close_timer_assert(errs, cfg):
    """计时器常量断言 (缩放合法性 + 生产值未被改动)。

    TB 覆盖 RTO_LIM/FIN_TO_LIM (xsim 跑不动 12.5M/50M 拍), 因此必须有这条断言
    把"生产值 + 两者比例"钉死, 否则"缩放"会变成静默放宽: 谁把 RTL 的超时改小,
    本门也照样绿。
    """
    pr = _src_param(RTL_TX_SRC, 'RTO_LIM',
                    r'parameter\s+integer\s+RTO_LIM\s*=\s*(\d+)')
    pf = _src_param(RTL_APP_SRC, 'FIN_TO_LIM',
                    r'parameter\s+\[17:0\]\s+FIN_TO_LIM\s*=\s*18\'d(\d+)')
    if pr is None:
        errs.append('无法从 %s 解析 RTO_LIM (判据不允许静默跳过)' % RTL_TX_SRC)
    elif pr != PROD_RTO_LIM:
        errs.append('rtl/tcp_tx_frame.v RTO_LIM=%d != 生产值 %d (RTO 被改动)'
                    % (pr, PROD_RTO_LIM))
    if pf is None:
        errs.append('无法从 %s 解析 FIN_TO_LIM (判据不允许静默跳过)' % RTL_APP_SRC)
    elif pf != PROD_FIN_TO_LIM:
        errs.append('rtl/app_ctrl.v FIN_TO_LIM=%d != 生产值 %d (关闭超时被改动)'
                    % (pf, PROD_FIN_TO_LIM))
    if pr is not None and pf is not None:
        # 生产关系: FIN_TO_LIM 轮 x 256 拍 = 4 x RTO
        if abs(pf - FIN_TO_RTO_RATIO * pr) > 1:
            errs.append('生产常量比例破: FIN_TO_LIM=%d != %d x RTO_LIM=%d'
                        % (pf, FIN_TO_RTO_RATIO, pr))
    if not cfg or 'rto_lim' not in cfg:
        errs.append('resp 缺 P5CFG (无法断言门内计时器配置)')
        return None
    rl, fl = cfg['rto_lim'], cfg['fin_to_lim']
    if abs(fl - FIN_TO_RTO_RATIO * rl) > 1:
        errs.append('TB 缩放比例破: fin_to_lim=%d != 4 x rto_lim=%d (缩放必须保持'
                    '与生产同比例, 否则重发/超时的先后关系与板级不一致)' % (fl, rl))
    if rl * RTO_TICK_PER_LIM != cfg.get('rto_ticks'):
        errs.append('P5CFG rto_ticks=%s != rto_lim=%d x %d'
                    % (cfg.get('rto_ticks'), rl, RTO_TICK_PER_LIM))
    print('计时器: RTL 生产值 RTO_LIM=%s / FIN_TO_LIM=%s (比例 %d)；本门缩放值 '
          'rto_lim=%d (RTO=%d 拍) / fin_to_lim=%d (超时=%d 拍, = %d x RTO)'
          % (pr, pf, FIN_TO_RTO_RATIO, rl, cfg.get('rto_ticks'), fl,
             fl * RTO_TICK_PER_LIM, fl // max(rl, 1)))
    return rl


def close_check(simdir):
    errs = []
    resp = os.path.join(simdir, 'resp_p5_close.memh')
    if not os.path.exists(resp):
        print('FAIL: resp_p5_close.memh 不存在 (仿真未跑?)')
        return 1
    frames, ev = close_parse(resp)
    known = set(PH_NAME)
    if 'close' not in ev or 'cfg' not in ev:
        print('FAIL: resp 缺 P5CLOSE/P5CFG 行 (仿真未收尾 -- 看门狗/超时?)')
        return 1
    if int(ev['close'].get('tmo', 0)) != 0:
        errs.append('TB 等待超时位图 tmo=%08x != 0 (某条等待没等到 -- 判据未成立)'
                    % int(ev['close']['tmo']))
    ph = ev['ph']
    if set(ph) != known:
        errs.append('阶段集合 %s != %s (TB 驱动异常)'
                    % (sorted(ph), sorted(known)))
        return close_report(errs, frames, ev)

    rl = close_timer_assert(errs, ev['cfg'])
    rto = (rl or 0) * RTO_TICK_PER_LIM

    # ---------------- 基础设施: 帧字节流 <-> P5FRM 一一对应 ----------------
    if len(frames) != len(ev['frm']):
        errs.append('GMII 帧数 %d != P5FRM 行数 %d (落盘/解码错位)'
                    % (len(frames), len(ev['frm'])))
    info = []          # 每帧: dict(bytes, tick0/1, 字段)
    for i, fb in enumerate(frames):
        if not fcs_ok(fb):
            errs.append('帧 #%d FCS 无效' % i)
            continue
        f = tcp_fields(fb)
        d = dict(idx=i, raw=fb, tcp=f)
        if i in ev['frm']:
            m = ev['frm'][i]
            d['t0'], d['t1'] = m['t0'], m['t1']
            if f is not None:
                # 交叉校验: P5FRM 的字段必须与字节流解出的一致
                for k, got, exp in (('flags', f['flags'], m['flags']),
                                    ('seq', f['seq'], m['seq']),
                                    ('ack', f['ack'], m['ack']),
                                    ('win', f['win'], m['win']),
                                    ('iplen', f['iplen'], m['iplen']),
                                    ('sport', f['sport'], m['sport']),
                                    ('dport', f['dport'], m['dport'])):
                    if got != exp:
                        errs.append('帧 #%d 字段 %s 字节流=%s P5FRM=%s (TB 解码/'
                                    '索引错位)' % (i, k, got, exp))
        else:
            errs.append('帧 #%d 缺 P5FRM 行 (无拍号, 无法归阶段)' % i)
        info.append(d)

    ours = [d for d in info if d.get('tcp') and
            (d['tcp']['sport'], d['tcp']['dport']) == (MY_PORT, PEER_PORT)]
    for d in ours:
        t = d['tcp']
        if t['smac'] != DUT_MAC_B:
            errs.append('帧 #%d src mac %s != DUT' % (d['idx'], t['smac'].hex()))
        if t['dmac'] != PEER_MAC_B:
            errs.append('帧 #%d dst mac %s != 对端 %s (CAM 空置 = 垃圾帧)'
                        % (d['idx'], t['dmac'].hex(), PEER_MAC_B.hex()))
    n_data = [d for d in ours if d['tcp']['flags'] == 0x18 and d['tcp']['plen'] > 0]
    n_fin = [d for d in ours if d['tcp']['flags'] == 0x11]
    n_rst = [d for d in ours if d['tcp']['flags'] == 0x14]
    n_oth = [d for d in ours if d['tcp']['flags'] not in (0x18, 0x11, 0x14)]
    print('线上帧: 总 %d (FCS 坏 %d) / conn0 数据 %d / FIN %d / RST %d / 其它 %d'
          % (len(frames), sum(1 for fb in frames if not fcs_ok(fb)), len(n_data),
             len(n_fin), len(n_rst), len(n_oth)))
    for d in n_oth:
        print('  其它帧 #%d flags=%02x seq=%08x plen=%d'
              % (d['idx'], d['tcp']['flags'], d['tcp']['seq'], d['tcp']['plen']))

    # 数据帧字段 + 载荷图案 (app_pattern 每阶段 ev_up 重置 LFSR => 偏移 = seq - 阶段基)
    for d in n_data:
        t = d['tcp']
        pid = _phase_of(ph, d)
        if pid is None:
            errs.append('数据帧 #%d (seq=%08x) 不属于任何阶段窗口' % (d['idx'], t['seq']))
            continue
        if t['doff'] != 0x50:
            errs.append('数据帧 #%d doff=%02x != 0x50' % (d['idx'], t['doff']))
        if t['plen'] > 1460:
            errs.append('数据帧 #%d plen=%d > 1460 (合并巨帧)' % (d['idx'], t['plen']))
        if t['win'] != 0xC000:
            errs.append('数据帧 #%d window=%04x != 0xC000 (阶段 %d)' % (d['idx'], t['win'], pid))
        off = t['seq'] - ph[pid]['base']
        if off < 0:
            errs.append('数据帧 #%d seq=%08x < 阶段基 %08x' % (d['idx'], t['seq'], ph[pid]['base']))
            continue
        exp = xs_stream(off + t['plen'], SEED)
        if t['pay'] != exp[off:off + t['plen']]:
            k = next((j for j in range(t['plen']) if t['pay'][j] != exp[off + j]), 0)
            errs.append('数据帧 #%d 载荷失配 (seq=%08x off=%d byte[%d])'
                        % (d['idx'], t['seq'], off, k))

    # ---------------- 基础设施: 阶段计数 <-> 拍窗归属 交叉校验 ----------------
    # P5PH 的 f/r/d 由 TB 在帧尾直接计数 (与拍窗归属**独立**): 两者必须相等,
    # 否则任何 "按拍窗归阶段" 的判据都可能漏算/错算 (基础设施不可信)。
    for key, got in (('d', len(n_data)), ('f', len(n_fin)), ('r', len(n_rst))):
        tot = sum(ev['ph'][i][key] for i in ev['ph'])
        if tot != got:
            errs.append('阶段计数 %s 合计 %d != 线上帧数 %d (拍窗归属与 TB 计数'
                        '不一致 — 阶段判据不可信)' % (key, tot, got))

    # ---------------- 聚合一致性 ----------------
    tx = ev['tx']
    if tx[0] != len(frames):
        errs.append('P5TX frames=%d != 线上帧数 %d' % (tx[0], len(frames)))
    if tx[1] != sum(d['tcp']['plen'] for d in n_data):
        errs.append('P5TX bytes=%d != 线上载荷合计 %d'
                    % (tx[1], sum(d['tcp']['plen'] for d in n_data)))
    if tx[3] != 0:
        errs.append('stat_drop_len=%d != 0 (超长帧被中止)' % tx[3])
    if tx[6] != 0:
        errs.append('stat_eend=%d != 0 (S_PAY 欠载) -- 判据 ② 要求 0' % tx[6])
    if tx[4] != len(n_fin) or tx[5] != len(n_rst):
        errs.append('P5TX fin=%d/rst=%d != 线上 fin=%d/rst=%d'
                    % (tx[4], tx[5], len(n_fin), len(n_rst)))
    st = ev['stat']
    if st[0] != sum(d['tcp']['plen'] for d in n_data):
        errs.append('app 报告 tx_bytes=%d != 线上载荷 %d (app->线上 丢字/多字)'
                    % (st[0], sum(d['tcp']['plen'] for d in n_data)))
    if st[1] != len(n_data):
        errs.append('app 报告 tx_frames=%d != 线上数据帧 %d' % (st[1], len(n_data)))
    if st[4] != 1:
        errs.append('app 未跑完一轮 (pat_done=%d)' % st[4])
    if st[5] != ev['cfg']['tx_bytes']:
        errs.append('app 报告 tx_bytes=%d != TB TX_BYTES %d' % (st[0], st[5]))
    if st[3] != 0 or st[6] != 0:
        errs.append('app RX mismatch=%d bad_frames=%d (本门不注数据段)' % (st[3], st[6]))

    # ---------------- ① 阶段 A ----------------
    pid = 1
    p = ph[pid]
    da = [d for d in n_data if _phase_of(ph, d) == pid]
    fa = [d for d in n_fin if _phase_of(ph, d) == pid]
    ra = [d for d in n_rst if _phase_of(ph, d) == pid]
    print('阶段 %s: 帧 d=%d f=%d r=%d (P5PH %d/%d/%d), 拍 [%d,%d]'
          % (PH_NAME[pid], len(da), len(fa), len(ra), p['d'], p['f'], p['r'],
             p['t0'], p['t1']))
    if len(da) != ev['cfg']['nframes']:
        errs.append('阶段 A 数据帧 %d != %d' % (len(da), ev['cfg']['nframes']))
    if len(fa) != 1:
        errs.append('判据①: 阶段 A FIN 帧 %d != 1 (恰一个)' % len(fa))
    else:
        f0 = fa[0]['tcp']
        exp_seq = p['base'] + sum(d['tcp']['plen'] for d in da)
        if f0['seq'] != exp_seq:
            errs.append('判据①: FIN seq=%08x != snd_una(=%08x: 基+数据字节)'
                        % (f0['seq'], exp_seq))
        if f0['plen'] != 0 or f0['doff'] != 0x50 or f0['iplen'] != 40:
            errs.append('判据①: FIN 形态错 (plen=%d doff=%02x iplen=%d)'
                        % (f0['plen'], f0['doff'], f0['iplen']))
        if f0['ack'] != PEER_ISN + 1:
            errs.append('判据①: FIN ack=%08x != rcv_nxt %08x' % (f0['ack'], PEER_ISN + 1))
        if f0['win'] != 0xC000:
            errs.append('判据①: FIN window=%04x != 0xC000' % f0['win'])
        # FIN 之后: 阶段 A 内不得再有数据帧 / FIN 帧
        after = [d for d in da + fa if d['t0'] > fa[0]['t0']]
        if after:
            errs.append('判据①: FIN 之后还有 %d 帧 (重复 FIN/越界数据)' % len(after))
        if ra:
            errs.append('判据①: 阶段 A 出现 %d 个 RST (不该有)' % len(ra))
        # 寄存器: snd_nxt 恰 +1 且 FIN 已被对端 ACK (snd_una 越过)
        r = ev['regp'].get(pid, {})
        if r.get(0x12) != f0['seq'] + 1:
            errs.append('判据①: TCB snd_nxt=%s != FIN.seq+1 (%08x)'
                        % (r.get(0x12), f0['seq'] + 1))
        if r.get(0x11) != f0['seq'] + 1:
            errs.append('判据①: TCB snd_una=%s != FIN.seq+1 (对端没 ACK 掉 FIN)'
                        % r.get(0x11))
        if r.get(0x10) != 1:
            errs.append('判据①: 阶段 A 末 state=%s != 1 (ESTAB)' % r.get(0x10))
        print('判据①: FIN seq=%08x (= 基+%d B), snd_nxt=snd_una=%08x (恰 +1), '
              'state=1, 阶段 A 仅此一个 FIN [OK]'
              % (f0['seq'], sum(d['tcp']['plen'] for d in da), f0['seq'] + 1))

    # ---------------- ② 阶段 B (FIN 丢失 -> RTO 重发) ----------------
    pid = 2
    p = ph[pid]
    db = [d for d in n_data if _phase_of(ph, d) == pid]
    fb_ = [d for d in n_fin if _phase_of(ph, d) == pid]
    rb = [d for d in n_rst if _phase_of(ph, d) == pid]
    print('阶段 %s: 帧 d=%d f=%d r=%d' % (PH_NAME[pid], len(db), len(fb_), len(rb)))
    if len(db) != ev['cfg']['nframes']:
        errs.append('阶段 B 数据帧 %d != %d' % (len(db), ev['cfg']['nframes']))
    if len(fb_) != 2:
        errs.append('判据②: 阶段 B FIN 帧 %d != 2 (FIN 丢失 -> 恰一次 RTO 重发;'
                    ' 第 2 个被 ACK 后不应再有)' % len(fb_))
    else:
        # "逐字节一致" 的口径: **TCP 段逐字节一致** (L4 头 + 载荷) —— 允许差异
        # 只出现在 IP ID (每帧自增的唯一标识, rtl/tcp_tx_frame.v 的 id_r) 及其
        # 连带的 IP 校验和、以及覆盖全帧的 FCS 上。差异集合必须严格 <= 这 4+4 字节,
        # 否则报 FAIL (seq/ack/flags/win/doff/载荷任何一处不同都会被抓住)。
        a, b = fb_[0]['raw'], fb_[1]['raw']
        if len(a) != len(b):
            errs.append('判据②: 重发 FIN 帧长 %d != %d' % (len(a), len(b)))
        else:
            body_n = len(a) - 12
            allow = {18, 19, 24, 25} | set(range(body_n - 4, body_n))
            diff = [j - 8 for j in range(8, len(a) - 4) if a[j] != b[j]]
            bad = [j for j in diff if j not in allow]
            if bad:
                errs.append('判据②: 重发 FIN 与原 FIN 在 TCP 段内不一致 (body 偏移 %s)'
                            % bad)
            else:
                print('判据②: FIN 重发与首发**逐字节一致** (差异仅 IP ID [18,19]/'
                      'IP csum [24,25], 覆盖 4/4 帧尾 FCS; 本次实测差 %d 字节)'
                      % len(diff))
        exp_seq = p['base'] + sum(d['tcp']['plen'] for d in db)
        if fb_[0]['tcp']['seq'] != exp_seq:
            errs.append('判据②: FIN seq=%08x != snd_una %08x' % (fb_[0]['tcp']['seq'], exp_seq))
        gap = fb_[1]['t0'] - fb_[0]['t0']
        if not (rto * 0.5 <= gap <= rto * 1.5):
            errs.append('判据②: FIN 重发间隔 %d 拍 不在 [%d, %d] (RTO=%d) -- 不是'
                        ' RTO 计时器触发的重发' % (gap, rto // 2, rto * 3 // 2, rto))
        else:
            print('判据②: 重发间隔 %d 拍 ~= 1 x RTO (%d 拍) -- RTO 路径触发 [OK]'
                  % (gap, rto))
    # ---- ⑤ 关闭超时 (同一阶段的后半段) ----
    evb = [e for e in ev['evt'] if e[0] == 'RSTREQ' and p['t0'] <= e[1] <= p['t1']]
    if not evb:
        errs.append('判据⑤: 阶段 B 无 rst_req 置位 (关闭超时未触发)')
    if not rb:
        errs.append('判据⑤: 阶段 B 没有 RST 帧上线 (rst_req 置位不等于 RST 发出)')
    else:
        print('判据⑤: 超时到点 -> rst_req@%s + RST 帧 #%d (flags 0x14)'
              % (evb[0][1] if evb else '?', rb[0]['idx']))
    st0b = [e for e in ev['evt'] if e[0] == 'ST0' and p['t0'] <= e[1] <= p['t1']]
    if not st0b:
        errs.append('判据⑤: 阶段 B 无 state=0 写 (TCB 未被拆)')
    elif rb and st0b[0][1] < rb[0]['t0']:
        errs.append('判据⑤: state=0 写 (@%d) 早于 RST 发出 (@%d) -- T3 的时序'
                    ' (RST 先发再拆 state) 被破坏' % (st0b[0][1], rb[0]['t0']))
    if p['ev'] < 1:
        errs.append('判据⑤: 阶段 B 无 CONN_DOWN 事件脉冲 (P5PH ev=%d)' % p['ev'])
    r = ev['regp'].get(pid, {})
    if r.get(0x9A) != 0:
        errs.append('判据⑤: 超时后 winq[0]=%s != 0 (配额未归还)' % r.get(0x9A))
    if r.get(0x97) != 0xC000:
        errs.append('判据⑤: 超时后 pool=%s != 0xC000 (配额未回到池里)' % r.get(0x97))
    if r.get(0x10) != 0:
        errs.append('判据⑤: 超时后 state=%s != 0' % r.get(0x10))
    if r.get(0x9A) == 0 and r.get(0x97) == 0xC000:
        print('判据⑤: 配额归还 winq[0]=0 / pool=0xC000 (全池) [OK], CONN_DOWN 脉冲 %d 次'
              % p['ev'])

    # ---------------- ④ 阶段 D1 / D2 (同时关闭) ----------------
    for pid, want in ((3, 1), (4, 0)):
        p = ph[pid]
        fd = [d for d in n_fin if _phase_of(ph, d) == pid]
        dd = [d for d in n_data if _phase_of(ph, d) == pid]
        rd = [d for d in n_rst if _phase_of(ph, d) == pid]
        print('阶段 %s: 帧 d=%d f=%d r=%d (P5PH %d/%d/%d)'
              % (PH_NAME[pid], len(dd), len(fd), len(rd), p['d'], p['f'], p['r']))
        if len(fd) != want:
            errs.append('判据④: 阶段 %s 板侧 fast path FIN 帧 %d != %d'
                        % (PH_NAME[pid][:2], len(fd), want))
        if rd:
            errs.append('判据④: 阶段 %s 出现 %d 个 RST' % (PH_NAME[pid][:2], len(rd)))
        if p['ev'] < 1:
            errs.append('判据④: 阶段 %s 无 CONN_DOWN (DEL 未落地)' % PH_NAME[pid][:2])
        if pid == 3 and len(fd) == 1:
            # DEL 之后的观察窗 (3 x RTO) 内不得再发 FIN (死连接不重发)
            print('判据④: D1 我方 FIN #%d (seq=%08x) 后经 %d 拍观察窗无第二个 FIN [OK]'
                  % (fd[0]['idx'], fd[0]['tcp']['seq'], p['t1'] - fd[0]['t1']))
    print('判据④: D2 (DEL 先到) FIN=0 [OK] -- 两种到达序都被接受 (规格 §0 ④)')

    # ---------------- ⑤ 阶段 F (新连接非零窗口) ----------------
    pid = 5
    p = ph[pid]
    df = [d for d in n_data if _phase_of(ph, d) == pid]
    r = ev['regp'].get(pid, {})
    if r.get(0x9A) != 0xC000:
        errs.append('判据⑤: 新连接 winq[0]=%s != 0xC000 (拿不到配额 => 通告窗 0)'
                    % r.get(0x9A))
    else:
        print('判据⑤: 新连接 winq[0]=0xC000 (非零 rcv_wnd) [OK] 其 %d 个数据帧 window '
              '字段全为 0xC000 [OK]' % len(df))
    if len(df) != ev['cfg']['nframes']:
        errs.append('阶段 F 数据帧 %d != %d' % (len(df), ev['cfg']['nframes']))
    if r.get(0x10) != 1:
        errs.append('阶段 F 末 state=%s != 1' % r.get(0x10))

    # ---------------- ③ 阶段 C / G (abort -> RST + state=0) ----------------
    for pid in (6, 7):
        p = ph[pid]
        dc = [d for d in n_data if _phase_of(ph, d) == pid]
        rc = [d for d in n_rst if _phase_of(ph, d) == pid]
        print('阶段 %s: 帧 d=%d r=%d (P5PH %d/%d)' % (PH_NAME[pid], len(dc), len(rc),
                                                      p['d'], p['r']))
        rq = [e for e in ev['evt'] if e[0] == 'RSTREQ' and p['t0'] <= e[1] <= p['t1']]
        if not rq:
            errs.append('判据③: 阶段 %d 无 rst_req 置位 (CMD abort 未生效)' % pid)
        if len(rc) != 1:
            errs.append('判据③: 阶段 %d RST 帧 %d != 1' % (pid, len(rc)))
            continue
        rst = rc[0]
        st0c = [e for e in ev['evt'] if e[0] == 'ST0' and p['t0'] <= e[1] <= p['t1']]
        se = [e for e in ev['evt'] if e[0] == 'RSTSENT' and p['t0'] <= e[1] <= p['t1']]
        if not st0c:
            errs.append('判据③: 阶段 %d 无 state=0 写' % pid)
        elif not se:
            errs.append('判据③: 阶段 %d 无 RST 发出 (tx.rst_sent_r 未上升) —— 但线'
                        '上有 RST 帧, 说明模板不一致, 判据不可信' % pid)
        elif st0c[0][1] < se[0][1]:
            errs.append('判据③: 阶段 %d state=0 (@%d) 早于 RST **发出** (@%d) — '
                        'T3 的时序契约 (RST 先发, 再拆 state) 被破坏'
                        % (pid, st0c[0][1], se[0][1]))
        else:
            print('判据③: RST 帧 #%d (flags=0x14, seq=%08x) 线上 [%d,%d]; 帧器发出 '
                  '@%d; state=0 @%d (晚 %d 拍) -- 线上确有 RST [OK]'
                  % (rst['idx'], rst['tcp']['seq'], rst['t0'], rst['t1'], se[0][1],
                     st0c[0][1], st0c[0][1] - se[0][1]))
        if rst['tcp']['plen'] != 0 or rst['tcp']['doff'] != 0x50 or rst['tcp']['iplen'] != 40:
            errs.append('判据③: RST 形态错 (plen=%d doff=%02x iplen=%d)'
                        % (rst['tcp']['plen'], rst['tcp']['doff'], rst['tcp']['iplen']))
        # RST 的 seq = 发出时 snd_nxt = 基 + 已发数据字节
        exp_seq = p['base'] + sum(d['tcp']['plen'] for d in dc)
        if rst['tcp']['seq'] != exp_seq:
            errs.append('判据③: RST seq=%08x != 基+数据 %08x (seq 空间被破坏)'
                        % (rst['tcp']['seq'], exp_seq))
        # 观察窗内 RST 之后不得再起数据帧 (G3 fence 的守卫子判据)
        after = [d for d in dc if d['t0'] > rst['t0']]
        if after:
            errs.append('判据③: 阶段 %d RST 之后仍有 %d 个数据帧上线 (abort fence '
                        '失效)' % (pid, len(after)))
        else:
            print('判据③: RST 之后的观察窗 (%d 拍) 内无数据帧 [OK]'
                  % (p['t1'] - rst['t1']))
        r = ev['regp'].get(pid, {})
        if r.get(0x10) != 0:
            errs.append('判据③: 阶段 %d 末 state=%s != 0' % (pid, r.get(0x10)))
        if pid in (6, 7):
            ap = ev['apptx'].get(pid)
            if ap:
                nf = ev['cfg']['nframes']
                if ap['frames'] >= nf:
                    # app 的 24 帧全部上线 => "RST 后不再起数据帧" 在本阶段为**空**
                    # 判据 (RST 被 scan_now 饥饿推到数据流末尾, 见报告); 该子判据
                    # 是回归绊线, 不当成本阶段的非空证据。
                    print('  阶段 %d fence 判据**为空**: app 本阶段 %d/%d 帧全部上线 '
                          '(RST 在数据流末尾才发出; 饥饿延迟, 见报告)'
                          % (pid, ap['frames'], nf))
                else:
                    print('  阶段 %d fence 判据非空: app 只上线 %d/%d 帧 (%d/%d B), '
                          '收尾时 app2_tvalid=%d tready=%d => 其余帧被 tx_blk 挡住 '
                          '[OK]' % (pid, ap['frames'], nf, ap['bytes'],
                                    ev['cfg']['tx_bytes'], ap['tvalid'],
                                    ap['tready']))

    return close_report(errs, frames, ev)


def _phase_of(ph, d):
    """帧 -> 阶段 id (按 P5FRM 拍号落在阶段窗口内)"""
    t0 = d.get('t0')
    if t0 is None:
        return None
    for pid, p in ph.items():
        if p['t0'] <= t0 <= p['t1']:
            return pid
    return None


def close_report(errs, frames, ev):
    print('')
    if 'close' in ev:
        print('P5CLOSE: %s' % ' '.join('%s=%s' % (k, v)
                                        for k, v in sorted(ev['close'].items())))
    for pid in sorted(ev['ph']):
        p = ev['ph'][pid]
        print('  阶段 %d %-32s base=%08x 数据=%d FIN=%d RST=%d EVDOWN=%d 拍[%d,%d]'
              % (pid, PH_NAME.get(pid, '?'), p['base'], p['d'], p['f'], p['r'],
                 p['ev'], p['t0'], p['t1']))
    for e in ev['evt']:
        if e[0] in ('RSTREQ', 'ST0'):
            print('  事件 %s @%d' % (e[0], e[1]))
    if errs:
        print('')
        for e in errs:
            print('MISMATCH: %s' % e)
        print('P5 CLOSE FAIL (%d 项)' % len(errs))
        return 1
    print('P5 CLOSE OK (关闭语义: FIN/RST/state=0/CONN_DOWN/配额归还 全判据通过)')
    return 0


def close_gen(simdir):
    rc = gen_stim(simdir)
    print('gen_stim_p5_app: close 门 (P5_CLOSE) -- TB 自带阶段驱动, 无额外 memh')
    return rc


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    simdir = sys.argv[1]
    if len(sys.argv) >= 3 and sys.argv[2] == 'close':
        # P5c-T4 close 门: 激励与默认门相同 (TB 自带阶段驱动), 判据独立
        if len(sys.argv) >= 4 and sys.argv[3] == 'check':
            sys.exit(close_check(simdir))
        sys.exit(close_gen(simdir))
    if len(sys.argv) >= 3 and sys.argv[2] == 'check':
        sys.exit(check(simdir))
    if len(sys.argv) >= 3 and sys.argv[2] == 'checkstatus':
        sys.exit(checkstatus(simdir))
    if len(sys.argv) >= 3 and sys.argv[2] == 'checkwrapper':
        sys.exit(checkwrapper(simdir))
    if len(sys.argv) >= 3 and sys.argv[2] == 'flow':
        sys.exit(checkflow(simdir))
    sys.exit(gen_stim(simdir))
