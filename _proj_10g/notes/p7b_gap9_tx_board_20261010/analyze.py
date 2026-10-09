#!/usr/bin/env python3
# analyze.py -- P7b-GAP9-TX 板级轮 (2026-10-10) 原始 run 解析器
#   纪律 (本工程"读数"三条硬要求):
#     1. fps = ΔW20/(ΔW5/156.25e6) 是**主判据**; P = ΔW43/ΔW20 只是等价换算
#        (W43 每拍无条件 +1 ⇒ ΔW43 ≡ ΔW5 ⇒ P ≡ 156.25e6/fps 是恒等式, **不叫线占空**)
#     2. 所有板侧计数器 32 位 ⇒ Δ 一律 mod 2^32, 记 raw 与回卷次数 k
#     3. W63/W64 与 fps **同窗**取; W64 不许单独读成"帧器背压"(帧器侧无计数器)
#   ⚠️ 链条法: pre → s0 → ... → sN → post 逐点**单调 unwrap** (相邻点间隔 << 27.487 s
#      ⇒ 每个计数器的回卷由"值变小"唯一判定), 再与墙钟交叉核对 ΔW5 (独立见证)。
import re, sys, json, statistics as st

FCLK = 156.25e6
MOD  = 1 << 32

def parse(path):
    """返回 {'snaps': [(tag, gen, t_wall, {w:val})...], 'lines': [...]}"""
    snaps = []; lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    cur = None; curtag = None; curnff = None
    pend_t = None
    for ln in lines:
        m = re.match(r'^LF_SNAP_T\s+([0-9.]+)\s+(\d+)$', ln)
        if m: pend_t = float(m.group(1)); continue
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', ln)
        if m: cur = {}; curtag = m.group(1); curgen = int(m.group(2)); continue
        m = re.match(r'^SNAP_END (\S+) nff=(\d+)', ln)
        if m:
            if cur is not None and curnff != 0 and m.group(2) != '0':
                pass
            snaps.append((curtag, curgen, pend_t, cur, int(m.group(2))))
            cur = None; pend_t = None; curnff = int(m.group(2)); continue
        m = re.match(r'^W(\d+)\s+(0x[0-9A-Fa-f]+)\s+(\S+)\s+(0x[0-9a-fA-F]+|\?)$', ln)
        if m and cur is not None:
            v = m.group(4)
            if v.startswith('0x'): cur[int(m.group(1))] = int(v, 16)
            continue
    return snaps, lines

def getline(lines, pat, grp=None):
    for ln in lines:
        if re.match(pat, ln): return ln
    return None

def valof(lines, key):
    for ln in lines:
        m = re.match(r'^\s*' + re.escape(key) + r':\s+(\d+)', ln)
        if m: return int(m.group(1))
    return None

def unwrap_chain(snaps, words):
    """按文件出现顺序把 words 里的计数器单调 unwrap (mod 2^32)。返回 {w: [unwrapped...]}"""
    out = {w: [] for w in words}
    for w in words:
        last = None; k = 0
        for (_tag, _g, _t, d, _n) in snaps:
            if w not in d:             # 该字不在本次 snap 的字表里
                out[w].append(None); continue
            v = d[w]
            if last is not None and v < last: k += 1
            out[w].append(v + k * MOD); last = v
    return out

def win(snaps, uw, a, b, w):
    """窗口 [a,b] (含端点) 的 Δ (未回卷域)"""
    va, vb = uw[w][a], uw[w][b]
    if va is None or vb is None: return None
    return vb - va

def main(paths):
    for path in paths:
        snaps, lines = parse(path)
        tag0 = snaps[0][0].rsplit('_', 1)[0] if snaps else '?'
        res = {'file': path, 'tag': tag0, 'n_snaps': len(snaps)}
        res['nff_total'] = sum(s[4] for s in snaps)
        # 元数据
        for k in ('LF_META_BID_EXPECT', 'LF_META_SINK_EXTRA', 'LF_META_SECS', 'LF_META_SNAP_MD5',
                  'LF_META_SCRIPT_MD5', 'LF_META_SINK_MD5', 'LF_META_BOARD_BID_PRE'):
            ln = getline(lines, r'^' + k + r'=')
            res[k] = ln.split('=', 1)[1] if ln else None
        ln = getline(lines, r'^SINK_LIMITS')
        res['SINK_LIMITS'] = ln
        ln = getline(lines, r'^LF_GEOM_OK|^LF_GEOM_FAIL')
        res['geom'] = ln
        ln = getline(lines, r'^CARRIER=')
        res['CARRIER'] = ln
        ln = getline(lines, r'^SINK_SUM')
        res['SINK_SUM'] = ln
        ln = getline(lines, r'^SINK_CONN')
        res['SINK_CONN'] = ln
        ln = getline(lines, r'^GEOM_NOPCAP_NIC_rx')
        res['GEOM_NOPCAP'] = ln
        cc = getline(lines, r'^LF_SNAP_MAXREACHED')
        res['MAXREACHED'] = cc

        words = [5, 20, 43, 51, 15, 52, 55, 57, 58, 61, 62, 63, 64, 21, 23, 35, 41, 42, 45, 59, 60,
                 0, 1, 4, 14, 22, 53, 54, 36, 37, 44, 3, 19]
        uw = unwrap_chain(snaps, words)
        # 相邻点间隔单调性见证
        gaps = []
        for i in range(1, len(snaps)):
            d5 = (uw[5][i] - uw[5][i-1]) if (uw[5][i] is not None and uw[5][i-1] is not None) else None
            gaps.append(d5)
        res['min_gap_cyc'] = min([g for g in gaps if g is not None], default=None)
        res['max_gap_cyc'] = max([g for g in gaps if g is not None], default=None)
        res['wrap_k_W5'] = (uw[5][-1] - snaps[-1][3][5]) // MOD if snaps[-1][3].get(5) is not None else None
        res['wrap_k_W51'] = (uw[51][-1] - snaps[-1][3][51]) // MOD if snaps[-1][3].get(51) is not None else None
        if 63 in snaps[-1][3] and snaps[-1][3].get(63) is not None:
            res['wrap_k_W63'] = (uw[63][-1] - snaps[-1][3][63]) // MOD
            res['wrap_k_W64'] = (uw[64][-1] - snaps[-1][3][64]) // MOD

        # 内窗活性: 逐点间隔的帧增量 -> 逐区间 fps -> **平台法**定窗
        #   ⚠️ 为什么不用"活跃阈值": pre -> s0 的间隔**混了流前空闲** (稀释), 但仍 > 1000 帧
        #      ⇒ 会把流前时间算进窗口 (实测在旧短跑上把 410k fps 稀释成 108k)。
        #   平台 = fps >= 0.5 * max(fps) 的**最长连续区间段**; 窗口端点 = 该段的首点 .. 末点后一点。
        act = []
        for i in range(1, len(snaps)):
            d20 = uw[20][i] - uw[20][i-1]; d5 = uw[5][i] - uw[5][i-1]
            fps_i = d20 / (d5 / FCLK) if d5 > 0 else 0.0
            act.append((fps_i, d20, d5))
        fmax = max([x[0] for x in act], default=0.0)
        res['fps_peak_interval'] = round(fmax, 1)
        if fmax <= 0:
            res['error'] = 'no active interval'; print(json.dumps(res, ensure_ascii=False)); continue
        good = [x[0] >= 0.5 * fmax for x in act]
        best = (0, -1); cur = None
        for j, g in enumerate(good):
            if g and cur is None: cur = j
            if (not g or j == len(good) - 1) and cur is not None:
                e = j if not g else j + 1
                if e - cur > best[1] - best[0]: best = (cur, e)
                cur = None
        i1, i2 = best[0], best[1] - 1     # 区间段 [i1..i2]
        idx = list(range(i1 + 1, i2 + 2))
        res['plateau_intervals'] = [i1, i2]
        res['plateau_frac_of_run'] = round((i2 - i1 + 1) / max(1, len(act)), 4)
        a = i1; b = i2 + 1                # 窗口端点 = 平台首点 .. 平台末区间的后一点
        res['win_a'] = a; res['win_b'] = b
        res['win_a_tag'] = snaps[a][0]; res['win_b_tag'] = snaps[b][0]
        d5 = win(snaps, uw, a, b, 5); dt = d5 / FCLK
        res['win_dt_s'] = round(dt, 6)
        res['win_dW5'] = d5
        res['wall_a'] = snaps[a][2]; res['wall_b'] = snaps[b][2]
        if snaps[a][2] and snaps[b][2]:
            res['win_wall_s'] = round(snaps[b][2] - snaps[a][2], 6)
            res['dt_vs_wall_ppm'] = round((dt / (snaps[b][2] - snaps[a][2]) - 1) * 1e6, 1)

        for w, nm in ((20, 'W20_mac_tx_frames'), (51, 'W51_app_tx_bytes'), (43, 'W43_mtx_tx_words'),
                      (15, 'W15_tcp_fastpath_bytes'), (52, 'W52_app_tx_frames'), (55, 'W55_retx'),
                      (63, 'W63_frmwait_cyc'), (64, 'W64_bp_cyc'), (53, 'W53_app_rx_bytes'),
                      (14, 'W14_tcp_fastpath_frames'), (54, 'W54_app_mismatch'), (61, 'W61_stat_wu'),
                      (62, 'W62_rx_occ'), (21, 'W21_tx_abort'), (23, 'W23_nonmatch'), (35, 'W35_rx_fifo_ovf'),
                      (41, 'W41_flush_words'), (42, 'W42_flush_done'), (45, 'W45_txcdc_ovf'),
                      (59, 'W59_stx_fifo_ovf'), (60, 'W60_srx_fifo_ovf'), (0, 'W0_rx_frames'),
                      (1, 'W1_rx_bytes'), (3, 'W3_crc_err'), (4, 'W4_rx_drop'), (36, 'W36_xgmii_words'),
                      (37, 'W37_rx_delivered')):
            d = win(snaps, uw, a, b, w)
            if d is not None:
                res['d_' + nm] = d
                raw_a = snaps[a][3].get(w); raw_b = snaps[b][3].get(w)
                res['raw_' + nm] = [hex(raw_a) if raw_a is not None else None,
                                    hex(raw_b) if raw_b is not None else None]
        # ---- ⚠️ W51/W15 回卷消歧 (本轮实测的**必要**步骤) -------------------------------
        #   病情: W51 在 9.3 Gbps 下 **3.70 s** 回卷一次 (2^32 / 1.162 GB/s); 而快照间隔在
        #   流快时实测退化到 7.74 s (> 3.70 s) ⇒ 单调 unwrap **结构性漏计回卷**
        #   (A2 实测: 单调法 18 圈 / 真值 23 圈 ⇒ 少算 21.5 GB = 21.5%).
        #   消歧 = 用**另一台仪器**把 k 钉死:
        #     (a) 窗口内 帧数 × 1460 B (W20 不回卷; app 的帧/载荷合同) —— 用于平台窗
        #     (b) 对端 sink 自报的 64 位字节数 (真正独立) —— 用于整链
        #   两者都给出 k 候选; 一致才采信。不许只报单调法。
        FRM = 1460
        d20 = res.get('d_W20_mac_tx_frames')
        def pin(w):
            ra = snaps[a][3].get(w); rb = snaps[b][3].get(w)
            if ra is None or rb is None: return None
            rawd = (rb - ra) % MOD
            mono = win(snaps, uw, a, b, w)
            out = {'raw_a': hex(ra), 'raw_b': hex(rb), 'raw_delta': rawd,
                   'mono_delta': mono, 'k_mono': (mono - rawd) // MOD if mono is not None else None}
            if d20:
                kf = int(round((d20 * FRM - rawd) / MOD))
                out['k_from_frames'] = kf
                out['delta_from_frames'] = rawd + kf * MOD
                out['frames_vs_pinned_ppm'] = round((out['delta_from_frames'] / (d20 * FRM) - 1) * 1e6, 1) if d20 else None
            return out
        res['W51_pin'] = pin(51); res['W15_pin'] = pin(15)
        d51 = None
        if res['W51_pin'] and 'delta_from_frames' in res['W51_pin']:
            d51 = res['W51_pin']['delta_from_frames']
            res['d_W51_app_tx_bytes_pinned'] = d51
        if d20: res['fps'] = round(d20 / dt, 1)
        if d51: res['app_Mbps'] = round(d51 * 8 / dt / 1e6, 3)
        d43 = res.get('d_W43_mtx_tx_words'); d15 = res.get('d_W15_tcp_fastpath_bytes')
        if d43 and d20:
            res['P_W43_over_W20'] = round(d43 / d20, 4)
            res['P_identity_check'] = round(FCLK / res['fps'], 4)
            # ⚠️ W43 在 **DP** 域 (MMCM), W5 在 **FE** 域 (CDR 恢复钟) —— 两源名义同为 156.25 MHz
            #    但实际频率差 ppm 级 ⇒ ΔW43/ΔW5 不恒为 1 ⇒ 只期望"到 ppm 级相等"。
            res['W43_over_W5_ppm'] = round((d43 / d5 - 1) * 1e6, 2) if d5 else None
            res['P_equals_identity_rel'] = round((d43 / d20) / (FCLK / res['fps']), 9)
        if d43: res['W43_Mbps_wire_words'] = round(d43 * 8 / dt / 1e6, 3)
        # ⚠️ 冗余率必须用 **pinned** 两个值 (单调法在流快时会漏圈 ⇒ 会算出 0.78 这种 <1 的假值)
        p15 = res.get('W15_pin') or {}; p51 = res.get('W51_pin') or {}
        if 'delta_from_frames' in p15 and 'delta_from_frames' in p51:
            res['redundancy_W15_over_W51'] = round(p15['delta_from_frames'] / p51['delta_from_frames'], 6)
        elif d15 and d51:
            res['redundancy_W15_over_W51'] = round(d15 / d51, 6)
        for w, nm in ((63, 'W63_frmwait_cyc'), (64, 'W64_bp_cyc')):
            d = res.get('d_' + nm)
            if d is not None:
                res[nm + '_pct_of_cycles'] = round(100.0 * d / d5, 4)
        # 逐区间 fps 分布 (仅活跃区间)
        per = []
        for i in idx:
            dd20 = act[i-1][1]; dd5 = act[i-1][2]
            per.append(dd20 / (dd5 / FCLK))
        if per:
            per_sorted = sorted(per)
            res['fps_intervals_n'] = len(per)
            res['fps_min'] = round(per_sorted[0], 1)
            res['fps_med'] = round(st.median(per_sorted), 1)
            res['fps_max'] = round(per_sorted[-1], 1)
        # 全跑 (pre -> post, 含流外时间; 仅作参考) + **守卫字全链差** (守卫只在 full 快照里,
        # 不在内窗字表里 ⇒ 平台窗里取不到; 全链差 = 覆盖面更大、更保守: 任何非 0 增量都要解释)
        if len(snaps) > 1:
            A0, B0 = 0, len(snaps) - 1
            d5t = win(snaps, uw, A0, B0, 5)
            if d5t:
                res['whole_dt_s'] = round(d5t / FCLK, 6)
                d20t = win(snaps, uw, A0, B0, 20)
                if d20t: res['whole_fps'] = round(d20t / (d5t / FCLK), 1)
            # 守卫 (含用户点名的 W21/23/35/41/42/45/59/60) + 相关字
            guards = {21: 'W21_tx_abort', 23: 'W23_nonmatch', 35: 'W35_rx_fifo_ovf',
                      41: 'W41_flush_words', 42: 'W42_flush_done', 45: 'W45_txcdc_ovf',
                      59: 'W59_stx_fifo_ovf', 60: 'W60_srx_fifo_ovf',
                      0: 'W0_rx_frames', 1: 'W1_rx_bytes', 3: 'W3_crc_err', 4: 'W4_rx_drop',
                      13: 'W13_udpapp_mismatch', 54: 'W54_app_mismatch', 55: 'W55_retx',
                      56: 'W56_udpapp_tx_ovf', 57: 'W57_retx_hi', 58: 'W58_retx_active',
                      61: 'W61_stat_wu', 62: 'W62_rx_occ', 14: 'W14_tcp_frames',
                      15: 'W15_tcp_bytes', 20: 'W20_mac_tx_frames', 22: 'W22_pass',
                      44: 'W44_ctrl_char', 36: 'W36_xgmii_words', 37: 'W37_rx_delivered'}
            for w, nm in guards.items():
                if snaps[0][3].get(w) is None or snaps[-1][3].get(w) is None: continue
                if w not in uw: uw[w] = unwrap_chain(snaps, [w])[w]   # 该字不在主字表里时补算

                ra, rb = snaps[0][3][w], snaps[-1][3][w]
                d = win(snaps, uw, A0, B0, w)
                res['g_' + nm] = {'raw_a': hex(ra), 'raw_b': hex(rb),
                                  'raw_delta': (rb - ra) % MOD, 'k_mono': (d - (rb - ra) % MOD) // MOD,
                                  'mono_delta': d}
        print(json.dumps(res, ensure_ascii=False))

if __name__ == '__main__':
    main(sys.argv[1:])
