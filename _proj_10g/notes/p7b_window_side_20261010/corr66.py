#!/usr/bin/env python3
# corr66.py -- P7B 构建 E 板级轮: 逐区间相关 (超集 = 上一轮 corr63.py + W66)
#   每区间 (相邻两个快照点, 只取流内点): idle/frm=ΔW65/ΔW20, W66/frm, W64/frm, W63/frm, W66/W65
#   ⚠️ 只报读数, 不下结论。
import re, sys, statistics as st
FCLK=156.25e6; MOD=1<<32

def parse(path):
    snaps=[]; cur=None; tag=None
    for ln in open(path, encoding='utf-8', errors='replace'):
        m=re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', ln)
        if m: cur={}; tag=m.group(1); continue
        m=re.match(r'^SNAP_END (\S+)', ln)
        if m: snaps.append((tag,cur)); cur=None; continue
        m=re.match(r'^W(\d+)\s+(0x[0-9A-Fa-f]+)\s+\S+\s+(0x[0-9a-fA-F]+|\?)$', ln)
        if m and cur is not None:
            v=m.group(3)
            if v.startswith('0x'): cur[int(m.group(1))]=int(v,16)
    return snaps

def uw(snaps,w):
    out=[];last=None;k=0
    for (_t,d) in snaps:
        if w not in d: out.append(None); continue
        v=d[w]
        if last is not None and v<last: k+=1
        out.append(v+k*MOD); last=v
    return out

def pear(a,b):
    ma,mb=st.mean(a),st.mean(b)
    num=sum((p-ma)*(q-mb) for p,q in zip(a,b))
    den=(sum((p-ma)**2 for p in a)*sum((q-mb)**2 for q in b))**0.5
    return num/den if den else float('nan')

for path in sys.argv[1:]:
    snaps=parse(path)
    U={w:uw(snaps,w) for w in (5,20,43,63,64,65,66)}
    rows=[]   # (idle/frm, W66/frm, W64/frm, W63/frm, W66/W65, share66_duty)
    for i in range(1,len(snaps)):
        if None in (U[65][i],U[65][i-1],U[64][i],U[64][i-1],U[20][i],U[20][i-1]): continue
        d20=U[20][i]-U[20][i-1]
        if d20<=0: continue
        d5=U[5][i]-U[5][i-1]
        if d5<=0 or d5>0.6*FCLK: continue      # 只取流内点 (间隔 < 0.6 s)
        d65=U[65][i]-U[65][i-1]; d64=U[64][i]-U[64][i-1]; d63=U[63][i]-U[63][i-1]
        d66=None
        if U[66][i] is not None and U[66][i-1] is not None:
            d66=U[66][i]-U[66][i-1]
        rows.append((d65/d20, (d66/d20 if d66 is not None else None), d64/d20, d63/d20,
                     (d66/d65 if (d66 is not None and d65>0) else None)))
    n=len(rows)
    if n<20: print(path,'n=',n,'太少'); continue
    x=[r[0] for r in rows]; y=[r[2] for r in rows]; z=[r[3] for r in rows]
    print('%-14s n=%3d  corr(idle/frm, W64/frm)=%.4f  corr(idle/frm, W63/frm)=%.4f  mean idle/frm=%.3f mean W64/frm=%.3f mean W63/frm=%.4f' % (
        path.split('/')[-1], n, pear(x,y), pear(x,z), st.mean(x), st.mean(y), st.mean(z)))
    has66=[r for r in rows if r[1] is not None]
    if has66:
        a=[r[0] for r in has66]; b=[r[1] for r in has66]; c=[r[4] for r in has66]
        print('%-14s n=%3d  corr(idle/frm, W66/frm)=%.4f  mean W66/frm=%.3f  mean W66/W65=%.6f  min=%.6f med=%.6f max=%.6f' % (
            '', len(has66), pear(a,b), st.mean(b), st.mean(c), min(c), st.median(c), max(c)))
