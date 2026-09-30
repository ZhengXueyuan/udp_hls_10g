#!/bin/bash
# d2_t3.sh -- 真正的教学帧判别: 路由自证 + 前/后快照 + 8080 对照
N=enp1s0f1np1
cd /home/a/xdma_test || exit 9
ip addr add 192.168.100.100/32 dev $N 2>/dev/null
ip route add 192.168.100.2/32 dev $N src 192.168.100.100 2>/dev/null
echo "route: $(ip route get 192.168.100.2 | head -1)"
echo "=== BEFORE ==="; bash /tmp/d2snap.sh 0 2 6 7 8 9 10 11 20 30 31
echo "=== teach 1x100B -> 8081 (p6e_udp_pattern) ==="
./p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081 --teach-n 1 2>&1 | grep -aE "teach|汇总|收 |Mbps|FAIL|PASS|gap|bad" | head -8
echo "=== AFTER teach ==="; bash /tmp/d2snap.sh 0 2 6 7 8 9 10 11 20 30 31
echo "route2: $(ip route get 192.168.100.2 | head -1)"
echo "=== 8080 对照 ==="
python3 -c "import socket,time;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('0.0.0.0',8080));s.settimeout(2);s.sendto(b'D'*49,('192.168.100.2',8080));print('reply=',s.recvfrom(2048)[0][:16])" 2>&1|tail -1
echo "=== AFTER 8080 ==="; bash /tmp/d2snap.sh 0 2 6 7 8 9 10 11 20
