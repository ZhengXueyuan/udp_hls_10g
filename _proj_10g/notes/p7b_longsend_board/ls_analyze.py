# ls_analyze.py -- P7B-LONGSEND 板级轮读数器 (长流/负对照两臂通用)
#   输入 = lf_dl.sh 的 stdout 落档 (per-run txt)
#   口径 (逐条照抄 lf_dl.sh / ACCEPT.md, 不新造):
#     内窗速率 = ΔW51*8/(ΔW5/156.25e6); 两点必须**都在流内** (0 < W51 < 收敛值);
#     P = ΔW43/ΔW20; 线占空 = 193/P; 所有 Δ 一律 mod 2^32 且**原始值一并落盘** + 回卷次数 k。
#   ⚠️ W5/W43 = 156.25MHz 时基 (27.487 s 回卷); W51/W15/W20/W52 是 32 位计数 (W51/W15 ≈3.66 s @9.4Gbps)。
import re, sys, os

WRAP = 2**32
TB = 156.25e6

def load(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    snaps = {}; cur = None; order = []
    tstamp = {}
    for line in txt.splitlines():
        m = re.match(r'^LF_SNAP_T (\S+) (\d+)$', line)
        if m: tstamp[int(m.group(2))] = float(m.group(1)); continue
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', line)
        if m:
            cur = m.group(1); snaps[cur] = {}; order.append(cur); continue
        m = re.match(r'^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)', line)
        if m and cur: snaps[cur][int(m.group(1))] = int(m.group(3), 16)
        if line.startswith('SNAP_END'): cur = None
    return snaps, order, txt

def d(a, b):   # mod 2^32 delta + wrap count
    x = b - a
    k = 0
    if x < 0: x += WRAP; k = 1
    return x, k

def field(txt, pat, cast=str):
    m = re.search(pat, txt)
    return cast(m.group(1)) if m else None

def run(path):
    snaps, order, txt = load(path)
    inner = [t for t in order if re.match(r'^\S+_s\d+$', t)]
    inner.sort(key=lambda t: int(t.rsplit('_s', 1)[1]))
    # ⭐ 2026-10-09 本会话实测: W51 是**跨连接累积**的自由计数器 (同一烧录内不归零)
    #    ⇒ "流内"判据的基准 = pre 快照的 W51, 不是 0 (ACCEPT 的 `0 < W51 < TXB` 只对
    #    "每跑前重烧"的批次成立 —— 本会话连跑 5 次, 第二次起 W51 已从 0x0FFFFFFF 起)。
    preL = [t for t in order if t.endswith('_pre')]
    base = snaps[preL[0]].get(51, 0) if preL else 0
    flow_pts = [t for t in inner if 0 < (snaps[t].get(51, 0) - base) % WRAP <= TXB]
    # 最长流内跨度
    best = None
    for i in range(len(flow_pts)):
        for j in range(i + 1, len(flow_pts)):
            A, B = snaps[flow_pts[i]], snaps[flow_pts[j]]
            if B[51] <= A[51]: continue
            if B[51] - A[51] > (best[0] if best else 0):
                best = (B[51] - A[51], flow_pts[i], flow_pts[j])
    out = {}
    out['npts'] = len(inner); out['nflow'] = len(flow_pts)
    out['sink_bps'] = field(txt, r'agg_Mbps=([0-9.]+)', float)
    out['sink_bytes'] = field(txt, r'SINK_SUM conns=1 fail_conns=0 bytes=(\d+)', int)
    out['sink_wall'] = field(txt, r'net_s=([0-9.]+)', float)
    out['sink_checked'] = field(txt, r'checked_bytes=(\d+)', int)
    out['sink_fm'] = field(txt, r'SINK_CONN 0 OK bytes=\d+ first_mismatch=(-?\d+) mism_bytes=(\d+)', str)
    out['sink_status'] = 'OK' if 'SINK_CONN 0 OK' in txt else ('STALL' if 'STALL' in txt else '?')
    out['sink_full'] = field(txt, r'(SINK_SUM [^\n]*)', str)
    out['sink_limits'] = field(txt, r'(SINK_LIMITS [^\n]*)', str)
    out['sink_check'] = field(txt, r'SINK_CHECK check=(\S+)', str)
    # NIC (pre2 -> post2 优先)
    nic = {}
    for tag in ('pre', 'pre2', 'post', 'post2'):
        m = re.search(r'### PHASE nic_%s[^\n]*\n(.*?)(?=\n###)' % tag, txt, re.S)
        if not m: continue
        v = {}
        for k in ('port_rx_good_bytes', 'port_rx_packets', 'port_rx_bad', 'rx_eth_crc_err',
                  'port_rx_nodesc_drops', 'port_tx_packets', 'port_tx_bytes'):
            mm = re.search(r'^\s*%s:\s*(\d+)' % k, m.group(1), re.M)
            if mm: v[k] = int(mm.group(1))
        nic[tag] = v
    A = nic.get('pre2') or nic.get('pre'); B = nic.get('post2') or nic.get('post')
    if A and B:
        out['nic_bytes'], out['nic_bytes_k'] = d(A['port_rx_good_bytes'], B['port_rx_good_bytes'])
        out['nic_pkts'], out['nic_pkts_k'] = d(A['port_rx_packets'], B['port_rx_packets'])
        out['nic_bpp'] = out['nic_bytes'] / out['nic_pkts'] if out['nic_pkts'] else 0
        out['nic_errs'] = {k: (B.get(k, 0) - A.get(k, 0)) for k in
                           ('port_rx_bad', 'rx_eth_crc_err', 'port_rx_nodesc_drops') if k in B}
    if best:
        _, tA, tB = best
        A, B = snaps[tA], snaps[tB]
        d51, k51 = d(A[51], B[51]); d5, k5 = d(A[5], B[5])
        d43, k43 = d(A[43], B[43]); d20, k20 = d(A[20], B[20])
        out['span'] = (tA, tB, d51, k51, d5, k5)
        out['inner_bps'] = d51 * 8.0 / (d5 / TB) / 1e9
        out['P'] = d43 / d20 if d20 else 0
        out['duty'] = 193.0 / out['P'] if out['P'] else 0
        out['inner_dt'] = d5 / TB
    # 全程 (pre -> post) 差分 + 回卷
    if ' LS3_pre' in txt or '_pre' in txt:
        pre = [t for t in order if t.endswith('_pre')]; post = [t for t in order if t.endswith('_post')]
        if pre and post:
            A, B = snaps[pre[0]], snaps[post[0]]
            row = {}
            for w in (5, 43, 20, 51, 15, 55, 23, 21, 41, 42, 45, 59, 60, 52, 14, 57):
                if w in A and w in B:
                    x, k = d(A[w], B[w]); row[w] = (x, k, A[w], B[w])
            out['full'] = row
    return out

TXB = 268435455
if __name__ == '__main__':
    for path in sys.argv[1:]:
        o = run(path)
        print('=' * 100)
        print(os.path.basename(path), ' npts=%d nflow=%d  sink_check=%s  limits=%s' % (o['npts'], o['nflow'], o.get('sink_check'), (o.get('sink_limits') or '')[:90]))
        print('  SINK  status=%s bytes=%s wall=%ss %.3f Mbps  checked=%s  FM=%s  %s' %
              (o['sink_status'], o['sink_bytes'], o['sink_wall'], o['sink_bps'], o['sink_checked'], o.get('sink_fm'), o['sink_full'][:120] if o.get('sink_full') else ''))
        if 'inner_bps' in o:
            A, B, d51, k51, d5, k5 = o['span']
            print('  BOARD inner %s->%s  dW51=%d(k=%d) dW5=%d(k=%d) dt=%.3fms  rate=%.4f Gbps  P=%.3f duty=%.1f%%' %
                  (A, B, d51, k51, d5, k5, o['inner_dt'] * 1e3, o['inner_bps'], o['P'], o['duty'] * 100))
        else:
            print('  BOARD inner: **无流内点**')
        if 'nic_bytes' in o:
            print('  NIC   rx_bytes=%d(k=%d) pkts=%d(k=%d) B/pkt=%.4f errs=%s' %
                  (o['nic_bytes'], o['nic_bytes_k'], o['nic_pkts'], o['nic_pkts_k'], o['nic_bpp'], o.get('nic_errs')))
        if o.get('full'):
            print('  FULL  pre->post:', ' '.join('W%d:%d(k=%d)' % (w, v[0], v[1]) for w, v in sorted(o['full'].items())))
