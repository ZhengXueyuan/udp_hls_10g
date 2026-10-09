# ls_summary.py -- 长流 pre->post 全量差分 (mod 2^32, **回卷次数 k 由独立口径钉死**)
#   口径: W51/W15 在 9.4 Gbps 下每 3.66 s 回卷一次 ⇒ k 不能从 mod 差值反推。
#   做法: 用**独立仪器** (sink 的 64 位 bytes / NIC 64 位计数) 定 k, 再与板侧 mod 残余对账。
import re, sys
WRAP = 2**32
TB = 156.25e6

def parse(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    pre = {}; post = {}; cur = None
    for line in txt.splitlines():
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', line)
        if m: cur = {}; continue
        m = re.match(r'^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)', line)
        if m and cur is not None: cur[int(m.group(1))] = int(m.group(3), 16); continue
        if line.startswith('SNAP_END'):
            tag = line.split()[1]
            if tag.endswith('_pre'): pre = cur
            if tag.endswith('_post'): post = cur
            cur = None
    return pre, post, txt

if __name__ == '__main__':
    path = sys.argv[1]
    pre, post, txt = parse(path)
    sink_bytes = int(re.search(r'SINK_SUM conns=1 fail_conns=0 bytes=(\d+)', txt).group(1))
    nic = {}
    for tag in ('pre', 'pre2', 'post', 'post2'):
        m = re.search(r'### PHASE nic_%s[^\n]*\n(.*?)(?=\n###)' % tag, txt, re.S)
        if m:
            nic[tag] = {k: int(v) for k, v in re.findall(r'^\s*(\w+):\s*(\d+)', m.group(1), re.M)}
    A = nic.get('pre2') or nic.get('pre'); B = nic.get('post2') or nic.get('post')
    nicb = B['port_rx_good_bytes'] - A['port_rx_good_bytes']
    nicp = B['port_rx_packets'] - A['port_rx_packets']
    print('独立口径: sink bytes=%d  NIC rx bytes=%d pkts=%d (B/pkt=%.6f)' % (sink_bytes, nicb, nicp, nicb / nicp))
    dur = float(re.search(r'net_s=([0-9.]+)', txt).group(1))
    print('sink net_s=%.3f s  wall=%.3f s  速率=%.3f Mbps' %
          (dur, float(re.search(r'wall_s=([0-9.]+)', txt).group(1)),
           float(re.search(r'agg_Mbps=([0-9.]+)', txt).group(1))))
    # k 由 sink bytes 定 (板侧 app 字节 == sink 收字节, 差 = 收尾在飞)
    kw51 = sink_bytes // WRAP
    print('\n== 全量差分 (pre->post) ==')
    print('%-4s %-22s %12s %12s %12s %4s %18s %14s' % ('字', '名字', 'pre', 'post', 'mod-Δ', 'k', '总 Δ', '备注'))
    NAME = {5: 'gmii_free_FE(timebase)', 14: 'tx_stat_frames_TCP', 15: 'tx_stat_bytes_TCP',
            20: 'mac_tx_frames', 21: 'tx_stat_abort', 23: 'rx_stat_nonmatch_TCP',
            41: 'mtx_flush_words', 42: 'mtx_flush_done', 43: 'mtx_stat_tx_words',
            45: 'txcdc_ovf_cnt', 51: 'app_tx_bytes', 52: 'app_tx_frames',
            55: 'tx_stat_retx', 57: 'tx_retx_hi', 59: 'stx_fifo_ovf', 60: 'srx_fifo_ovf'}
    for w in (5, 14, 15, 20, 21, 23, 41, 42, 43, 45, 51, 52, 55, 57, 59, 60):
        if w not in pre or w not in post: continue
        a, b = pre[w], post[w]
        d = (b - a) % WRAP
        if w in (51, 15):
            k = kw51
            note = 'W15总Δ-W51总Δ=%d (重传字节)' % (k * WRAP + d - (kw51 * WRAP + ((post[51] - pre[51]) % WRAP)))
        elif w == 5:
            k = 1 if b < a else 0; note = '时基: 总Δticks=%d = %.3f s (全场 %.3f s)' % (k * WRAP + d, (k * WRAP + d) / TB, dur)
        else:
            k = 0; note = ''
        print('%-4s %-22s %12d %12d %12d %4d %18d %s' % ('W%d' % w, NAME.get(w, '?'), a, b, d, k, k * WRAP + d, note))
    print('\n== 派生 ==')
    tot51 = kw51 * WRAP + (post[51] - pre[51]) % WRAP
    tot15 = kw51 * WRAP + (post[15] - pre[15]) % WRAP
    print('冗余率 W15/W51 = %.7f  (重传字节 %d)' % (tot15 / tot51, tot15 - tot51))
    print('per-conn: sink bytes/TX_BYTES = %.4f 量子' % (sink_bytes / 268435455.0))
    print('W52 app_tx_frames=%d  W20 mac_tx_frames=%d (NIC Δpkts=%d)' %
          ((post[52] - pre[52]) % WRAP, (post[20] - pre[20]) % WRAP, nicp))
    print('W55 重传会话=%d (%.2f/s)   W57 tx_retx_hi=%d' % ((post[55] - pre[55]) % WRAP, ((post[55] - pre[55]) % WRAP) / dur, (post[57] - pre[57]) % WRAP))
