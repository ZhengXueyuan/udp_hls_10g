import re,glob,os
for f in sorted(glob.glob('runs/LF*.txt')):
    t=open(f,encoding='utf-8',errors='replace').read()
    got={}
    for tag in ('pre','pre2','post','post2'):
        m=re.search(rf'### PHASE nic_{tag}[^\n]*\n(.*?)(?=\n###)',t,re.S)
        if not m: continue
        v={}
        for k in ('port_rx_good_bytes','port_rx_packets','port_tx_bytes','port_tx_packets','port_rx_bad','rx_eth_crc_err','port_rx_nodesc_drops'):
            mm=re.search(rf'^\s*{k}:\s*(\d+)',m.group(1),re.M)
            if mm: v[k]=int(mm.group(1))
        got[tag]=v
    A=got.get('pre2') or got.get('pre'); B=got.get('post2') or got.get('post')
    tag = os.path.basename(f).replace('.txt','')
    if A and B and A.get('port_rx_good_bytes') is not None and B.get('port_rx_good_bytes') is not None:
        drb=B['port_rx_good_bytes']-A['port_rx_good_bytes']; drp=B['port_rx_packets']-A['port_rx_packets']
        dtp=B['port_tx_packets']-A['port_tx_packets']; dtb=B['port_tx_bytes']-A['port_tx_bytes']
        zero = " ⚠️同一对读数(未刷新)" if (drb==0 and drp==0) else ""
        print(f"{tag:42s} NIC rx {drb:>10d} B / {drp:>7d} pkt ({drb/drp if drp else 0:9.4f} B/pkt) | peer TX {dtp:>7d} pkts {dtb:>10d} B{zero}")
    else:
        print(f"{tag:42s} NIC: 缺读数")
