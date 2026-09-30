#!/bin/bash
# rate_probe.sh — 三个独立口径的**同窗**帧率比较:
#   ① 网卡硬件计数 (ethtool -S port_rx_good/bytes, 抓包前后各一次)
#   ② pcap 时间戳 (tcpdump 抓 N 帧, 首末时间戳 ⇒ 平均帧间隔) —— 抓包点=驱动队列, 但时间戳=内核收包时刻
#   ③ 板侧自报 (W20/W8) —— 由 xchk_probe.sh 另测
# 只读, 不改配置。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
nic(){ ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(good|bad|packets|bytes|1024_to_15xx)|rx_eth_crc_err):' | tr -d ' ' | tr ':' ' '; }
echo "NIC_BEFORE $(date +%s.%N)"
nic
echo "PCAP_START $(date +%s.%N)"
timeout 20 tcpdump -i enp1s0f1np1 -c 3000 -s 96 -w /tmp/g4_rate.pcap 'udp and dst port 8081' 2>/tmp/g4_tcpdump.err
echo "PCAP_RC=$? $(date +%s.%N)"
cat /tmp/g4_tcpdump.err | tail -3
echo "NIC_AFTER $(date +%s.%N)"
nic
ls -la /tmp/g4_rate.pcap
