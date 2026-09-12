#!/usr/bin/env python
"""P4b-7-P6: 重放 run 后分析 — resp_p4_chain.memh vs p4b7_syn.pcapng 板级签名。

对比量纲 (板/sim 同坐标系, HLS ISS 均为 0x12345678):
- 板 snd 链基 305419897; sim prelude 多 16B (data7a+data7b) -> sim echo seq = 板 seq+16。
- PC 流: 板 seq 基 691601199; sim 重定基 seq_off=-691600183 -> sim rcv = 板 rcv offset +1016。
- 冻结签名 (板): rcv_nxt 冻在 692071927 (accepted 470728B); snd_una 停 305854125
  (echo offset 434228); echo 链停 305858505 (offset 438608, 差 32120 = 32KB FIFO 边缘);
  合法 ack=305858505 被拒; RTO 100ms 循环 (sim: 32k 拍)。
"""
import struct
import sys
import zlib

sys.path.insert(0, r'D:\repo\ECO\udp_hls_10g\tools')
import gen_stim_p4_chain as G

ROOT = r'D:\repo\ECO\udp_hls_10g'
SIMDIR = r'D:\repo\ECO\udp_hls_10g\sim\p4sim'

PC_ISS = 691601198          # pcap SYN seq
PC_BASE = 691601199         # 首数据字节
DUT_SND_BASE = 0x12345679   # = 305419897 (板与 sim 同值)
SEQ_OFF = 1016 - PC_BASE   # replay 重定基
ACK_OFF = 16               # prelude data7a+data7b 16B -> sim echo 链 = 板 + 16

def parse_pcap(fn):
    data = open(fn, 'rb').read()
    frames = []
    i = 0
    while i + 12 <= len(data):
        btype, blen = struct.unpack('<II', data[i:i + 8])
        if blen < 12 or i + blen > len(data):
            break
        if btype == 6:
            body = data[i + 8:i + blen - 4]
            ifid, tsh, tsl, caplen, origlen = struct.unpack('<IIIII', body[:20])
            frames.append(((tsh * 2**32 + tsl) / 1e6, body[20:20 + caplen]))
        i += blen
    return frames

def tcpf(p):
    ip = p[14:]; ihl = (ip[0] & 0xf) * 4
    t = ip[ihl:]
    sport, dport = struct.unpack('!HH', t[0:4])
    flags = t[13]
    seq, ack = struct.unpack('!II', t[4:12])
    plen = len(ip) - ihl - ((t[12] >> 4) * 4)
    return sport, dport, flags, seq, ack, plen

def main():
    # ---------- 板级 F2P (echo 侧) ----------
    board_echo = []          # (seq, plen, ack) 活 echo (排除 0x12 SYNACK)
    for ts, p in parse_pcap(ROOT + r'\p4b7_syn.pcapng'):
        if len(p) < 54 or p[12:14] != b'\x08\x00':
            continue
        ip = p[14:]
        if ip[9] != 6:
            continue
        src = '%d.%d.%d.%d' % tuple(ip[12:16])
        if src != '192.168.100.2':
            continue
        sport, dport, flags, seq, ack, plen = tcpf(p)
        if flags == 0x18 and sport == 8080 and plen:
            board_echo.append((seq, plen, ack))
    # ---------- sim 输出 ----------
    got, ev = G.parse_gmii(SIMDIR + r'\resp_p4_chain.memh')
    sim_echo = []            # (seq, plen, ack, first_cy) conn0 echo
    cy = 0
    for fb in got:
        body = fb[8:-4]
        if len(body) >= 48 and body[12:14] == b'\x08\x00' and body[23] == 6:
            flags = body[47]
            sport, dport = struct.unpack('!HH', body[34:38])
            if flags == 0x18 and sport == 0x1F90 and dport == 0x3039:
                seq, = struct.unpack('!I', body[38:42])
                ack, = struct.unpack('!I', body[42:46])
                plen = struct.unpack('!H', body[16:18])[0] - 40
                sim_echo.append((seq, plen, ack))
    print('board live echoes: %d  sim echoes: %d' % (len(board_echo), len(sim_echo)))

    def off_of(seq, base):
        return seq - base

    # ---------- echo 链对比 (offset 量纲) ----------
    be = [(off_of(s, DUT_SND_BASE), p) for s, p, _ in board_echo]
    se = [(off_of(s, DUT_SND_BASE) - ACK_OFF, p) for s, p, _ in sim_echo]
    print('board echo chain end offset: %d  sim: %d'
          % (be[-1][0] + be[-1][1] if be else -1, se[-1][0] + se[-1][1] if se else -1))
    # sim echo offset -> 板量纲后逐项对比 (长度不一时逐帧比)
    n = min(len(be), len(se))
    diverge = -1
    for i in range(n):
        if be[i] != se[i]:
            diverge = i
            print('DIVERGE at echo #%d: board(off,plen)=%s sim=%s' % (i, be[i], se[i]))
            print('  board seq=%u plen=%d ; sim seq=%u plen=%d'
                  % (be[i][0] + DUT_SND_BASE, be[i][1], se[i][0] + DUT_SND_BASE + ACK_OFF, se[i][1]))
            for j in range(max(0, i - 3), min(len(be), i + 4)):
                print('    b[%d]=%s s[%d]=%s' % (j, be[j], j, se[j] if j < len(se) else '--'))
            break
    if diverge < 0:
        print('echo 链前缀全等 (%d 帧); 长度差异 = 板 %d vs sim %d'
              % (n, len(be), len(se)))
        if len(se) > len(be):
            print('sim 多出 %d 个 echo (sim 未停): 前几个: %s'
                  % (len(se) - len(be), [(s, p) for s, p in se[len(be):len(be) + 5]]))
        if len(be) > len(se):
            print('板多出 %d 个 echo: %s' % (len(be) - len(se),
                  [(s, p) for s, p in be[len(se):len(se) + 5]]))
    print('STATS7  %s' % (ev['stats7'],))
    print('STATS_TX %s' % (ev['stx'],))
    print('RETX %s' % (ev['retx'],))
    print('STATS_ECO %s' % (ev['seco'],))
    print('TCBF %s' % (ev['tcbf'],))
    # ---------- 冻结签名核对 (sim 坐标) ----------
    if ev['tcbf']:
        rcv, snd, una = ev['tcbf'][0], ev['tcbf'][1], ev['tcbf'][2]
        print('conn0 TCB: rcv_nxt=%u (板冻结 sim 坐标 471744) snd_nxt=%u snd_una=%u'
              ' (板冻结 snd_una sim 坐标 %u)' % (rcv, snd, una, 305854125 + ACK_OFF))
        if rcv == 471744:
            print('==> rcv_nxt 冻结复现 (与板同值, sim 坐标 471744)')
        if una == 305854125 + ACK_OFF:
            print('==> snd_una 停摆复现 (sim 坐标 %u)' % una)
    if ev['stats7']:
        ps = ev['stats7']
        exp_pass = 3 + 414  # prelude 3 tcp? no - data7a/7b + 414 replay
        print('stat: pass=%d seq_drop=%d ack_drop=%d (seq_drop>0 => dup 被正常丢)'
              % (ps[0], ps[4], ps[5]))
    # 最后 sim 输出帧位置 (冻结后 sim 是否还发过帧)
    print('last echo sim:', sim_echo[-1] if sim_echo else None)
    print('board last echo:', board_echo[-1] if board_echo else None)

if __name__ == '__main__':
    main()
