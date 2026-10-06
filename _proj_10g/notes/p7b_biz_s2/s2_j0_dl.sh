#!/bin/bash
# s2_j0_dl.sh -- P7B-BIZ Stage 2: J0 (UDP 下行几何) 板级窗口测量
#   板子此刻已在持续 floods 下行 (813 kfps) ⇒ 本脚本只做"取窗 + 抓包 + NIC 计数"
#   输出: 两次 snap (含 W8/W9/W20/W43/W56) + 一个 300 帧 pcap + NIC 前后计数
set -u
cd /tmp/p7b_biz || exit 9
S=/tmp/p7b_biz/p7b_snap.sh
KW="0 1 3 5 8 9 20 24 43 56 3 4 21 32 33 34 35 46 47 48 49"

echo "### NIC_PRE $(date +%s.%N)"
ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_good_bytes|port_rx_packets|port_rx_bad|rx_eth_crc_err|port_rx_nodesc_drops|port_tx_packets|port_tx_bytes):'

echo "### SNAP_A $(date +%s.%N)"
bash "$S" snap S2_J0_A $KW

echo "### TCPDUMP $(date +%s.%N)"
rm -f /tmp/s2_dl.pcap
timeout 30 tcpdump -i enp1s0f1np1 -s 0 -c 300 -w /tmp/s2_dl.pcap > /tmp/s2_dl_tcpdump.log 2>&1
echo "TCPDUMP_RC=$? $(date +%s.%N)"
cat /tmp/s2_dl_tcpdump.log | tail -3

echo "### SLEEP $(date +%s.%N)"
sleep 2.2

echo "### SNAP_B $(date +%s.%N)"
bash "$S" snap S2_J0_B $KW

echo "### NIC_POST $(date +%s.%N)"
ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_good_bytes|port_rx_packets|port_rx_bad|rx_eth_crc_err|port_rx_nodesc_drops|port_tx_packets|port_tx_bytes):'
echo "S2_J0_DONE $(date +%s.%N)"
