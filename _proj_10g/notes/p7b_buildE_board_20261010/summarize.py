#!/usr/bin/env python3
# summarize.py -- P7B 构建 E 板级轮: 把 analyze.py 的 JSON 压成一行一跑的可核表 + 守卫
import json, subprocess, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

def one(path):
    out = subprocess.run([PY, os.path.join(HERE, 'analyze.py'), path],
                         capture_output=True, text=True, encoding='utf-8').stdout.strip()
    return json.loads(out.splitlines()[-1])

def line(d):
    f = lambda k: d.get(k)
    s = []
    s.append(f"{d.get('tag'):6s}")
    s.append(f"fps={f('fps')}")
    s.append(f"[{f('fps_min')}/{f('fps_med')}/{f('fps_max')}]")
    s.append(f"dt={f('win_dt_s')}s")
    s.append(f"P={f('P_W43_over_W20')}")
    s.append(f"idle/frm={f('idle_per_frame_W65_over_W20')}")
    s.append(f"nonidle/frm={f('nonidle_per_frame')}")
    s.append(f"idle_duty={f('idle_duty_W65_over_W5')}")
    # ---- ⭐ 本轮核心: W66 ----
    s.append(f"WIN/frm={f('win_per_frame_W66_over_W20')}")
    s.append(f"WIN/idle={f('win_share_of_idle_W66_over_W65')}")
    s.append(f"W66/W64={f('W66_over_W64')}")
    s.append(f"W66/W63={f('W66_over_W63')}")
    d63, d64, d20 = f('d_W63_frmwait_cyc'), f('d_W64_bp_cyc'), f('d_W20_mac_tx_frames')
    if d63 is not None and d20: s.append(f"W63/frm={round(d63/d20,6)}")
    if d64 is not None and d20: s.append(f"W64/frm={round(d64/d20,6)}")
    s.append(f"app={f('app_Mbps')}Mbps")
    s.append(f"red={f('redundancy_W15_over_W51')}")
    s.append(f"nff={d.get('nff_total')} snaps={d.get('n_snaps')}")
    return ' '.join(s)

def guards(d):
    ks = [k for k in d if k.startswith('g_')]
    out = {}
    for k in ks:
        v = d[k]
        out[k[2:]] = v['raw_delta']
    return out

if __name__ == '__main__':
    for p in sys.argv[1:]:
        d = one(p)
        print(line(d))
        print('        GEOM:', d.get('geom'), '| CARRIER:', d.get('CARRIER'))
        print('        SINK:', (d.get('SINK_SUM') or '')[:190])
        print('        NIC :', (d.get('GEOM_NOPCAP') or '')[:170])
        print('        RECON: whole dW20=%s NIC dPkts=%s diff=%s | NIC/W20=%s' % (
            d.get('whole_dW20'), d.get('NIC_dPkts'), d.get('NIC_pkts_vs_W20_delta'), d.get('NIC_pkts_over_W20')))
        print('        W63=%s (%s%%) W64=%s (%s%%) W65=%s (%s%%) W66=%s (%s%%)  idle/frame med=%s max=%s  nonidle/frame med=%s' % (
            d.get('d_W63_frmwait_cyc'), d.get('W63_frmwait_cyc_pct_of_cycles'),
            d.get('d_W64_bp_cyc'), d.get('W64_bp_cyc_pct_of_cycles'),
            d.get('d_W65_tx_idle'), d.get('W65_tx_idle_pct_of_cycles'),
            d.get('d_W66_tx_winstall'), d.get('W66_tx_winstall_pct_of_cycles'),
            d.get('idle_per_frame_med'), d.get('idle_per_frame_max'), d.get('nonidle_per_frame_med')))
        print('        WIN_PIN:', json.dumps(d.get('W66_pin'), ensure_ascii=False),
              'win_share intervals n=%s min=%s med=%s max=%s' % (
                  d.get('win_share_intervals_n'), d.get('win_share_min'),
                  d.get('win_share_med'), d.get('win_share_max')))
        print('        TRI:', json.dumps(d.get('tri_check'), ensure_ascii=False))
        print('        WINRAWK:', json.dumps(d.get('win_rawk'), ensure_ascii=False))
        print('        GUARDS(whole-chain raw_delta):', json.dumps(guards(d), ensure_ascii=False))
