#!/bin/bash
# run_arm2.sh -- P7B 构建 F 板级二轮 (2026-10-10): 长流下行 (板 -> 对端 :8080) 一跑
#   与上一轮 run_arm.sh 的差别 (只有三处):
#     ① 主脚本换成 /tmp/p7b_board2/lf_dl_snmp.sh (= lf_dl.sh 逐字副本 + 4 处 /proc/net/snmp 取样插桩;
#        diff md5 见 STEP0) —— 目的 = L 的**独立分母** (对端内核 TcpOutSegs)
#     ② 取回三个额外日志: snmp_ (点采样) / snmpseq_ (0.5 s 连续采样器) / ss_ (10 ms, 台架自带)
#     ③ 用 -mtime 见证 + 本次独有字符串判"命令真跑了" (不给陈旧件)
#   用法: bash run_arm2.sh <TAG> <rcvbuf> <maxbytes> [dump=0/1]
#   env: SECS SNAPGAP MAXSNAP KW SNMP_IDLE SNMP_IDLE_SECS
set -u
TAG=${1:?usage: run_arm2.sh TAG RCVBUF MAXBYTES [DUMP]}; RCVBUF=${2:?need RCVBUF}
MAXBYTES=${3:?need MAXBYTES}; DUMP=${4:-0}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildF_board2_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

SECS=${SECS:-180}
SNAPGAP=${SNAPGAP:-0.05}
MAXSNAP=${MAXSNAP:-900}
# 内窗字表: 8 字 = 时基(W5) + 帧(W20) + tx 自由拍(W43) + app 字节(W51)
#           + 三个新仪器(W66/W67/W68) + 等窗锁存(W69)
KW=${KW:-'5 20 43 51 66 67 68 69'}
BIE=0x0000001A; NW=70
RAW=$OUT/runs/${TAG}.txt
COALF=$OUT/runs/${TAG}_coalesce.txt
mkdir -p "$OUT/runs"

echo "### RUN_BEGIN tag=$TAG rcvbuf=$RCVBUF maxbytes=$MAXBYTES dump=$DUMP $(date +%s.%N)"
echo "### KW_USED tag=$TAG KW='$KW' secs=$SECS snapgap=$SNAPGAP maxsnap=$MAXSNAP"

# --- COALESCE 见证 (每次报速率必带) ---
PEER_PW=111111 $SSH "ethtool -c enp1s0f1np1 | grep -E 'Coalesce|Adaptive|rx-usecs'" 2>&1 | tee "$COALF"

# --- 板侧身份闸 (跑前; 独立于 lf_dl_snmp.sh 内的闸; 本次独有串 = RUNID 时刻) ---
echo "### ARM_T0 $(date +%s.%N)"
PEER_PW=111111 $SSH --sudo "EXPECT_BID=$BIE NW=$NW bash /tmp/p7b_biz/p7b_snap.sh id; echo ID_RC=\$?" 2>&1 | tee "$OUT/runs/${TAG}_id.txt"

# --- 可选的流中 ACK 抓包 (后台; 先起等握手, 再跑主流程) ---
if [ "$DUMP" = "1" ]; then
  PEER_PW=111111 $SSH --sudo "rm -f /tmp/dump_${TAG}_*.pcap /tmp/dump_${TAG}.err; setsid nohup bash /tmp/p7b_biz/wdump.sh $TAG 80 12 >/dev/null 2>&1 < /dev/null & echo WD_PID=\$!"
fi

# --- 主跑 ---
PEER_PW=111111 $SSH --sudo --timeout 1200 "cd /tmp/p7b_biz && TAG=$TAG SECS=$SECS NW=$NW BID_EXPECT=$BIE KW='$KW' SINK_EXTRA='--check lane8 --maxbytes $MAXBYTES' MAXSNAP=$MAXSNAP SNAPGAP=$SNAPGAP RCVBUF=$RCVBUF bash /tmp/p7b_board2/lf_dl_snmp.sh" > "$RAW" 2>&1
RC=$?
echo "### RUN_END tag=$TAG rc=$RC bytes=$(stat -c %s "$RAW" 2>/dev/null) $(date +%s.%N)"

# --- 取回三个见证日志 (⚠️ --get 本地路径必须 Windows 形式) ---
W=runs
PEER_PW=111111 $SSH --get /tmp/snmp_${TAG}.log    "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_buildF_board2_20261010\\$W\\${TAG}_snmp.log" 2>&1
PEER_PW=111111 $SSH --get /tmp/snmpseq_${TAG}.log "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_buildF_board2_20261010\\$W\\${TAG}_snmpseq.log" 2>&1
PEER_PW=111111 $SSH --get /tmp/ss_${TAG}.log      "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_buildF_board2_20261010\\$W\\${TAG}_ss.log" 2>&1

# --- 抓包读数 (DUMP=1) ---
if [ "$DUMP" = "1" ]; then
  PEER_PW=111111 $SSH "echo '=== HANDSHAKE (SYN/SYN-ACK, wscale 见证) ==='; tcpdump -r /tmp/dump_${TAG}_hs.pcap -nvv 2>&1 | head -40; echo '=== MID-FLOW window-field (每点 80 包, win 字段) ==='; for p in \$(seq 0 11); do f=/tmp/dump_${TAG}_p\${p}.pcap; [ -s \$f ] || { echo \"-- point \$p: (无/空)\"; continue; }; echo \"-- point \$p:\"; tcpdump -r \$f -n 2>/dev/null | grep -oE 'win [0-9]+' | awk '{print \$2}' | sort -n | awk 'NR==1{mn=\$1} {a[NR]=\$1} END{if(NR>0) printf \"n=%d min=%d med=%d max=%d\\n\", NR, mn, a[int((NR+1)/2)], a[NR]; else print \"(空)\"}'; done; echo '=== dump 点时间戳 (覆盖区间见证) ==='; grep -E 'PHASE[12]|DUMP_DONE' /tmp/dump_${TAG}.err; echo '=== stderr tail ==='; tail -5 /tmp/dump_${TAG}.err; echo '=== ss 见证: 该连接 segs_out/segs_in (per-socket 口径) ==='; grep -oE 'segs_out:[0-9]+ segs_in:[0-9]+' /tmp/ss_${TAG}.log | head -2; grep -oE 'segs_out:[0-9]+ segs_in:[0-9]+' /tmp/ss_${TAG}.log | tail -2" 2>&1 | tee "$OUT/runs/${TAG}_dump.txt"
fi

# --- 跑后板侧态 (0x08 / carrier / BID) ---
PEER_PW=111111 $SSH --sudo "echo '--- post 0x08 ---'; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; echo '--- post BID ---'; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; echo '--- carrier ---'; cat /sys/class/net/enp1s0f1np1/carrier" 2>&1 | tee "$OUT/runs/${TAG}_postid.txt"

# --- 紧凑摘要 ---
echo "--- SNMP_POINTS ---";  grep -E '^SNMP ' "$RAW" | head -12
echo "--- META ---";         grep -E '^LF_META_|^SINK_LIMITS|^CARRIER=|^LF_GEOM_OK|^LF_GEOM_FAIL|^PCAP_ACTIVE' "$RAW" | head -20
echo "--- SINK ---";         grep -E '^SINK_SUM|^SINK_CONN' "$RAW" | head -6
echo "--- PIN ---";          grep -E '^PIN_CPU=|^PIN_THREAD|^UNPINNED=' "$RAW" | head -8
echo "--- GUARDS ---";       grep -E '^LF_SNAP_MAXREACHED|^SNAP_FAIL|^GEN_FAIL|^LF_ABORT' "$RAW" | head -5
echo "--- GEOM_NOPCAP ---";  grep -E '^GEOM_NOPCAP' "$RAW" | head -3
echo "--- PING ---";         grep -A1 'PHASE ping' "$RAW" | tail -2
