#!/bin/bash
# d2_t2.sh -- 对端 TX 通路诊断: 内核计数 / sfc 硬件计数 / qdisc / ARP 状态 / 抓包自证
N=enp1s0f1np1
k(){ cat /sys/class/net/$N/statistics/$1; }
h(){ ethtool -S $N | awk -v k="$1" '$1==k":"{print $2}'; }
echo "--- 内核计数 (tx/rx) ---"
echo "tx_packets=$(k tx_packets) tx_bytes=$(k tx_bytes) rx_packets=$(k rx_packets) rx_bytes=$(k rx_bytes) tx_dropped=$(k tx_dropped) tx_errors=$(k tx_errors)"
echo "--- sfc 硬件计数 ---"
for c in port_tx_packets port_tx_bytes port_tx_unicast port_tx_broadcast port_tx_errors port_rx_good port_rx_bytes; do echo "$c=$(h $c)"; done
echo "--- MTU / qdisc ---"
ip -br link show $N; tc -s qdisc show dev $N | head -8
echo "--- ARP 邻居 ---"; ip neigh show 192.168.100.2; ip neigh show dev $N | head -5
echo "--- 发 2 个 ping ---"
ping -c 2 -W 1 -n 192.168.100.2 2>&1 | tail -4
echo "--- ping 后 ---"
echo "k_tx_packets=$(k tx_packets) fw_tx_packets=$(h port_tx_packets) fw_tx_bytes=$(h port_tx_bytes)"
ip neigh show 192.168.100.2
echo "--- tcpdump 前台抓 6 帧自证 (同时发 3 个 ping) ---"
( sleep 1; ping -c 3 -W 1 -n 192.168.100.2 >/dev/null 2>&1 ) &
tcpdump -i $N -nn -q -e -c 6 2>&1 | head -12
