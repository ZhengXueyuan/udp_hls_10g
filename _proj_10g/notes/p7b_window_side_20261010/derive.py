#!/usr/bin/env python3
# derive.py -- P7B 构建 E 板级轮: 逐跑的三口径速率 + 本轮四个核心比值 + raw/k 逐字
#   口径: 板内窗 = app_Mbps (ΔW51 pinned by frames); sink = SINK_SUM agg_Mbps (墙钟);
#         NIC = (Δbytes − 58×Δpkts)×8/whole_dt_s (对端网卡硬件计数, 58 B/帧 = 14+20+8+... = 1518−1460)
#   ⛔ 不写"线占空 = 193/P"(恒等式, 已订正; P ≡ 156.25e6/fps)。
import json, re, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

def getline(path, pat):
    for ln in open(path, encoding='utf-8', errors='replace'):
        if re.match(pat, ln): return ln.strip()
    return None

for tag in sys.argv[1:]:
    out = __import__('subprocess').run([PY, os.path.join(HERE, 'analyze.py'), 'runs/%s.txt' % tag],
                                       capture_output=True, text=True, encoding='utf-8').stdout.strip()
    j = json.loads(out.splitlines()[-1])
    raw = 'runs/%s.txt' % tag
    nic = getline(raw, r'^GEOM_NOPCAP') or ''
    sink = getline(raw, r'^SINK_SUM') or ''
    db = int(re.search(r'd_bytes=(\d+)', nic).group(1))
    dp = int(re.search(r'd_pkts=(\d+)', nic).group(1))
    nets = float(re.search(r'net_s=([\d.]+)', sink).group(1))
    dtw = j.get('whole_dt_s')
    nic_payload = (db - dp * 58) * 8 / (dtw * 1e6) if dtw else None
    print('%-6s fps=%-11s 板内窗=%-11s sink=%-11s NIC(载荷,整窗)=%-11s' % (
        tag, j.get('fps'),
        (('%.3f Mbps' % j['app_Mbps']) if j.get('app_Mbps') else 'NA'),
        ('%.3f Mbps' % float(re.search(r'agg_Mbps=([\d.]+)', sink).group(1))),
        (('%.3f Mbps' % nic_payload) if nic_payload else 'NA')))
    print('        P(W43/W20)=%s  idle/frm(W65/W20)=%s  WIN/frm(W66/W20)=%s  **WIN/idle(W66/W65)=%s**  W66/W64=%s  W66/W63=%s' % (
        j.get('P_W43_over_W20'), j.get('idle_per_frame_W65_over_W20'), j.get('win_per_frame_W66_over_W20'),
        j.get('win_share_of_idle_W66_over_W65'), j.get('W66_over_W64'), j.get('W66_over_W63')))
    print('        W63/frm=%s W64/frm=%s  nonidle/frm=%s  W63%%=%s W64%%=%s W65%%=%s W66%%=%s' % (
        round(j['d_W63_frmwait_cyc'] / j['d_W20_mac_tx_frames'], 6) if j.get('d_W63_frmwait_cyc') is not None and j.get('d_W20_mac_tx_frames') else None,
        round(j['d_W64_bp_cyc'] / j['d_W20_mac_tx_frames'], 6) if j.get('d_W64_bp_cyc') is not None and j.get('d_W20_mac_tx_frames') else None,
        j.get('nonidle_per_frame'),
        j.get('W63_frmwait_cyc_pct_of_cycles'), j.get('W64_bp_cyc_pct_of_cycles'),
        j.get('W65_tx_idle_pct_of_cycles'), j.get('W66_tx_winstall_pct_of_cycles')))
    pin = j.get('W66_pin')
    if pin:
        print('        W66 raw %s -> %s raw_delta=%d k=%d mono=%d | W66/W65 逐区间 n=%s min=%s med=%s max=%s' % (
            pin['raw_a'], pin['raw_b'], pin['raw_delta'], pin['k'], pin['mono_delta'],
            j.get('win_share_intervals_n'), j.get('win_share_min'), j.get('win_share_med'), j.get('win_share_max')))
    print('        RECON NIC_dPkts=%s vs whole_dW20=%s diff=%s | red(W15/W51)=%s | g_W55=%s' % (
        j.get('NIC_dPkts'), j.get('whole_dW20'), j.get('NIC_pkts_vs_W20_delta'),
        j.get('redundancy_W15_over_W51'), (j.get('g_W55_retx') or {}).get('raw_delta')))
