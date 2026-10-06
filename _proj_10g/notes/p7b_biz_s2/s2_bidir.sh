#!/bin/bash
# s2_bidir.sh -- 双向抓包: 判 "对端到底有没有发过 dup-ACK" (P7B_BIZ_S2.md §4.3 的缺口)
#   用法: bash s2_bidir.sh <conns> <seconds>
set -u
CONNS=${1:-60}
SECS=${2:-15}
cd /tmp/p7b_biz || exit 9
S=/tmp/p7b_biz/p7b_snap.sh
echo "### PRE $(date +%s.%N)"
bash "$S" snap S2_BIDIR_PRE 0 1 3 4 14 15 20 22 23 24 51 52 55 56 57 58
rm -f /tmp/s2_bidir.pcap
( timeout $((SECS + 12)) tcpdump -i enp1s0f1np1 -s 0 -w /tmp/s2_bidir.pcap "tcp port 8080" > /tmp/s2_bidir.log 2>&1 & )
sleep 1.5
echo "### SINK_START $(date +%s.%N)"
./p7b_tcp_sink --host 192.168.100.2 --port 8080 --conns "$CONNS" --seconds "$SECS" | tail -2
echo "### SINK_END $(date +%s.%N)"
sleep 2
bash "$S" snap S2_BIDIR_POST 0 1 3 4 14 15 20 22 23 24 51 52 55 56 57 58
sleep 12
echo "### tcpdump log:"; tail -3 /tmp/s2_bidir.log
echo "S2_BIDIR_DONE $(date +%s.%N)"
