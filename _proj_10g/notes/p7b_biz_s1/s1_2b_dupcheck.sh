#!/bin/bash
# 单连接: NIC RX 计数 vs pcap 帧数 —— 判定"重传"是真上线还是抓包点幻影
set -u
cd /tmp/p7b_biz || exit 9
g(){ ethtool -S enp1s0f1np1 | grep -E "^ *($1):" | awk '{s+=$2} END{print s}'; }
NW='rx-0.rx_packets|port_rx_packets|port_rx_good'
echo "PRE  $(date +%s.%N)  $($NW)"
A0=$(ethtool -S enp1s0f1np1 | awk '/^ +rx-0\.rx_packets:/{s+=$2}END{print s}')
B0=$(ethtool -S enp1s0f1np1 | awk '/^ +port_rx_packets:/{s+=$2}END{print s}')
echo "PRE rx-0=$A0 port_rx=$B0"
rm -f /tmp/dup1.pcap
( timeout 20 tcpdump -i enp1s0f1np1 -s 0 -w /tmp/dup1.pcap "tcp and src 192.168.100.2 and src port 8080" >/dev/null 2>&1 & )
sleep 1.5
./p7b_tcp_sink --host 192.168.100.2 --port 8080 --conns 1 --seconds 20
sleep 2
A1=$(ethtool -S enp1s0f1np1 | awk '/^ +rx-0\.rx_packets:/{s+=$2}END{print s}')
B1=$(ethtool -S enp1s0f1np1 | awk '/^ +port_rx_packets:/{s+=$2}END{print s}')
echo "POST rx-0=$A1 port_rx=$B1"
echo "DELTA rx-0=$((A1-A0))  port_rx=$((B1-B0))"
echo "PCAP_FRAMES $(python3 -c "
import sys;sys.path.insert(0,'/tmp/p7b_biz')
from p7b_pcap_deep import iter_pcap,parse
n=0;data=0;dup=0;seen=set()
for ts,d in iter_pcap('/tmp/dup1.pcap'):
    r=parse(d)
    if not r or r.get('proto')!=6: continue
    if r['src']!='192.168.100.2' or r['sport']!=8080: continue
    n+=1
    if r['plen']>0:
        data+=1
        if r['seq'] in seen: dup+=1
        else: seen.add(r['seq'])
print('frames=%d data=%d dup=%d uniq=%d'%(n,data,dup,len(seen)))
")"
echo "S1_2B_DONE"
