#!/bin/bash
# s1_2_run.sh -- S1.2 单会话驱动: 前快照 -> tcpdump+sink -> 后快照  (全部在**同一个 sudo 会话**里)
#   ⚠️ 分两次 ssh 的话第一次会话一关, 后台 tcpdump 会被收掉 (方案 §4-S1.2 明令)
#   用法: bash s1_2_run.sh <conns> <seconds> <pcap> <tag>
set -u
CONNS=${1:-300}
SECS=${2:-45}
PCAP=${3:-/tmp/biz_tcp.pcap}
TAG=${4:-S1_2}
S=/tmp/p7b_biz/p7b_snap.sh
cd /tmp/p7b_biz || exit 9

echo "### PHASE pre_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_pre" || { echo "S1_2_ABORT pre snapshot"; exit 1; }

echo "### PHASE tcpdump_start $(date +%s.%N)"
rm -f "$PCAP"
( timeout $((SECS + 15)) tcpdump -i enp1s0f1np1 -s 0 -w "$PCAP" \
    "tcp and src 192.168.100.2 and src port 8080" >/tmp/tcpdump_${TAG}.log 2>&1 & )
sleep 1.5

echo "### PHASE ss_sampler_start $(date +%s.%N)"
( for i in $(seq 1 $((SECS + 4))); do
    echo "SS_T $(date +%s.%N) $(ss -tinm state established '( dport = :8080 or sport = :8080 )' 2>/dev/null | tr '\n' '|')"
    sleep 1
  done > /tmp/ss_${TAG}.log 2>&1 & )

echo "### PHASE sink_start $(date +%s.%N)"
./p7b_tcp_sink --host 192.168.100.2 --port 8080 --conns "$CONNS" --seconds "$SECS"
echo "SINK_RC=$?  $(date +%s.%N)"
echo "### PHASE sink_end $(date +%s.%N)"
sleep 2
echo "### PHASE post_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_post" || { echo "S1_2_ABORT post snapshot"; exit 1; }
echo "### PHASE done $(date +%s.%N)"
wc -c "$PCAP"
echo "S1_2_DONE"
