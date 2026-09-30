#!/bin/bash
# d2_t4.sh -- 20 连发 + 长度扫描 (每次发送前自证路由活)
N=enp1s0f1np1
cd /home/a/xdma_test || exit 9
rt(){ ip addr add 192.168.100.100/32 dev $N 2>/dev/null; ip route add 192.168.100.2/32 dev $N src 192.168.100.100 2>/dev/null; ip route get 192.168.100.2 | head -1; }
r(){ bash /tmp/d2snap.sh 0 2 6 10 8 20 31 | tail -n +2; }
rt
echo "=== BEFORE ==="; r
echo "=== A: 20 连发 (teach-n 20, len 100) ==="
./p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081 --teach-n 20 2>&1 | grep -aE "teach|汇总|Mbps|FAIL|个包" | head -5
echo "=== A AFTER ==="; r
for L in 99 98 97 96 95 94 93 92; do
  rt >/dev/null
  ./p6e_udp_pattern --secs 1 --board 192.168.100.2 --port 8081 --teach-n 1 --teach-len $L >/tmp/d2_l.txt 2>&1
  echo "len=$L rc=$? | $(grep -aE '收 ' /tmp/d2_l.txt | head -1 | tr -s ' ') | $(r | tr '\n' ' ')"
done
echo "route_end: $(ip route get 192.168.100.2 | head -1)"
