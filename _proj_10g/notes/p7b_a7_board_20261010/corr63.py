import re, sys, json, statistics as st
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
for path in sys.argv[1:]:
    snaps=parse(path)
    U={w:uw(snaps,w) for w in (5,20,63,64,65,43)}
    rows=[]
    for i in range(1,len(snaps)):
        if None in (U[65][i],U[65][i-1],U[64][i],U[64][i-1],U[20][i],U[20][i-1]): continue
        d20=U[20][i]-U[20][i-1]
        if d20<=0: continue
        d5=U[5][i]-U[5][i-1]
        if d5<=0 or d5>0.6*FCLK: continue      # 只取流内点 (间隔 < 0.6 s)
        rows.append(((U[65][i]-U[65][i-1])/d20, (U[64][i]-U[64][i-1])/d20, (U[63][i]-U[63][i-1])/d20))
    if len(rows)<20: print(path,'n=',len(rows),'太少'); continue
    x=[r[0] for r in rows]; y=[r[1] for r in rows]; z=[r[2] for r in rows]
    def pear(a,b):
        ma,mb=st.mean(a),st.mean(b)
        num=sum((p-ma)*(q-mb) for p,q in zip(a,b))
        den=(sum((p-ma)**2 for p in a)*sum((q-mb)**2 for q in b))**0.5
        return num/den if den else float('nan')
    print('%-10s n=%3d  corr(idle/frm, W64/frm)=%.4f  corr(idle/frm, W63/frm)=%.4f  mean idle/frm=%.3f mean W64/frm=%.3f mean W63/frm=%.4f' % (
        path.split('/')[-1], len(rows), pear(x,y), pear(x,z), st.mean(x), st.mean(y), st.mean(z)))
