import re, glob, os
M32=2**32
KEYS=[0,22,3,4,19,21,32,33,34,35,38,46,47,48,56,59,60]
NAMES={0:'rx_frames',22:'pass_TCP',3:'crc_err',4:'rx_drop',19:'srx_drop',21:'tx_abort',32:'drop_partial',33:'orphan_bytes',34:'drop_full',35:'fifo_ovf',38:'rxcdc_ovf',46:'cls_ovf',47:'cls_route_ovf',48:'cls_stall_in',56:'udp_tx_ovf',59:'stx_fifo_ovf',60:'srx_fifo_ovf'}
for path in sorted(glob.glob('run_*.txt')):
    tag=os.path.basename(path)[4:-4]
    txt=open(path,encoding='utf-8',errors='replace').read()
    occ={}
    for m in re.finditer(r'^W(\d+)\s+0x[0-9A-F]+\s+(\S+)\s+0x([0-9a-fA-F]+)\s*$', txt, re.M):
        occ.setdefault(int(m.group(1)),[]).append(int(m.group(3),16))
    # pre = 第1次出现 (full), post = 第4次出现 (full, 若有)
    out=[]
    for k in KEYS:
        v=occ.get(k,[])
        if len(v)>=4:
            d=(v[3]-v[0])%M32
            if d: out.append('%s=+%d'%(NAMES[k],d))
    print('%-14s drop_nonzero: %s'%(tag, ', '.join(out) if out else 'NONE (全 0)'))
