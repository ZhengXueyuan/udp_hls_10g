# an_up.py -- P7B 上行天花板轮 读数分析器 (2026-10-10)
#   输入: up_ceil.sh 的输出文件 (含 LF_SNAP_T / SNAP_BEGIN tag=..._sN gen=/ W<num> <addr> <name> <hex>)
#   口径:
#     * 每对相邻点 = 一个区间; 时基 dt = ΔW5/156.25e6 (W5 = gmii_free_FE, 自由计数, 27.487 s 回绕)
#     * 所有 Δ 一律 mod 2^32, 同时落 raw(A,B) 与回卷次数 k (k 由 (A + Δ) >= 2^32 推出, Δ < 2^32)
#     * 速率 = ΔW*8/dt; 上行 = W53 (app_rx_bytes) / 下行 = W51 (app_tx_bytes)
#     * P = ΔW43/ΔW20 (每帧拍数, 线几何 193); **193/P = 换算, 不是线占空测量**
#       (⛔ 2026-10-10 口径订正: W43 每拍无条件 +1 (mac_tx_10g.v:330, 在 case(state) 之外) ⇒
#        P ≡ 156.25e6/fps ⇒ 193/P 只是"fps 未达几何上限"的换算式; 板侧无线占空计数器;
#        ⚠️ 本脚本打印表头仍写 "duty%" —— 本轮只改注释不改逻辑, 引用输出时按本行读)
#   ⚠️ 区间 dt > 3.0 s 打红旗 (可能跨多次回卷而不可判)
import re, sys

WRAP = 2**32
TB = 156.25e6
# 上行/下行/背景词
UP, DOWN = 53, 51

def parse(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    snaps, cur = [], None
    tmap = {}
    for line in txt.splitlines():
        m = re.match(r'^LF_SNAP_T (\S+) (\d+)$', line)
        if m:
            tmap[int(m.group(2))] = float(m.group(1)); continue
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', line)
        if m:
            tag = m.group(1)
            mm = re.search(r'_s(\d+)$', tag)
            cur = {'tag': tag, 'gen': int(m.group(2)),
                   'idx': int(mm.group(1)) if mm else None, 'w': {},
                   't': tmap.get(int(mm.group(1))) if mm else None}
            snaps.append(cur); continue
        m = re.match(r'^W(\d+)\s+0x[0-9A-Fa-f]+\s+(\S+)\s+(0x[0-9a-fA-F]+)', line)
        if m and cur is not None:
            cur['w'][int(m.group(1))] = int(m.group(3), 16)
        if line.startswith('SNAP_END'):
            cur = None
    return snaps, txt

def dd(a, b):
    """差值 mod 2^32; 返回 (delta, k) —— k = 回卷次数 (假定 delta < 2^32)"""
    x = (b - a) % WRAP
    k = 1 if (a + x) >= WRAP else 0
    return x, k

def main():
    for path in sys.argv[1:]:
        snaps, txt = parse(path)
        pts = [s for s in snaps if s['idx'] is not None and 5 in s['w']]
        pts.sort(key=lambda s: s['idx'])
        print('=' * 100)
        print('# FILE %s   points=%d' % (path, len(pts)))
        meta = [l for l in txt.splitlines() if l.startswith(('COALESCE=', 'UP_META_SRC_BIN=', 'NIC_PRE', 'NIC_POST',
                                                             'ROUTE=', 'CARRIER=', 'UP_META_SCRIPT_MD5=', 'ID_BID',
                                                             'ID_FAIL', 'ETHSTAT'))]
        for l in meta:
            print('# META %s' % l)
        hdr = ('# i->i+1  dt_ms   kW5  |  dW53(raw A->B, k)      UP_Mbps   |  dW51(raw A->B, k)     DOWN_Mbps  |'
               '  dW52    dW20    P=dW43/dW20  duty%  dW15      dW23  dW21  dW55  dW62  dW61  dW0/dW1')
        print(hdr)
        for i in range(len(pts) - 1):
            A, B = pts[i], pts[i + 1]
            d5, k5 = dd(A['w'][5], B['w'][5])
            if d5 == 0:
                continue
            dt = d5 / TB
            flag = '  <<<dt>3.0s' if dt > 3.0 else ''
            row = {}
            for w in (53, 51, 52, 20, 43, 15, 14, 23, 21, 55, 62, 61, 0, 1, 54):
                if w in A['w'] and w in B['w']:
                    row[w] = dd(A['w'][w], B['w'][w])
                else:
                    row[w] = (0, 0)
            up46 = row[53][0] * 8.0 / dt / 1e6
            dn46 = row[51][0] * 8.0 / dt / 1e6
            P = (row[43][0] / row[20][0]) if row[20][0] else 0.0
            print('%2d->%2d  %7.1f  k%d  |  %10d->%-10d k%d  %9.3f  |  %10d->%-10d k%d  %9.3f  |'
                  '  %6d  %6d  %10.3f  %6.1f  %10d  %5d  %5d  %5d  %5d  %5d  %s'
                  % (i, i + 1, dt * 1000, k5,
                     A['w'][53], B['w'][53], row[53][1], up46,
                     A['w'][51], B['w'][51], row[51][1], dn46,
                     row[52][0], row[20][0], P, (193.0 / P * 100 if P else 0),
                     row[15][0], row[23][0], row[21][0], row[55][0],
                     row[62][0], row[61][0],
                     '%d/%d' % (row[0][0], row[1][0])) + flag)
        # 汇总: 全窗 (第一点 -> 最后一点), 用逐区间求和 (每区间 mod 2^32 后可判)
        tot_up = sum(dd(pts[i]['w'][53], pts[i + 1]['w'][53])[0] for i in range(len(pts) - 1))
        tot_dn = sum(dd(pts[i]['w'][51], pts[i + 1]['w'][51])[0] for i in range(len(pts) - 1))
        tot_t5 = sum(dd(pts[i]['w'][5], pts[i + 1]['w'][5])[0] for i in range(len(pts) - 1))
        dt_all = tot_t5 / TB
        nk53 = sum(dd(pts[i]['w'][53], pts[i + 1]['w'][53])[1] for i in range(len(pts) - 1))
        nk51 = sum(dd(pts[i]['w'][51], pts[i + 1]['w'][51])[1] for i in range(len(pts) - 1))
        print('# SUM(WINDOW s%d..s%d): dt=%.3f s  UP=%d B (k=%d) = %.3f Mbps  DOWN=%d B (k=%d) = %.3f Mbps'
              % (pts[0]['idx'], pts[-1]['idx'], dt_all, tot_up, nk53, tot_up * 8.0 / dt_all / 1e6,
                 tot_dn, nk51, tot_dn * 8.0 / dt_all / 1e6))
        # 稳态窗 (丢掉首末两点: 首点含起流斜坡, 末点含收流; 与对端工具的自报口径可比)
        if len(pts) >= 4:
            st = pts[1:-1]
            t_up = sum(dd(st[i]['w'][53], st[i + 1]['w'][53])[0] for i in range(len(st) - 1))
            t_dn = sum(dd(st[i]['w'][51], st[i + 1]['w'][51])[0] for i in range(len(st) - 1))
            t_5 = sum(dd(st[i]['w'][5], st[i + 1]['w'][5])[0] for i in range(len(st) - 1))
            k_up = sum(dd(st[i]['w'][53], st[i + 1]['w'][53])[1] for i in range(len(st) - 1))
            k_dn = sum(dd(st[i]['w'][51], st[i + 1]['w'][51])[1] for i in range(len(st) - 1))
            dt_s = t_5 / TB
            print('# SUM_STEADY(s%d..s%d): dt=%.3f s  UP=%d B (k=%d) = %.3f Mbps  DOWN=%d B (k=%d) = %.3f Mbps  SUM=%.3f Gbps'
                  % (st[0]['idx'], st[-1]['idx'], dt_s, t_up, k_up, t_up * 8.0 / dt_s / 1e6,
                     t_dn, k_dn, t_dn * 8.0 / dt_s / 1e6, (t_up + t_dn) * 8.0 / dt_s / 1e9))
        # 尾点单点读数 (raw)
        last = pts[-1]
        print('# LASTPOINT s%d: W53=0x%08X W51=0x%08X W54=0x%08X W52=0x%08X W5=0x%08X gen=%d'
              % (last['idx'], last['w'][53], last['w'][51], last['w'].get(54, 0), last['w'][52],
                 last['w'][5], last['gen']))
        # 守卫全窗汇总 (第一点 -> 最后点, 逐区间求和; 每区间 mod 2^32 可判)
        GUARD = {54: 'app_mismatch', 23: 'rx_nonmatch_TCP', 21: 'tx_stat_abort', 4: 'rx_stat_drop',
                 3: 'rx_stat_crc_err', 35: 'rx_stat_fifo_ovf', 41: 'mtx_flush_words', 42: 'mtx_flush_done',
                 45: 'txcdc_ovf_cnt', 59: 'stx_fifo_ovf', 60: 'srx_fifo_ovf', 38: 'rxcdc_ovf_cnt',
                 55: 'tx_stat_retx', 61: 'stat_wu', 52: 'app_tx_frames', 0: 'rx_stat_frames', 1: 'rx_stat_bytes'}
        print('# --- 全窗守卫/背景 (W%3s 名 : 首值 -> 尾值 (k)  = 总增量)' % '号')
        for w, name in sorted(GUARD.items()):
            if w in pts[0]['w'] and w in pts[-1]['w']:
                tot = sum(dd(pts[i]['w'][w], pts[i + 1]['w'][w])[0] for i in range(len(pts) - 1))
                nk = sum(dd(pts[i]['w'][w], pts[i + 1]['w'][w])[1] for i in range(len(pts) - 1))
                print('# W%-3d %-18s %10d -> %-10d (k=%d) 总增 %d' % (w, name, pts[0]['w'][w], pts[-1]['w'][w], nk, tot))
        # 极值词 (max) —— occ_max 类
        for w, name in ((27, 'rxcdc_occ_max'), (28, 'txcdc_occ_max'), (29, 'txwire_stall_cycles'), (26, 'rxcdc_full_cycles')):
            vals = [s['w'][w] for s in pts if w in s['w']]
            if vals:
                print('# MAX W%-3d %-18s min=0x%08X max=0x%08X' % (w, name, min(vals), max(vals)))

if __name__ == '__main__':
    main()
