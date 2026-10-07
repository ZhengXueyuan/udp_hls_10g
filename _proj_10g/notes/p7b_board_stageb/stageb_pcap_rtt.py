#!/usr/bin/env python3
# stageb_pcap_rtt.py -- 从 j6 台架的 pcap 里量"真实 RTT / 发送节奏 / ACK 合并比 / 重传"
#   用法: python3 stageb_pcap_rtt.py <pcap> [--peer 192.168.100.100] [--board 192.168.100.2]
#   纯流式解析 (snaplen 96 够 TCP 头), 不依赖 scapy。
#   输出 (全部可复算):
#     DATA_*  : 上行数据帧 (peer -> board) 计数/字节
#     ACK_*   : 下行 ACK 帧 (board -> peer) 计数
#     RTT_*   : data(seq_end) -> 首个 ack>=seq_end 的间隔 (ms) 分布
#     GAP_*   : 数据帧到达间隔 (无数据窗口) 分布
#     BURST_* : 数据突发结构 (连续到达 <=2ms 视为一簇)
#     RETX_*  : seq 回退次数 (重传迹象)
import sys, struct

def main():
    path = sys.argv[1]
    peer_ip = '192.168.100.100'
    board_ip = '192.168.100.2'
    for i, a in enumerate(sys.argv):
        if a == '--peer': peer_ip = sys.argv[i+1]
        if a == '--board': board_ip = sys.argv[i+1]
    peer_b = bytes(int(x) for x in peer_ip.split('.'))
    board_b = bytes(int(x) for x in board_ip.split('.'))

    f = open(path, 'rb')
    gh = f.read(24)
    magic = struct.unpack('<I', gh[:4])[0]
    if magic == 0xa1b2c3d4: endian, nano = '<', False
    elif magic == 0xa1b23c4d: endian, nano = '<', True
    elif magic == 0xd4c3b2a1: endian, nano = '>', False
    else: sys.exit('bad magic %x' % magic)

    n_data = 0; n_ack = 0; n_other = 0
    data_bytes = 0
    t_first = None; t_last = None
    pending = {}            # seq_end -> t  (最近未确认的段, 窗口 49KB => 极少)
    rtts = []               # ms
    gaps = []               # 数据帧到达间隔 (s)
    prev_t = None
    max_seq = -1
    n_retx = 0
    ack_bytes_batches = []  # 每个 ACK 新确认的字节数 (合并比)
    last_ack = -1
    t0 = None
    burst = []              # 突发: [start_t, n_frames, bytes]
    cur = None
    BURST_GAP = 2e-3        # 连续到达 (间隔 <=2ms) 归为同一簇
    while True:
        rh = f.read(16)
        if len(rh) < 16: break
        ts_s, ts_us, incl, orig = struct.unpack(endian + 'IIII', rh)
        t = ts_s + ts_us * (1e-9 if nano else 1e-6)
        pkt = f.read(incl)
        if len(pkt) < 14 + 20 + 20: continue
        if pkt[12:14] != b'\x08\x00': continue
        ihl = (pkt[14] & 0x0f) * 4
        if pkt[14+9] != 6: continue                # TCP only
        src = pkt[26:30]; dst = pkt[30:34]
        flags = pkt[14+ihl+13]
        sport = struct.unpack('>H', pkt[14+ihl:14+ihl+2])[0]
        dport = struct.unpack('>H', pkt[14+ihl+2:14+ihl+4])[0]
        seq = struct.unpack('>I', pkt[14+ihl+4:14+ihl+8])[0]
        ack = struct.unpack('>I', pkt[14+ihl+8:14+ihl+12])[0]
        win = struct.unpack('>H', pkt[14+ihl+14:14+ihl+16])[0]
        ip_tot = struct.unpack('>H', pkt[16:18])[0]
        paylen = ip_tot - ihl - 20
        if t0 is None: t0 = t
        if src == peer_b and dst == board_b and dport == 8080:
            # 上行数据 (或纯 ACK/SYN)
            if paylen > 0:
                n_data += 1; data_bytes += paylen
                if t_last is None or t > t_last: t_last = t
                if t_first is None: t_first = t
                seq_end = (seq + paylen) & 0xFFFFFFFF
                if max_seq >= 0 and seq < max_seq - 200000:  # 回退 (回卷重放/重传)
                    n_retx += 1
                if max_seq < 0 or seq_end > max_seq:
                    max_seq = seq_end if max_seq < 0 or (seq_end - max_seq) < 2**31 else max_seq
                pending[seq_end] = t
                if len(pending) > 4096: pending = dict(list(pending.items())[-512:])
                if prev_t is not None:
                    d = t - prev_t
                    if d > 1e-4: gaps.append(d)
                    if cur is not None and d <= BURST_GAP:
                        cur[1] += 1; cur[2] += paylen; cur[3] = t
                    else:
                        cur = [t, 1, paylen, t]; burst.append(cur)
                else:
                    cur = [t, 1, paylen, t]; burst.append(cur)
                prev_t = t
            else:
                n_other += 1
        elif src == board_b and dst == peer_b and sport == 8080:
            n_ack += 1
            if ack != last_ack:
                # 新确认的字节 (带符号处理回绕)
                d = (ack - last_ack) & 0xFFFFFFFF
                if last_ack >= 0 and 0 < d < 10**7:
                    ack_bytes_batches.append(d)
                last_ack = ack
            # RTT: 匹配所有 ack >= seq_end 的 pending
            done = [k for k in pending if ((ack - k) & 0xFFFFFFFF) < 2**31 and ((ack - k) & 0xFFFFFFFF) < 10**7]
            for k in done:
                rtts.append((t - pending.pop(k)) * 1e3)
        else:
            n_other += 1
    f.close()
    def pct(v, p):
        if not v: return float('nan')
        s = sorted(v); i = min(len(s)-1, int(len(s)*p/100.0)); return s[i]
    print("PCAP %s  span_s=%.3f" % (path, (t_last or 0) - (t_first or 0)))
    print("DATA_FRAMES=%d DATA_BYTES=%d DATA_MBps=%.2f DATA_Gbps=%.4f" % (
        n_data, data_bytes, data_bytes/((t_last-t_first) or 1)/1e6, data_bytes*8/((t_last-t_first) or 1)/1e9))
    print("ACK_FRAMES=%d OTHER=%d ACK_per_seg=%.4f" % (n_ack, n_other, n_ack/max(1,n_data)))
    print("RETX_seq_backward=%d (%.4f%%)" % (n_retx, 100.0*n_retx/max(1,n_data)))
    if rtts:
        print("RTT_n=%d RTT_med=%.3fms RTT_p90=%.3fms RTT_p99=%.3fms RTT_max=%.3fms" % (
            len(rtts), pct(rtts,50), pct(rtts,90), pct(rtts,99), max(rtts)))
    if gaps:
        print("GAP_n=%d GAP_med=%.3fms GAP_p90=%.3fms GAP_p99=%.3fms GAP_max=%.3fms GAP_sum_s=%.3f" % (
            len(gaps), pct(gaps,50)*1e3, pct(gaps,90)*1e3, pct(gaps,99)*1e3, max(gaps)*1e3, sum(gaps)))
    if burst:
        b_n = [b[1] for b in burst]; b_d = [(b[3]-b[0]) for b in burst if b[3] > b[0]]
        b_by = [b[2] for b in burst]
        print("BURST_n=%d BURST_frames_med=%d BURST_bytes_med=%d BURST_dur_med=%.3fms" % (
            len(burst), pct(b_n,50), pct(b_by,50), pct(b_d,50)*1e3 if b_d else float('nan')))
    if ack_bytes_batches:
        print("ACKBATCH_n=%d ACKBATCH_med=%dB ACKBATCH_p90=%dB ACKBATCH_max=%dB" % (
            len(ack_bytes_batches), pct(ack_bytes_batches,50), pct(ack_bytes_batches,90), max(ack_bytes_batches)))

main()
