import sys, struct
path=sys.argv[1]
f=open(path,'rb'); gh=f.read(24); magic=struct.unpack('<I',gh[:4])[0]
endian='<' if magic in (0xa1b2c3d4,0xa1b23c4d) else '>'; nano=magic==0xa1b23c4d
board_b=bytes([192,168,100,2]); peer_b=bytes([192,168,100,100])
t0=None; max_sent=None; credits=[]
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
    if s==peer_b and d==board_b and dp==8080:
        pay=struct.unpack('>H',pkt[16:18])[0]-ihl-20
        if pay>0:
            seq=struct.unpack('>I',pkt[14+ihl+4:14+ihl+8])[0]
            e=(seq+pay)&0xFFFFFFFF
            if max_sent is None or ((e-max_sent)&0xFFFFFFFF) < 2**31: max_sent=e
    elif s==board_b and d==peer_b and sp==8080:
        ack=struct.unpack('>I',pkt[14+ihl+8:14+ihl+12])[0]
        win=struct.unpack('>H',pkt[14+ihl+14:14+ihl+16])[0]
        if max_sent is not None:
            c=(ack+win-max_sent)&0xFFFFFFFF
            if c < 2**31: credits.append(c)
f.close()
n=len(credits)
def pct(v,p):
    s=sorted(v); return s[min(len(s)-1,int(len(s)*p/100.0))]
import collections
c=collections.Counter(credits)
print("CREDIT_samples=%d  (unit: bytes of unused send window at each ACK arrival)"%n)
print("CREDIT_top:", c.most_common(6))
print("CREDIT_p1=%d p10=%d p50=%d p90=%d max=%d"%(pct(credits,1),pct(credits,10),pct(credits,50),pct(credits,90),max(credits)))
z=sum(1 for x in credits if x<1500); zz=sum(1 for x in credits if x==0)
print("CREDIT_lt_one_seg_frac=%.4f  eq0_frac=%.4f"%(z/n, zz/n))
