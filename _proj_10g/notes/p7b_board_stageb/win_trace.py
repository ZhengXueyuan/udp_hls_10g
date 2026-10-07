import sys, struct
path=sys.argv[1]
f=open(path,'rb'); gh=f.read(24); magic=struct.unpack('<I',gh[:4])[0]
endian='<' if magic in (0xa1b2c3d4,0xa1b23c4d) else '>'
nano = magic==0xa1b23c4d
board_b=bytes([192,168,100,2]); peer_b=bytes([192,168,100,100])
t0=None; recs=[]; wins=[]
while True:
    rh=f.read(16)
    if len(rh)<16: break
    ts_s,ts_us,incl,orig=struct.unpack(endian+'IIII',rh)
    t=ts_s+ts_us*(1e-9 if nano else 1e-6)
    pkt=f.read(incl)
    if len(pkt)<54 or pkt[12:14]!=b'\x08\x00': continue
    ihl=(pkt[14]&0x0f)*4
    if pkt[14+9]!=6: continue
    if pkt[26:30]==board_b and pkt[30:34]==peer_b and struct.unpack('>H',pkt[14+ihl:14+ihl+2])[0]==8080:
        ack=struct.unpack('>I',pkt[14+ihl+8:14+ihl+12])[0]
        win=struct.unpack('>H',pkt[14+ihl+14:14+ihl+16])[0]
        if t0 is None: t0=t
        recs.append((t-t0,ack,win)); wins.append(win)
    f.close if False else None
f.close()
n=len(recs)
print("ACKS=%d"%n)
import collections
c=collections.Counter(wins)
print("WIN_TOP:", c.most_common(8))
print("WIN_min=%d p1=%d p50=%d p90=%d max=%d"%(min(wins),sorted(wins)[n//100],sorted(wins)[n//2],sorted(wins)[n*9//10],max(wins)))
print("WIN_zero_frac=%.5f WIN_lt1460_frac=%.5f"%(sum(1 for w in wins if w==0)/n, sum(1 for w in wins if w<1460)/n))
# 低窗 -> 恢复 的间隔 (口径: win<1460 -> 首个 win>=1460)
rec=None; recs2=[]
for (t,a,w) in recs:
    if w<1460:
        if rec is None: rec=t
    else:
        if rec is not None: recs2.append(t-rec); rec=None
recs2.sort()
print("LOWWIN_REC_n=%d med=%.6fs p90=%.6fs max=%.6fs"%(len(recs2), recs2[len(recs2)//2] if recs2 else -1, recs2[int(len(recs2)*0.9)] if recs2 else -1, recs2[-1] if recs2 else -1))
# 静默段 (>100ms 无 ACK)
gaps=[recs[i+1][0]-recs[i][0] for i in range(n-1) if recs[i+1][0]-recs[i][0]>0.1]
print("SILENT_gt100ms_n=%d max_gap=%.6fs"%(len(gaps), max([recs[i+1][0]-recs[i][0] for i in range(n-1)]+[0])))
# 20ms 窗口的 (t, ack 前进, win) 轨迹 (前 40 条)
sel=[r for r in recs if 2.0 <= r[0] < 2.02][:40]
print("TRACE 2.00-2.02s (t, ack, win) [+dack]:")
prev=None
for (t,a,w) in sel:
    d=(a-prev)&0xFFFFFFFF if prev is not None else 0
    print("  %.6f %10d %6d d=%d"%(t,a,w,d)); prev=a
