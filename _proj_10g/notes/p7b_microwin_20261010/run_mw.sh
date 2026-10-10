#!/bin/bash
# run_mw.sh -- 微窗 stall 轮 (2026-10-10): 一跑 = 下行 (板 -> 对端 :8080) + 本轮侧信道插桩
#   与上一轮 run_arm2.sh 的差别:
#     ① 内窗字表默认含 **W55/W57/W58** (= stat_retx / o_retx_hi / o_retx_active) —— stall 期取数
#     ② 侧信道: 对端内核计数器采样器 (我自己的 /tmp/p7b_microwin/ctr.sh, 0.2 s)
#     ③ 侧信道: **全窗 pcap** (双向, 从连接前起抓 N 秒) —— 用于判"板还发不发 / 对端还 ACK 不 ACK"
#     ④ SECS 默认 60 (stall 判据只需 15 s; healthy 档到 60 s 或 maxbytes 先到)
#   用法: bash run_mw.sh <TAG> <rcvbuf> <maxbytes> [pcap_secs]
#   env: SECS KW CONNS
set -u
TAG=${1:?usage: run_mw.sh TAG RCVBUF MAXBYTES [PCAP_SECS]}; RCVBUF=${2:?need RCVBUF}
MAXBYTES=${3:?need MAXBYTES}; PCAP_SECS=${4:-0}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_microwin_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

SECS=${SECS:-60}
CONNS=${CONNS:-1}
KW=${KW:-'5 20 43 51 55 57 58 66 67 68 69'}
BIE=0x0000001A; NW=70
RAW=$OUT/runs/${TAG}.txt
mkdir -p "$OUT/runs"

echo "### RUN_BEGIN tag=$TAG rcvbuf=$RCVBUF maxbytes=$MAXBYTES pcap_secs=$PCAP_SECS $(date +%s.%N)"
echo "### KW_USED tag=$TAG KW='$KW' secs=$SECS conns=$CONNS"

# --- 部署本轮对端侧信道件 (只写 /tmp/p7b_microwin/, 绝不碰 /tmp/p7b_biz) ---
PEER_PW=111111 $SSH --sudo "mkdir -p /tmp/p7b_microwin && chmod 777 /tmp/p7b_microwin" >/dev/null 2>&1
PEER_PW=111111 $SSH --put "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_microwin_20261010\\_tools\\ctr.sh" /tmp/p7b_microwin/ctr.sh 2>&1 | tail -1
LOCALMD5=$(md5sum "$OUT/_tools/ctr.sh" | cut -d' ' -f1)
REMOTEMD5=$(PEER_PW=111111 $SSH "md5sum /tmp/p7b_microwin/ctr.sh 2>&1" | awk '{print $1}')
echo "### CTRMD5_LOCAL $LOCALMD5"; echo "### CTRMD5_REMOTE $REMOTEMD5"
[ "$LOCALMD5" = "$REMOTEMD5" ] || { echo "FATAL_CTR_PUT_FAIL (对端采样器 md5 不符/不存在) ⇒ 拒绝继续"; exit 3; }
{ echo "CTRMD5_LOCAL $LOCALMD5"; echo "CTRMD5_REMOTE $REMOTEMD5"; } | tee "$OUT/runs/${TAG}_ctrmd5.txt" >/dev/null

# --- COALESCE 见证 ---
PEER_PW=111111 $SSH "ethtool -c enp1s0f1np1 | grep -E 'Coalesce|Adaptive|rx-usecs'" 2>&1 | tee "$OUT/runs/${TAG}_coalesce.txt"

# --- 板侧身份闸 (跑前) ---
echo "### ARM_T0 $(date +%s.%N)"
PEER_PW=111111 $SSH --sudo "EXPECT_BID=$BIE NW=$NW bash /tmp/p7b_biz/p7b_snap.sh id; echo ID_RC=\$?; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x04 w | tail -1; cat /sys/class/net/enp1s0f1np1/carrier" 2>&1 | tee "$OUT/runs/${TAG}_id.txt"

# --- 侧信道 ①: 内核计数器采样器 ---
PEER_PW=111111 $SSH --sudo "rm -f /tmp/mw_${TAG}_ctr.log; setsid nohup env TAG=$TAG bash /tmp/p7b_microwin/ctr.sh > /tmp/mw_${TAG}_ctr.log 2>&1 < /dev/null & echo CTR_PID=\$!" 2>&1

# --- 侧信道 ③: 判别探针 (只在本轮授权范围内: 对端发包, 不改任何配置) ---
if [ -n "${PROBE_WIN:-}" ]; then
  PEER_PW=111111 $SSH --put "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_microwin_20261010\\_tools\\stall_probe.py" /tmp/p7b_microwin/stall_probe.py 2>&1 | tail -1
  PEER_PW=111111 $SSH --sudo "rm -f /tmp/mw_${TAG}_probe.log; setsid nohup env PROBE_WIN=$PROBE_WIN python3 /tmp/p7b_microwin/stall_probe.py ${INJECT_AT:-3} 3 0.15 > /tmp/mw_${TAG}_probe.log 2>&1 < /dev/null & echo PROBE_PID=\$!" 2>&1
fi

# --- 侧信道 ②: 全窗 pcap (双向) ---
if [ "$PCAP_SECS" != "0" ]; then
  PEER_PW=111111 $SSH --sudo "rm -f /tmp/mw_${TAG}.pcap /tmp/mw_${TAG}_pcap.err; setsid nohup timeout -k 2 $PCAP_SECS tcpdump -i enp1s0f1np1 -s 128 -U -w /tmp/mw_${TAG}.pcap 'port 8080' > /tmp/mw_${TAG}_pcap.err 2>&1 < /dev/null & echo PCAP_PID=\$!; date +%s.%N" 2>&1
fi

# --- 主跑 (上一轮的脚本, 一字未改; 我的字表经 KW 传入) ---
PEER_PW=111111 $SSH --sudo --timeout 1200 "cd /tmp/p7b_biz && TAG=$TAG SECS=$SECS CONNS=$CONNS NW=$NW BID_EXPECT=$BIE KW='$KW' SINK_EXTRA='--check lane8 --maxbytes $MAXBYTES --poll-ms ${POLL_MS:-5000} --stall-n ${STALL_N:-3}' MAXSNAP=900 SNAPGAP=0.05 RCVBUF=$RCVBUF bash /tmp/p7b_board2/lf_dl_snmp.sh" > "$RAW" 2>&1
RC=$?
echo "### RUN_END tag=$TAG rc=$RC bytes=$(stat -c %s "$RAW" 2>/dev/null) $(date +%s.%N)"

# --- 停采样器 + 取回 ---
PEER_PW=111111 $SSH --sudo "pkill -f 'p7b_microwin/ctr.sh' 2>/dev/null; pkill -f \"tcpdump -i enp1s0f1np1 -s 128 -U -w /tmp/mw_${TAG}.pcap\" 2>/dev/null; echo KILLED; ls -la /tmp/mw_${TAG}* 2>&1" 2>&1 | tail -8

W=runs; L="D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_microwin_20261010\\$W"
PEER_PW=111111 $SSH --get /tmp/mw_${TAG}_ctr.log      "$L\\${TAG}_ctr.log"     2>&1 | tail -1
PEER_PW=111111 $SSH --get /tmp/snmp_${TAG}.log        "$L\\${TAG}_snmp.log"    2>&1 | tail -1
PEER_PW=111111 $SSH --get /tmp/snmpseq_${TAG}.log     "$L\\${TAG}_snmpseq.log" 2>&1 | tail -1
PEER_PW=111111 $SSH --get /tmp/ss_${TAG}.log          "$L\\${TAG}_ss.log"      2>&1 | tail -1
PEER_PW=111111 $SSH --get /tmp/sink_${TAG}.txt        "$L\\${TAG}_sink.txt"    2>&1 | tail -1
if [ -n "${PROBE_WIN:-}" ]; then
  PEER_PW=111111 $SSH --get /tmp/mw_${TAG}_probe.log  "$L\\${TAG}_probe.log"  2>&1 | tail -1
fi
if [ "$PCAP_SECS" != "0" ]; then
  PEER_PW=111111 $SSH --get /tmp/mw_${TAG}.pcap "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_microwin_20261010\\$W\\${TAG}.pcap" 2>&1 | tail -1
  PEER_PW=111111 $SSH --get /tmp/mw_${TAG}_pcap.err "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_microwin_20261010\\$W\\${TAG}_pcap.err" 2>&1 | tail -1
fi

# --- 跑后板侧态 ---
PEER_PW=111111 $SSH --sudo "echo '--- post 0x08 ---'; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; echo '--- post BID ---'; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; echo '--- carrier ---'; cat /sys/class/net/enp1s0f1np1/carrier; echo '--- 残留进程 ---'; pgrep -a p7b_tcp_sink; pgrep -a tcpdump; echo '(空=无残留)'" 2>&1 | tee "$OUT/runs/${TAG}_postid.txt" | tail -10

# --- 摘要 ---
echo "--- META ---";     grep -E '^LF_META_|^SINK_LIMITS|^CARRIER=|^ID_BID|^LF_GEOM_OK|^LF_GEOM_FAIL|^ID_OK' "$RAW" | head -20
echo "--- SINK ---";     grep -E '^SINK_SUM|^SINK_CONN 0 ' "$RAW" | head -4
echo "--- GUARDS ---";   grep -E '^LF_SNAP_MAXREACHED|^SNAP_FAIL|^GEN_FAIL|^LF_ABORT' "$RAW" | head -5
echo "--- GEOM ---";     grep -E '^GEOM_NOPCAP' "$RAW" | head -3
echo "--- PING ---";     grep -A1 'PHASE ping' "$RAW" | tail -2
