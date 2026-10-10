#!/usr/bin/env python3
# ctr_delta.py -- 把 /tmp/mw_<TAG>_ctr.log 的逐点采样折成 首/末 差; 并输出"变化点"时刻
#   用法: python ctr_delta.py runs/<TAG>_ctr.log [nz|all|key]
import re, sys

def load(path):
    rows, cur, t = [], {}, None
    for line in open(path, errors="replace"):
        m = re.match(r"CTR_T ([0-9.]+)", line.strip())
        if m:
            if t is not None:
                rows.append((t, cur))
            t = float(m.group(1)); cur = {}
            continue
        p = line.split()
        if len(p) >= 2:
            try: cur[p[0]] = int(p[1])
            except ValueError: pass
    if t is not None:
        rows.append((t, cur))
    return rows

def main():
    path = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "nz"
    rows = load(path)
    if not rows:
        print("EMPTY %s" % path); return
    t0 = rows[0][0]
    a, b = rows[0][1], rows[-1][1]
    print("# samples=%d span=%.2fs  (%s)" % (len(rows), rows[-1][0]-t0, path))
    keys = sorted(set(a) | set(b))
    if mode == "all":
        for k in keys:
            print("%-30s %14d -> %14d  d=%d" % (k, a.get(k, 0), b.get(k, 0), b.get(k, 0)-a.get(k, 0)))
    else:
        for k in keys:
            d = b.get(k, 0) - a.get(k, 0)
            if d != 0:
                print("%-30s %14d -> %14d  d=%+d" % (k, a.get(k, 0), b.get(k, 0), d))
    if mode == "key":
        pass
    # 变化点 (谁在什么时候动了) —— 只对"本轮关心"的计数器
    watch = ["TcpExtTCPZeroWindowDrop", "TcpExtTCPRcvQDrop", "TcpExtTCPOFOQueue", "TcpExtTCPOFODrop",
             "TcpExtTCPFromZeroWindowAdv", "TcpExtTCPToZeroWindowAdv", "TcpExtTCPWantZeroWindowAdv",
             "TcpInSegs", "TcpOutSegs", "TcpRetransSegs", "TcpInErrs", "TcpExtTCPAckCompressed",
             "TcpExtOfoPruned", "TcpExtRcvPruned", "TcpExtPruneCalled", "TcpExtTCPMemoryPressures"]
    print("-- 变化点 (t_rel, 计数器, 值) --")
    prev = dict(a)
    for t, r in rows[1:]:
        for k in watch:
            if k in r and r[k] != prev.get(k):
                print("  %7.3f  %-30s %d -> %d" % (t-t0, k, prev.get(k, 0), r[k]))
                prev[k] = r[k]

if __name__ == "__main__":
    main()
