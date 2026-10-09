#!/usr/bin/env python3
# derive.py -- P7B-A7: 逐跑的**线占空(%)** 两种独立口径 + NIC/sink/板三口径速率
#   口径1 (几何): 192.25 / P   —— 1538 B/帧 (8 前导 + 1518 + 12 IFG) = 192.25 个 8B 字
#   口径2 (NIC): (Δbytes + Δpkts×20)×8 / (net_s × 10e9)  —— 20 B/帧 = 8 前导 + 12 IFG
#   ⚠️ 口径2 完全独立于板侧计数器 (对端网卡硬件计数); 两者应到 ppm 级一致。
import json, re, sys, os

def getline(path, pat):
    for ln in open(path, encoding='utf-8', errors='replace'):
        if re.match(pat, ln): return ln.strip()
    return None

for tag in sys.argv[1:]:
    j = json.loads(open('runs/%s.json' % tag, encoding='utf-8').read().strip().splitlines()[-1])
    raw = 'runs/%s.txt' % tag
    nic = getline(raw, r'^GEOM_NOPCAP')
    sink = getline(raw, r'^SINK_SUM')
    db = int(re.search(r'd_bytes=(\d+)', nic).group(1))
    dp = int(re.search(r'd_pkts=(\d+)', nic).group(1))
    bp = float(re.search(r'bytes_per_pkt=([\d.]+)', nic).group(1))
    nets = float(re.search(r'net_s=([\d.]+)', sink).group(1))
    P = j['P_W43_over_W20']
    util_geom = 192.25 / P                      # 流内 (板侧 P): 线上占空 (含前导+IFG 的 1538B/帧 口径)
    dt_flow = j['win_dt_s']; dt_whole = j['whole_dt_s']
    # NIC 自己的窗 (whole: pre2 -> post2, 其跨度 = 板侧 whole_dt; 其中含流外空闲) —— 只与**同窗**比
    util_nic_whole = (db + dp * 20) * 8 / (dt_whole * 1e9)
    nic_payload_Mbps = (db - dp * 58) * 8 / dt_whole / 1e6
    print('%-6s P=%-9s 流内线占空(几何 192.25/P)=%.6f (=%.4f Gbps @10G)' % (tag, P, util_geom, util_geom * 10))
    print('        NIC 整窗({:.3f}s, 含流外空闲) 线占空={:.6f} (= {:.4f} Gbps); 流窗/整窗={:.6f}'
          ' -> 折算到流内={:.4f} Gbps (=ppm diff {:.0f})'.format(
              dt_whole, util_nic_whole, util_nic_whole, dt_flow / dt_whole,
              util_nic_whole * (dt_whole / dt_flow), (util_nic_whole * (dt_whole / dt_flow) / (util_geom * 10) - 1) * 1e6))
    print('        NIC_bytes/pkt=%.6f | NIC_payload(整窗)=%.3f Mbps | sink=%.3f | app(流窗)=%.3f | fps=%s' % (
        bp, nic_payload_Mbps, float(re.search(r'agg_Mbps=([\d.]+)', sink).group(1)), j['app_Mbps'], j['fps']))
    tc = j.get('tri_check')
    if tc:
        print('        tri: sum(dW65+dW43)=%s vs dW5=%s  ratio=%.8f  (k_W65=%s raw_delta_W65=%s)' % (
            tc['sum_dW65_dW43'], tc['dW5'], tc['ratio_sum_over_dW5'], tc['k_W65'], tc['raw_delta_W65']))
        print('        W43/ΔW5 ppm=%.2f  |  ΔW65/ΔW5=%.8f  ΔW65/ΔW43=%.8f  ΔW65/ΔW20=%.6f' % (
            j['W43_over_W5_ppm'], j['idle_duty_W65_over_W5'], j['idle_duty_W65_over_W43'], j['idle_per_frame_W65_over_W20']))
