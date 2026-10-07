import sys, struct
path=sys.argv[1]
f=open(path,'rb'); gh=f.read(24); magic=struct.unpack('<I',gh[:4])[0]
endian='<' if magic in (0xa1b2c3d4,0xa1b23c4d) else '>'; nano = magic==0xa1b23c4d
board_b=bytes([192,168,100,2]); peer_b=bytes([192,168,100,100])
t0=None; ev=[]   # (t, dir, flags, seq, ack, paylen, win)
while True:
    rh=f.read(16)
    if len(rh)<16: break
    ts_s,ts_us,incl,orig=struct.unpack(endian+'IIII',rh)
    t=ts_s+ts_us*(1e-9 if nano else 1e-6)
    pkt=f.read(incl)
    if len(pkt)<54 or pkt[12:14]!=b'\x08\x00': continue
    ihl=(pkt[14]&0x0f)*4
    if pkt[14+9]!=6: continue
    s=pkt[26:30]; d=pkt[30:34]
    sp=struct.unpack('>H',pkt[14+ihl:14+ihl+2])[0]; dp=struct.unpack('>H',pkt[14+ihl+2:14+ihl+4])[0]
    if not ((s==board_b and d==peer_b and sp==8080) or (s==peer_b and d==board_b and dp==8080)): continue
    fl=pkt[14+ihl+13]
    seq=struct.unpack('>I',pkt[14+ihl+4:14+ihl+8])[0]
    ack=struct.unpack('>I',pkt[14+ihl+8:14+ihl+12])[0]
    win=struct.unpack('>H',pkt[14+ihl+14:14+ihl+16])[0]
    ip_tot=struct.unpack('>H',pkt[16:18])[0]; pay=ip_tot-ihl-20
    if t0 is None: t0=t
    ev.append((t-t0, 'P->B' if s==peer_b else 'B->P', fl, seq, ack, pay, win))
f.close()
# 找第一个 SYN (P->B, fl&0x02)
i0=next(i for i,e in enumerate(ev) if e[1]=='P->B' and (e[2]&0x02))
print("first bytes:")
for e in ev[i0:i0+12]:
    print("  t=%.6f %s fl=0x%02x seq=%u ack=%u pay=%d win=%d"%e)
# 第一个数据段 (P->B, pay>0) 与其 ack
first_data=next((i,e) for i,e in enumerate(ev) if i>i0 and e[1]=='P->B' and e[5]>0)
ti, ed = first_data
print("FIRST_DATA t=%.6f pay=%d"%(ed[0], ed[5]))
print("后续 P->B 数据段 (前 40) 与 '首个覆盖它末尾的 B->P ACK' 的间隔:")
seg_end=(ed[3]+ed[5])&0xFFFFFFFF
k=0; j=ti+1; pending=[]
while j < len(ev) and k < 40:
    e=ev[j]
    if e[1]=='P->B' and e[5]>0:
        pending.append((e[0], (e[3]+e[5])&0xFFFFFFFF)); k+=1
    elif e[1]=='B->P' and len(pending):
        done=[p for p in pending if ((e[4]-p[1])&0xFFFFFFFF) < 100000]
        for p in done:
            print("  seg_end=%u  sent t=%.6f  ack t=%.6f  RTT=%.1f us"%(p[1],p[0],e[0],(e[0]-p[0])*1e6))
            pending.remove(p)
    j+=1
