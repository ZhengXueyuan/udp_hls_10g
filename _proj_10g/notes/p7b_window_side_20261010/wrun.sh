#!/bin/bash
# wrun.sh -- P7b 窗口侧判别轮 (2026-10-10): 长流下行一跑, **只动对端 --rcvbuf** (位流不动)
#   用法(TAG 指向 rcvbuf 档): TAG=WS_B8M_r1 RCVBUF=8388608 bash wrun.sh
#   env: TAG RCVBUF [SECS=150] [MAXBYTES=30000000000] [DUMP=0] [SNAPGAP=0.1] [MAXSNAP=2000]
#   与 run_arm.sh (构建 E 轮) 的差别:
#     ① ARM 参数换成 RCVBUF 档 (位流恒 = 构建 E, BID 0x00000019)
#     ② 跑后取回 /tmp/ss_${TAG}.log (lf_dl.sh 自带的 ss 采样器全量日志 = 窗口见证)
#     ③ DUMP=1 时另起 wdump.sh 抓流中 ACK 的窗口字段 (pcap, IO_AFFECTING, 单跑登记)
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_window_side_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

TAG=${TAG:?usage: TAG=WS_x_r1 RCVBUF=65536 bash wrun.sh}; RCVBUF=${RCVBUF:?need RCVBUF}
SECS=${SECS:-150}; MAXBYTES=${MAXBYTES:-30000000000}; DUMP=${DUMP:-0}
SNAPGAP=${SNAPGAP:-0.1}; MAXSNAP=${MAXSNAP:-2000}
BIE=0x00000019; NW=67
KW='5 20 43 51 15 63 64 65 66'
mkdir -p "$OUT/runs"
RAW=$OUT/runs/${TAG}.txt

echo "### RUN_BEGIN tag=$TAG rcvbuf=$RCVBUF secs=$SECS maxbytes=$MAXBYTES dump=$DUMP $(date +%s.%N)"

# --- COALESCE 见证 (每次报速率必带) ---
PEER_PW=111111 $SSH "ethtool -c enp1s0f1np1 | grep -E 'Adaptive|rx-usecs:'" 2>&1 | tee "$OUT/runs/${TAG}_coalesce.txt"

# --- 板侧身份闸 (NW=67 / BID 0x19; 与 lf_dl.sh 内的闸独立) ---
PEER_PW=111111 $SSH --sudo "EXPECT_BID=$BIE NW=$NW bash /tmp/p7b_biz/p7b_snap.sh id | grep -E 'ID_MAGIC|ID_BID|ID_UNIMPL|ID_OK|ID_FAIL'" 2>&1 | tee "$OUT/runs/${TAG}_id.txt"

# --- 可选的流中 ACK 抓包 (后台, 等 ESTAB 后 3 s 起抓) ---
if [ "$DUMP" = "1" ]; then
  PEER_PW=111111 $SSH --sudo "setsid nohup bash /tmp/p7b_biz/wdump.sh $TAG 600 4 >/dev/null 2>&1 < /dev/null & echo WD_PID=\$!"
fi

# --- 主跑 ---
PEER_PW=111111 $SSH --sudo --timeout 400 "cd /tmp/p7b_biz && TAG=$TAG SECS=$SECS NW=$NW BID_EXPECT=$BIE KW='$KW' SINK_EXTRA='--check lane8 --maxbytes $MAXBYTES' MAXSNAP=$MAXSNAP SNAPGAP=$SNAPGAP RCVBUF=$RCVBUF bash /tmp/p7b_biz/lf_dl.sh" > "$RAW" 2>&1
RC=$?
echo "### RUN_END tag=$TAG rc=$RC bytes=$(stat -c %s "$RAW" 2>/dev/null) $(date +%s.%N)"

# --- 取回 ss 见证全量日志 (⚠️ --get 的本地路径必须 Windows 形式: /d/... 会被 paramiko 拒) ---
WOUT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_window_side_20261010'
PEER_PW=111111 $SSH --get /tmp/ss_${TAG}.log "$WOUT\\runs\\${TAG}_ss.log" 2>&1

# --- 可选抓包读数 ---
if [ "$DUMP" = "1" ]; then
  PEER_PW=111111 $SSH "echo '=== HANDSHAKE (SYN/SYN-ACK, wscale 见证) ==='; tcpdump -r /tmp/dump_${TAG}_hs.pcap -nvv 2>&1 | head -40; echo '=== MID-FLOW window-field (每点 80 包, win 字段) ==='; for p in 0 1 2 3 4 5; do echo \"-- point \$p:\"; tcpdump -r /tmp/dump_${TAG}_p\${p}.pcap -n 2>/dev/null | grep -oE 'win [0-9]+' | awk '{print \$2}' | sort -n | awk 'NR==1{mn=\$1} {a[NR]=\$1} END{if(NR>0) printf \"n=%d min=%d med=%d max=%d\\n\", NR, mn, a[int((NR+1)/2)], a[NR]; else print \"(空)\"}'; done; echo '=== stderr ==='; tail -10 /tmp/dump_${TAG}.err" 2>&1 | tee "$OUT/runs/${TAG}_dump.txt"
fi

# --- 紧凑摘要 ---
echo "--- META ---";        grep -E '^LF_META_|^SINK_LIMITS|^CARRIER=|^LF_GEOM_OK|^LF_GEOM_FAIL|^PCAP_ACTIVE' "$RAW" | head -20
echo "--- SINK ---";        grep -E '^SINK_SUM|^SINK_CONN' "$RAW" | head -6
echo "--- PIN ---";         grep -E '^PIN_CPU=|^PIN_THREAD|^UNPINNED=' "$RAW" | head -8
echo "--- GUARDS ---";      grep -E '^LF_SNAP_MAXREACHED|^SNAP_FAIL|^GEN_FAIL' "$RAW" | head -5
echo "--- GEOM_NOPCAP ---"; grep -E '^GEOM_NOPCAP' "$RAW" | head -3
echo "### WRUN_DONE $(date +%s.%N)"
