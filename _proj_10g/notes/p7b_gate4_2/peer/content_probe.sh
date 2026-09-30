#!/bin/bash
# content_probe.sh — F3 独立逐字节判据 (偏移 0 锚定)
#   前提: 刚重烧位流 ⇒ app 图案发生器复位到流偏移 0, peer 表空 ⇒ 板子不发。
#   顺序: **先武装 tcpdump(全载荷) → 再教学一帧** ⇒ 抓到的第 1 帧就是板子发的第 1 帧 (偏移 0)。
#   判据(本地 Python 复算, 不用被验工具/板子自报): 每帧载荷 == xorshift64 流上 1472 的整数倍偏移;
#   相邻帧偏移严格递增且差为 1472 的整数倍。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
nic(){ ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(good|bad|packets|bytes|1024_to_15xx)|rx_eth_crc_err):' | tr -d ' ' | tr ':' ' ' | tr '\n' ' '; echo; }
# ⚠️ /32 路由会被 NetworkManager 静默冲掉 (本工程实测多次) ⇒ **每次发送前现取现补**
echo "ROUTE_BEFORE $(ip route get 192.168.100.2 2>&1 | head -1)"
ip addr add 192.168.100.100/32 dev enp1s0f1np1 2>/dev/null
ip route add 192.168.100.2/32 dev enp1s0f1np1 src 192.168.100.100 2>/dev/null
echo "ROUTE_AFTER $(ip route get 192.168.100.2 2>&1 | head -1)"
echo "NIC_PRE $(date +%s.%N)"; nic
nohup timeout 30 tcpdump -Z root -i enp1s0f1np1 -c 3000 -s 1600 -w /tmp/g4_content3.pcap 'udp and dst port 8081' >/tmp/tcp.err 2>&1 &
TPID=$!
sleep 2
echo "TCPDUMP_ARMED $(date +%s.%N) pid=$TPID"
cd /home/a/xdma_test && ./p6e_udp_pattern --secs 5 --teach-n 1 --teach-len 100 --board 192.168.100.2 --port 8081 2>&1 | tail -12
echo "TEACH_DONE $(date +%s.%N)"
wait $TPID
echo "--- tcpdump stderr ---"; tail -4 /tmp/tcp.err
echo "NIC_POST $(date +%s.%N)"; nic
ls -la /tmp/g4_content3.pcap
echo CONTENT_DONE
