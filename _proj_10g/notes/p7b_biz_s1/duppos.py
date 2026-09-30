import struct,sys,collections
sys.path.insert(0,'/tmp/p7b_biz')
from p7b_pcap_deep import iter_pcap, parse
flows={}
for ts,d in iter_pcap('/tmp/biz_tcp.pcap'):
    r=parse(d)
    if not r or r.get('proto')!=6: continue
    if r['src']!='192.168.100.2' or r['sport']!=8080: continue
    if r['plen']<=0: continue
    k=(r['src'],r['sport'],r['dst'],r['dport'])
    fl=flows.setdefault(k,{'seen':{}, 'ev':[], 'first':ts, 'base':None})
    if fl['base'] is None: fl['base']=r['seq']
    if r['seq'] in fl['seen']:
        fl['ev'].append((ts-fl['first'], r['seq']-fl['base'], r['plen']))
    else:
        fl['seen'][r['seq']]=(r['plen'],ts)
k=max(flows,key=lambda k:len(flows[k]['ev']))
fl=flows[k]
print("FLOW %s:%d->%s:%d dups=%d uniq=%d"%(k[0],k[1],k[2],k[3],len(fl['ev']),len(fl['seen'])))
ev=fl['ev']
print("dup stream offsets first 25:", [e[1] for e in ev[:25]])
print("dup stream offsets last 10:", [e[1] for e in ev[-10:]])
print("dup times rel (ms) first 15:", ["%.3f"%(e[0]*1e3) for e in ev[:15]])
print("dup times rel (ms) last 8:", ["%.3f"%(e[0]*1e3) for e in ev[-8:]])
print("uniq payload bytes=%d  (1MB=1048576)"%sum(v[0] for v in fl['seen'].values()))
maxoff=max(fl['seen'].keys())-fl['base']
b=collections.Counter(min(9,(e[1]*10)//max(1,maxoff)) for e in ev)
print("dup count per decile of stream offset:", dict(sorted(b.items())))
