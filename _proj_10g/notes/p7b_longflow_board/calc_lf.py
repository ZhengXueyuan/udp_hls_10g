import re,sys
p=sys.argv[1]
txt=open(p,encoding='utf-8',errors='replace').read()
snaps={}; cur=None
for line in txt.splitlines():
    m=re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)',line)
    if m: cur=(m.group(1),int(m.group(2))); snaps[cur]={}
    m=re.match(r'^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)',line)
    if m and cur: snaps[cur][int(m.group(1))]=int(m.group(3),16)
order=[k for k in snaps if re.match(r'^\S+_s\d+$',k[0])]
order.sort(key=lambda k:int(k[0].split('_s')[1]))
print("points:",[(t,gen) for t,gen in order])
def pair(a,b):
    A=snaps[a]; B=snaps[b]
    d={w:(B.get(w,0)-A.get(w,0))%2**32 for w in (5,43,51,20,15,52,14,55,57)}
    dt=d[5]/156.25e6
    print(f"{a[0]+'->'+b[0]:18s} dW5={d[5]:12d} dt={dt*1e3:9.3f}ms dW51={d[51]:12d} rate={d[51]*8/dt/1e9:8.4f}Gbps dW43={d[43]:12d} dW43/dW5={d[43]/d[5]:9.5f} dW20={d[20]:9d} P={d[43]/d[20] if d[20] else 0:10.5f} dW15={d[15]:12d} dW55={d[55]:4d} dW52={d[52]:8d}")
    return d
for i in range(len(order)-1): pair(order[i],order[i+1])
print("--- longest inner span ---"); pair(order[0],order[-1])
pre=[k for k in snaps if k[0].endswith('_pre')][0]; post=[k for k in snaps if k[0].endswith('_post')][0]
print("--- bounding pre->post ---"); pair(pre,post)
for tag in sorted({k[0] for k in snaps}):
    for (t,gen),dd in snaps.items():
        if t==tag:
            print(f"{t:10s} gen={gen:3d} "+" ".join(f"W{k}={dd[k]:#010x}" for k in (5,14,15,20,43,51,52,55,57,58,61,62) if k in dd))
