#!/bin/bash
# wdump_probe.sh -- 抓包探针: 一条**短**下行流 (TAG/RCVBUF 指定) + 前台抓包 (握手 + 6 点流中窗)
#   ⚠️ 本探针的**目的只有窗字段见证**, 不是速率判据跑 (读数仍会落盘, 但登记为附带)
#   用法: TAG=DP_B8M RCVBUF=8388608 bash wdump_probe.sh
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_window_side_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"
TAG=${TAG:?usage: TAG=DP_x RCVBUF=65536 bash wdump_probe.sh}; RCVBUF=${RCVBUF:?need RCVBUF}
SECS=${SECS:-40}; MAXBYTES=${MAXBYTES:-12000000000}
mkdir -p "$OUT/runs"

# 1) 抓包 (本地 ssh 会话保持存活期间远程前台跑 wdump.sh)
PEER_PW=111111 $SSH --sudo --timeout 200 "bash /tmp/p7b_biz/wdump.sh $TAG 80 6" > "$OUT/runs/${TAG}_wdump_stdout.txt" 2>&1 &
WPID=$!
sleep 2

# 2) 短跑 (sink; 与抓包并行)
PEER_PW=111111 $SSH --sudo --timeout 200 "cd /tmp/p7b_biz && TAG=$TAG SECS=$SECS NW=67 BID_EXPECT=0x00000019 KW='5 20 43 51 15 63 64 65 66' SINK_EXTRA='--check lane8 --maxbytes $MAXBYTES' MAXSNAP=8 SNAPGAP=0.05 RCVBUF=$RCVBUF bash /tmp/p7b_biz/lf_dl.sh" > "$OUT/runs/${TAG}.txt" 2>&1
echo "SINK_RC=$?"
wait $WPID

# 3) 读数
PEER_PW=111111 $SSH "echo '=== HANDSHAKE (SYN/SYN-ACK) ==='; tcpdump -r /tmp/dump_${TAG}_hs.pcap -nvv 2>&1 | head -30; echo '=== MID-FLOW win 字段 (每点 80 包) ==='; for p in 0 1 2 3 4 5; do printf -- '-- point %s: ' \$p; tcpdump -r /tmp/dump_${TAG}_p\${p}.pcap -n 2>/dev/null | grep -oE 'win [0-9]+' | awk '{print \$2}' | sort -n | awk '{a[NR]=\$1} END{if(NR>0) printf \"n=%d min=%d med=%d max=%d\n\", NR, a[1], a[int((NR+1)/2)], a[NR]; else print \"(空)\"}'; done; echo '=== 样本行 (point0 前 3 行) ==='; tcpdump -r /tmp/dump_${TAG}_p0.pcap -n 2>/dev/null | head -3; echo '=== stderr ==='; cat /tmp/dump_${TAG}.err" 2>&1 | tee "$OUT/runs/${TAG}_dump.txt"
