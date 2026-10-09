#!/usr/bin/env python3
# summarize.py -- 把 analyze.py 的 JSON 压成一行一跑的可核表 + 打印关键守卫
import json, subprocess, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

def one(path):
    out = subprocess.run([PY, os.path.join(HERE, 'analyze.py'), path],
                         capture_output=True, text=True, encoding='utf-8').stdout.strip()
    d = json.loads(out.splitlines()[-1])
    return d

def line(d):
    f = lambda k: d.get(k)
    s = []
    s.append(f"{d.get('tag'):8s}")
    s.append(f"fps={f('fps')}")
    s.append(f"[{f('fps_min')}/{f('fps_med')}/{f('fps_max')}]")
    s.append(f"dt={f('win_dt_s')}s")
    s.append(f"app={f('app_Mbps')}Mbps")
    s.append(f"P={f('P_W43_over_W20')}")
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
        print('        SINK:', (d.get('SINK_SUM') or '')[:150])
        print('        NIC :', (d.get('GEOM_NOPCAP') or '')[:160])
        print('        LIMITS:', d.get('SINK_LIMITS'))
        print('        maxgap=%.2fs' % (d['max_gap_cyc']/156.25e6) if d.get('max_gap_cyc') else '        maxgap=n/a')
        if d.get('d_W63_frmwait_cyc') is not None:
            print('        W63=%d (%.3f%% of cyc) W64=%d (%.3f%%)  k63=%s k64=%s  dt_win=%s' % (
                d['d_W63_frmwait_cyc'], d.get('W63_frmwait_cyc_pct_of_cycles', 0) or 0,
                d['d_W64_bp_cyc'], d.get('W64_bp_cyc_pct_of_cycles', 0) or 0,
                d.get('wrap_k_W63'), d.get('wrap_k_W64'), d.get('win_dt_s')))
        print('        GUARDS(whole-chain raw_delta):', json.dumps(guards(d), ensure_ascii=False))
