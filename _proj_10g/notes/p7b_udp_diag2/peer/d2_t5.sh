#!/bin/bash
# d2_t5.sh -- 逐帧依赖判别: 占住 8081 (抑制 ICMP) + 变 N / 变长度, 量 app 认领帧数
N=enp1s0f1np1
cd /home/a/xdma_test || exit 9
python3 -c "
import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4<<20)
s.bind(('0.0.0.0',8081)); time.sleep(900)
" >/dev/null 2>&1 &
ip addr add 192.168.100.100/32 dev $N 2>/dev/null
ip route add 192.168.100.2/32 dev $N src 192.168.100.100 2>/dev/null
echo "route: $(ip route get 192.168.100.2|head -1)"
w(){ bash /tmp/d2snap.sh "$@" | tail -n +2 | awk -F= '{printf "%s=%s ", $1, $2}'; echo; }
send(){ python3 -c "
import socket,sys,time
M=(1<<64)-1
def xs(s):
    s^=(s<<13)&M; s^=s>>7; s^=(s<<17)&M; return s&M
def pref(n,seed=0x9E3779B97F4A7C15):
    s=seed; o=bytearray()
    for _ in range(n):
        o.append((s>>24)&0xFF); s=xs(s)
    return bytes(o)
n=int(sys.argv[1]); L=int(sys.argv[2]); g=float(sys.argv[3])
t=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); p=pref(L)
for i in range(n):
    t.sendto(p,('192.168.100.2',8081)); time.sleep(g)
" $1 $2 $3; }
echo "--- 背景速率 (无激励) ---"; w 0 10 31; sleep 3; w 0 10 31
for L in 100 96 104; do
 for n in 1 2 4 8 20; do
  a=$(w 0 10 31 | tr -d '\n')
  send $n $L 0.05
  sleep 0.6
  b=$(w 0 10 31 38 26 34 32 | tr -d '\n')
  echo "L=$L N=$n : 前[$a] 后[$b]"
 done
done
echo "--- 收尾背景 ---"; w 0 10 31
