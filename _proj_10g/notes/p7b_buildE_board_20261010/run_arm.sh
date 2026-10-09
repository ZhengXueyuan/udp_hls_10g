#!/bin/bash
# run_arm.sh -- P7B 构建 E 板级轮: 长流下行 (板 -> 对端 :8080) 一跑
#   两臂**同构型**: 同 SECS / 同 --maxbytes / 同台架脚本 / 同 rcvbuf / 同 sink 二进制
#   唯一差异 = 位流 (E 67 字含 W66 / D 66 字无 W66) 与随之而变的 KW 字表 (W66 只在 E 里存在)
#   用法: bash run_arm.sh E|D <RUNID>   env: MAXBYTES SECS SNAPGAP MAXSNAP RCVBUF
set -u
ARM=${1:?usage: run_arm.sh E|D RUNID}; RUNID=${2:?usage: run_arm.sh E|D RUNID}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildE_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

MAXBYTES=${MAXBYTES:-100000000000}
SECS=${SECS:-240}
SNAPGAP=${SNAPGAP:-0.1}
MAXSNAP=${MAXSNAP:-1500}
RCVBUF=${RCVBUF:-8388608}

case "$ARM" in
  E) BIE=0x00000019; NW=67; KW='5 20 43 51 15 63 64 65 66' ;;   # 被测: 67 字 (W66 = 帧器侧窗口门停顿拍数)
  D) BIE=0x00000018; NW=66; KW='5 20 43 51 15 63 64 65' ;;      # 对照: 66 字 (无 W66)
  *) echo "ARM_UNKNOWN $ARM"; exit 2;;
esac
TAG="BE${ARM}${RUNID}"
echo "### KW_USED tag=$TAG arm=$ARM KW='$KW'"
RAW=$OUT/runs/${TAG}.txt
COALF=$OUT/runs/${TAG}_coalesce.txt

echo "### RUN_BEGIN arm=$ARM tag=$TAG $(date +%s.%N)"
# --- COALESCE 见证 (每次报速率必带; 测前/测后各一次) ---
PEER_PW=111111 $SSH "ethtool -c enp1s0f1np1 | grep -E 'Coalesce|Adaptive|rx-usecs'; echo ---; nproc; echo NIC_COUNT=\$(lspci | grep -c 9120)" 2>&1 | tee "$COALF"

# --- 板侧身份闸 (跑前, 独立于 lf_dl.sh 内的闸) ---
PEER_PW=111111 $SSH --sudo "EXPECT_BID=$BIE NW=$NW bash /tmp/p7b_biz/p7b_snap.sh id | grep -E 'ID_MAGIC|ID_BID|ID_UNIMPL|ID_OK|ID_FAIL'" 2>&1

# --- 主跑 ---
PEER_PW=111111 $SSH --sudo --timeout 900 "cd /tmp/p7b_biz && TAG=$TAG SECS=$SECS NW=$NW BID_EXPECT=$BIE KW='$KW' SINK_EXTRA='--check lane8 --maxbytes $MAXBYTES' MAXSNAP=$MAXSNAP SNAPGAP=$SNAPGAP RCVBUF=$RCVBUF bash /tmp/p7b_biz/lf_dl.sh" > "$RAW" 2>&1
RC=$?
echo "### RUN_END arm=$ARM tag=$TAG rc=$RC bytes=$(stat -c %s "$RAW" 2>/dev/null) $(date +%s.%N)"

# --- 测后 COALESCE ---
PEER_PW=111111 $SSH "ethtool -c enp1s0f1np1 | grep -E 'Adaptive|rx-usecs'" 2>&1

# --- 紧凑摘要 (供人读; 判据解析另走 python) ---
echo "--- META ---";        grep -E '^LF_META_|^SINK_LIMITS|^CARRIER=|^LF_GEOM_OK|^LF_GEOM_FAIL|^PCAP_ACTIVE' "$RAW" | head -20
echo "--- SINK ---";        grep -E '^SINK_SUM|^SINK_CONN' "$RAW" | head -6
echo "--- PIN ---";         grep -E '^PIN_CPU=|^PIN_THREAD|^UNPINNED=' "$RAW" | head -6
echo "--- GUARDS ---";      grep -E '^LF_SNAP_MAXREACHED|^SNAP_FAIL|^GEN_FAIL' "$RAW" | head -5
echo "--- GEOM_NOPCAP ---"; grep -E '^GEOM_NOPCAP' "$RAW" | head -3
echo "--- PING ---";        grep -A1 'PHASE ping' "$RAW" | tail -2
