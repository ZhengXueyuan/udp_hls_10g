#!/bin/bash
# d2_t6.sh -- 干净对账: N=20 逐帧认领 + W0/W6/W10/W31 四项闭账 + 后台 socket 兜住 ICMP
N=enp1s0f1np1
cd /home/a/xdma_test || exit 9
setsid nohup python3 -c "
import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4<<20)
s.bind(('0.0.0.0',8081)); time.sleep(7200)
" >/dev/null 2>&1 &
sleep 1
ip addr add 192.168.100.100/32 dev $N 2>/dev/null
ip route add 192.168.100.2/32 dev $N src 192.168.100.100 2>/dev/null
echo "route: $(ip route get 192.168.100.2|head -1)"
w(){ bash /tmp/d2snap.sh "$@" | tail -n +2 | awk -F= '{printf "%s=%s ", $1, $2}'; echo; }
for i in 1 2 3; do
  a=$(w 0 6 10 31)
  python3 -c "
import socket,sys,time
M=(1<<64)-1
def xs(s):
    s^=(s<<13)&M; s^=s>>7; s^=(s<<17)&M; return s&M
def pref(n,seed=0x9E3779B97F4A7C15):
    s=seed;o=bytearray()
    for _ in range(n):
        o.append((s>>24)&0xFF); s=xs(s)
    return bytes(o)
t=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); p=pref(100)
for i in range(20):
    t.sendto(p,('192.168.100.2',8081)); time.sleep(0.05)
"
  sleep 0.6
  echo "轮$i 前[$a]"
  echo "轮$i 后[$(w 0 6 10 31 8 20)]"
done
echo "--- 后台 8081 持有者 ---"; ss -lunp 2>/dev/null | grep 8081 | head -2
