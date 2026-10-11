# delta_window.py -- 每个注入点前后窗的板侧计数差 (mod 2^32), 用于 R2/R3/R4 两臂对照
import sys
WORD = {"W5":0,"W20":1,"W43":2,"W51":3,"W55":4,"W57":5,"W58":6,"W66":7,"W67":8,"W69":9}
def load(p):
    rows=[]
    for line in open(p, encoding="utf-8", errors="replace"):
        line=line.strip()
        if not line or line.startswith("#"): continue
        p2=line.split()
        rows.append((float(p2[1]), [int(x,16) for x in p2[2:]]))
    return rows
def inj_times(probe_log):
    out=[]
    for line in open(probe_log, encoding="utf-8", errors="replace"):
        if line.startswith("PROBE_INJECT"):
            for kv in line.split()[1:]:
                if kv.startswith("t="): out.append(float(kv[2:]))
    return out
def d(a,b): return (b-a) & 0xFFFFFFFF
tag, series, probe = sys.argv[1], sys.argv[2], sys.argv[3]
rows = load(series); inj = inj_times(probe)
print("### %s points=%d span=%.2fs" % (tag, len(rows), rows[-1][0]-rows[0][0]))
for t in inj:
    pre = [r for r in rows if r[0] <= t-0.05]
    post= [r for r in rows if r[0] >= t+2.0]
    if not pre or not post:
        print("  inj t=%.6f : no bracket (pre=%d post=%d)" % (t, len(pre), len(post))); continue
    a=pre[-1]; b=post[0]
    print("  inj t=%.6f -> dW20=%-6d dW43=%-10d dW51=%-6d dW55=%-4d dW66=%-10d dW67=%-10d  (dt=%.2fs) W69_post=0x%08x" % (
        t, d(a[1][WORD['W20']],b[1][WORD['W20']]), d(a[1][WORD['W43']],b[1][WORD['W43']]),
        d(a[1][WORD['W51']],b[1][WORD['W51']]), d(a[1][WORD['W55']],b[1][WORD['W55']]),
        d(a[1][WORD['W66']],b[1][WORD['W66']]), d(a[1][WORD['W67']],b[1][WORD['W67']]),
        b[0]-a[0], b[1][WORD['W69']]))
r0, r1 = rows[0], rows[-1]
print("  RUN TOTAL: dW20=%d dW43=%d dW51=%d dW55=%d dW66=%d dW67=%d" % (
    d(r0[1][WORD['W20']],r1[1][WORD['W20']]), d(r0[1][WORD['W43']],r1[1][WORD['W43']]),
    d(r0[1][WORD['W51']],r1[1][WORD['W51']]), d(r0[1][WORD['W55']],r1[1][WORD['W55']]),
    d(r0[1][WORD['W66']],r1[1][WORD['W66']]), d(r0[1][WORD['W67']],r1[1][WORD['W67']])))
