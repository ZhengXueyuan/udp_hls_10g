#!/bin/bash
# d2_t1.sh -- 单帧对照: ping(已知好) / 8081(待查) / 8080(已知好); 三口径同时取数
cd /home/a/xdma_test || exit 9
snap(){ bash /tmp/d2snap.sh | tr '\n' ' '; echo; }
sW(){ bash /tmp/d2snap.sh "$@" | tail -n +2 | tr '\n' ' '; echo; }
txp(){ ethtool -S enp1s0f1np1 | awk '/port_tx_packets/{print $2}'; }
txb(){ ethtool -S enp1s0f1np1 | awk '/port_tx_bytes/{print $2}'; }
txu(){ ethtool -S enp1s0f1np1 | awk '/port_tx_unicast/{print $2}'; }
echo "=== A 基线 ==="; snap
tcpdump -i enp1s0f1np1 -w /tmp/d2_t1.pcap -U -q >/dev/null 2>&1 &
TP=$!; sleep 2
echo "TX_a pkt=$(txp) bytes=$(txb) uni=$(txu)"
ping -c 3 -W 1 -n 192.168.100.2 >/tmp/d2_ping.txt 2>&1; echo "ping_rc=$?"; tail -2 /tmp/d2_ping.txt|head -1
sleep 1; echo "TX_b pkt=$(txp) bytes=$(txb) uni=$(txu)  (ping x3 后)"
echo "=== B 板侧 (ping 后) ==="; snap
python3 - <<'PY'
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 8081))
s.sendto(b'A'*49,  ("192.168.100.2", 8081)); time.sleep(0.3)
s.sendto(b'B'*100, ("192.168.100.2", 8081)); time.sleep(0.3)
print("sent: 49B(dport8081) + 100B(dport8081)")
PY
sleep 1; echo "TX_c pkt=$(txp) bytes=$(txb) uni=$(txu)  (2x 8081 后)"
echo "=== C 板侧 (8081 x2 后) ==="; snap
python3 -c "import socket,time;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('0.0.0.0',8080));s.settimeout(2);s.sendto(b'C'*49,('192.168.100.2',8080));print('reply=',s.recvfrom(2048)[0][:20])" 2>&1 | tail -2
sleep 1; echo "TX_d pkt=$(txp) bytes=$(txb) uni=$(txu)  (8080 后)"
echo "=== D 板侧 (8080 后) ==="; snap
kill $TP 2>/dev/null; sleep 1
echo "=== tcpdump 帧表 ==="; tcpdump -r /tmp/d2_t1.pcap -nn -q -e 2>/dev/null | sed 's/\(length [0-9]*\).*/\1/'
