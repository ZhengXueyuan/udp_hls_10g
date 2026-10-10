#!/bin/bash
# run_arm.sh -- P7B 构建 F 板级轮 (2026-10-10): 长流下行 (板 -> 对端 :8080) 一跑
#   与构建 E 轮 run_arm.sh 同构型 (同 SECS/--maxbytes/台架脚本/rcvbuf/sink 二进制),
#   唯一差异 = 位流 (F 70 字含 W67/W68/W69) 与 KW 字表 (多 3 个新仪器)。
#   用法: bash run_arm.sh <RUNID> [rcvbuf] [dump]
#   env: MAXBYTES SECS SNAPGAP MAXSNAP RCVBUF
set -u
RUNID=${1:?usage: run_arm.sh RUNID [rcvbuf] [dump]}
RCVBUF=${2:-${RCVBUF:-8388608}}
DUMP=${3:-${DUMP:-0}}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildF_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

MAXBYTES=${MAXBYTES:-75000000000}     # 75 GB: 9.15 Gbps 下 ≈ 65.6 s (>= 派单的 60 s)
SECS=${SECS:-180}                     # sink 墙钟上限 (只挡新连接, 不终止在跑的连接)
SNAPGAP=${SNAPGAP:-0.05}
MAXSNAP=${MAXSNAP:-900}
KW=${KW:-'5 20 43 51 63 64 65 66 67 68 69'}   # 11 字 (派单 §① 的字表)
BIE=0x0000001A; NW=70
TAG="BF${RUNID}"
mkdir -p "$OUT/runs"
RAW=$OUT/runs/${TAG}.txt
COALF=$OUT/runs/${TAG}_coalesce.txt

echo "### KW_USED tag=$TAG KW='$KW' rcvbuf=$RCVBUF dump=$DUMP maxbytes=$MAXBYTES secs=$SECS snapgap=$SNAPGAP maxsnap=$MAXSNAP"
echo "### RUN_BEGIN tag=$TAG $(date +%s.%N)"
# --- COALESCE 见证 (每次报速率必带; 测前/测后各一次) ---
PEER_PW=111111 $SSH "ethtool -c enp1s0f1np1 | grep -E 'Coalesce|Adaptive|rx-usecs'|head -3; echo ---; nproc" 2>&1 | tee "$COALF"

# --- 板侧身份闸 (跑前, 独立于 lf_dl.sh 内的闸) ---
PEER_PW=111111 $SSH --sudo "EXPECT_BID=$BIE NW=$NW bash /tmp/p7b_biz/p7b_snap.sh id | grep -E 'ID_MAGIC|ID_BID|ID_UNIMPL|ID_OK|ID_FAIL'" 2>&1

# --- 可选的流中 ACK 抓包 (后台; 先起等握手, 再跑主流程) ---
if [ "$DUMP" = "1" ]; then
  PEER_PW=111111 $SSH --sudo "setsid nohup bash /tmp/p7b_biz/wdump.sh $TAG 80 10 >/dev/null 2>&1 < /dev/null & echo WD_PID=\$!"
fi

# --- 主跑 ---
PEER_PW=111111 $SSH --sudo --timeout 900 "cd /tmp/p7b_biz && TAG=$TAG SECS=$SECS NW=$NW BID_EXPECT=$BIE KW='$KW' SINK_EXTRA='--check lane8 --maxbytes $MAXBYTES' MAXSNAP=$MAXSNAP SNAPGAP=$SNAPGAP RCVBUF=$RCVBUF bash /tmp/p7b_biz/lf_dl.sh" > "$RAW" 2>&1
RC=$?
echo "### RUN_END tag=$TAG rc=$RC bytes=$(stat -c %s "$RAW" 2>/dev/null) $(date +%s.%N)"

# --- ss 见证全量日志取回 (lf_dl.sh 自带 10 ms 采样器) ---
WOUT="D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_buildF_board_20261010\\runs\\${TAG}_ss.log"
PEER_PW=111111 $SSH --get /tmp/ss_${TAG}.log "$WOUT" 2>&1

# --- 抓包读数 (DUMP=1 时) ---
if [ "$DUMP" = "1" ]; then
  PEER_PW=111111 $SSH "echo '=== HANDSHAKE (SYN/SYN-ACK, wscale 见证) ==='; tcpdump -r /tmp/dump_${TAG}_hs.pcap -nvv 2>&1 | head -40; echo '=== MID-FLOW window-field (每点 80 包, win 字段) ==='; for p in 0 1 2 3 4 5 6 7 8 9; do echo \"-- point \$p:\"; tcpdump -r /tmp/dump_${TAG}_p\${p}.pcap -n 2>/dev/null | grep -oE 'win [0-9]+' | awk '{print \$2}' | sort -n | awk 'NR==1{mn=\$1} {a[NR]=\$1} END{if(NR>0) printf \"n=%d min=%d med=%d max=%d\\n\", NR, mn, a[int((NR+1)/2)], a[NR]; else print \"(空)\"}'; done; echo '=== stderr ==='; tail -5 /tmp/dump_${TAG}.err" 2>&1 | tee "$OUT/runs/${TAG}_dump.txt"
fi

# --- 紧凑摘要 (供人读; 判据解析另走 analyze.py) ---
echo "--- META ---";        grep -E '^LF_META_|^SINK_LIMITS|^CARRIER=|^LF_GEOM_OK|^LF_GEOM_FAIL|^PCAP_ACTIVE' "$RAW" | head -20
echo "--- SINK ---";        grep -E '^SINK_SUM|^SINK_CONN' "$RAW" | head -6
echo "--- PIN ---";         grep -E '^PIN_CPU=|^PIN_THREAD|^UNPINNED=' "$RAW" | head -8
echo "--- GUARDS ---";      grep -E '^LF_SNAP_MAXREACHED|^SNAP_FAIL|^GEN_FAIL' "$RAW" | head -5
echo "--- GEOM_NOPCAP ---"; grep -E '^GEOM_NOPCAP' "$RAW" | head -3
echo "--- PING ---";        grep -A1 'PHASE ping' "$RAW" | tail -2
